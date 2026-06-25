package handlers

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"log"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/minio/minio-go/v7"
)

// transcodeToHLS downloads the source video from R2 and turns it into an HLS
// stream that actually plays smoothly: it caps the bitrate to a streamable level
// (camera/source files can be 100+ Mbps, which no connection can stream) at high
// visual quality, scales to at most 1080p, and segments into short .ts pieces.
// Uploads playlist + segments back to R2 and marks the asset ready. Runs in its
// own goroutine; failures flip the status to 'failed' (source mp4 is the fallback).
func (h *Handlers) transcodeToHLS(assetID, sourceKey string) {
	ctx := context.Background()
	fail := func(msg string, err error) {
		log.Printf("transcode %s: %s: %v", assetID, msg, err)
		_, _ = h.Pool.Exec(ctx, `UPDATE media_assets SET status='failed' WHERE id=$1`, assetID)
	}
	cl, err := h.r2client()
	if err != nil {
		fail("r2 client", err)
		return
	}
	tmp, err := os.MkdirTemp("", "hls-"+assetID)
	if err != nil {
		fail("tmpdir", err)
		return
	}
	defer os.RemoveAll(tmp)

	out := filepath.Join(tmp, "hls")
	if err := os.MkdirAll(out, 0o755); err != nil {
		fail("mkdir", err)
		return
	}

	// AES-128 encrypt the segments. The key URI in the playlist points at our API
	// (served only to logged-in users); the key bytes live in the DB, never in R2.
	encKey := make([]byte, 16)
	if _, err := rand.Read(encKey); err != nil {
		fail("keygen", err)
		return
	}
	keyFile := filepath.Join(tmp, "enc.key")
	if err := os.WriteFile(keyFile, encKey, 0o600); err != nil {
		fail("keyfile", err)
		return
	}
	keyURI := h.Cfg.AppBaseURL + "/api/v1/me/videos/" + assetID + "/hls.key"
	keyInfo := filepath.Join(tmp, "enc.keyinfo")
	if err := os.WriteFile(keyInfo, []byte(keyURI+"\n"+keyFile+"\n"), 0o600); err != nil {
		fail("keyinfo", err)
		return
	}

	// Choose the ffmpeg input. Prefer streaming the source straight from R2's
	// public URL: for multi-GB videos this avoids first downloading the whole file
	// to the box (peak local disk = HLS output only, not source+output), and ffmpeg
	// starts immediately. ffmpeg reads it over HTTP range requests. If the bucket
	// isn't public (probe fails) we fall back to downloading the source first.
	var input string
	var pr srcProbe
	var ok bool
	if h.Cfg.R2.PublicBase != "" {
		u := strings.TrimRight(h.Cfg.R2.PublicBase, "/") + "/" + sourceKey
		if pr, ok = ffprobeSource(u); ok {
			input = u
		}
	}
	if input == "" {
		src := filepath.Join(tmp, "src"+path.Ext(sourceKey))
		if err := cl.FGetObject(ctx, h.Cfg.R2.Bucket, sourceKey, src, minio.GetObjectOptions{}); err != nil {
			fail("download", err)
			return
		}
		input = src
		pr, ok = ffprobeSource(input)
	}

	// The HLS muxer args are the same whichever way we feed it: 6-second
	// AES-128-encrypted VOD segments.
	hlsTail := []string{
		"-f", "hls", "-hls_time", "6", "-hls_playlist_type", "vod", "-hls_flags", "independent_segments",
		"-hls_key_info_file", keyInfo,
		"-hls_segment_filename", filepath.Join(out, "seg_%03d.ts"),
		filepath.Join(out, "index.m3u8"),
	}
	// Full re-encode: scale down to <=1080p, CRF 21 for near-transparent quality,
	// capped at 6 Mbps so it streams smoothly anywhere. This is the expensive path
	// (minutes of CPU on libx264) and only runs when the source isn't already a
	// web-ready H.264 file.
	encodeArgs := append([]string{"-y", "-i", input,
		"-map", "0:v:0", "-map", "0:a:0?",
		"-vf", "scale='min(1920,iw)':'-2'",
		"-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-pix_fmt", "yuv420p",
		"-crf", "21", "-maxrate", "6M", "-bufsize", "12M",
		"-c:a", "aac", "-b:a", "128k", "-ac", "2"}, hlsTail...)

	// Cheap path: if the upload is already H.264 within our size/bitrate limits we
	// just stream-copy it into HLS (near-instant, I/O bound) instead of burning
	// minutes re-encoding. Audio is copied when already AAC, else re-encoded (cheap).
	// An unreadable probe falls through to the full encode.
	copyMode := ok && pr.canStreamCopy()

	var args []string
	if copyMode {
		args = []string{"-y", "-i", input, "-map", "0:v:0"}
		if pr.hasAudio {
			args = append(args, "-map", "0:a:0?", "-c:v", "copy")
			if pr.aCodec == "aac" {
				args = append(args, "-c:a", "copy")
			} else {
				args = append(args, "-c:a", "aac", "-b:a", "128k", "-ac", "2")
			}
		} else {
			args = append(args, "-c:v", "copy", "-an")
		}
		args = append(args, hlsTail...)
	} else {
		args = encodeArgs
	}

	mode := "encode"
	if copyMode {
		mode = "stream-copy"
	}
	log.Printf("transcode %s: %s (codec=%q %dx%d bitrate=%d audio=%q)", assetID, mode, pr.vCodec, pr.width, pr.height, pr.bitRate, pr.aCodec)

	if logBytes, err := exec.Command("ffmpeg", args...).CombinedOutput(); err != nil {
		// A stream-copy attempt can still trip on an exotic container or odd
		// keyframe layout — fall back to a clean full re-encode before giving up.
		if !copyMode {
			log.Printf("transcode %s ffmpeg output: %s", assetID, tail(string(logBytes), 600))
			fail("ffmpeg", err)
			return
		}
		log.Printf("transcode %s stream-copy failed, retrying with encode: %s", assetID, tail(string(logBytes), 300))
		_ = os.RemoveAll(out)
		if err := os.MkdirAll(out, 0o755); err != nil {
			fail("mkdir retry", err)
			return
		}
		if logBytes, err := exec.Command("ffmpeg", encodeArgs...).CombinedOutput(); err != nil {
			log.Printf("transcode %s ffmpeg output: %s", assetID, tail(string(logBytes), 600))
			fail("ffmpeg", err)
			return
		}
	}

	entries, err := os.ReadDir(out)
	if err != nil {
		fail("readdir", err)
		return
	}
	prefix := "videos/" + assetID + "/hls/"
	for _, e := range entries {
		ct := "video/mp2t"
		if strings.HasSuffix(e.Name(), ".m3u8") {
			ct = "application/vnd.apple.mpegurl"
		}
		if _, err := cl.FPutObject(ctx, h.Cfg.R2.Bucket, prefix+e.Name(), filepath.Join(out, e.Name()),
			minio.PutObjectOptions{ContentType: ct}); err != nil {
			fail("upload "+e.Name(), err)
			return
		}
	}
	hlsURL := strings.TrimRight(h.Cfg.R2.PublicBase, "/") + "/" + prefix + "index.m3u8"
	if _, err := h.Pool.Exec(ctx, `UPDATE media_assets SET status='ready', hls_url=$2, enc_key=$3 WHERE id=$1`, assetID, hlsURL, encKey); err != nil {
		fail("db update", err)
		return
	}
	log.Printf("transcode %s: ready -> %s", assetID, hlsURL)
}

func tail(s string, n int) string {
	if len(s) > n {
		return s[len(s)-n:]
	}
	return s
}

// srcProbe is the slice of ffprobe output we use to decide whether the source can
// be stream-copied into HLS instead of re-encoded.
type srcProbe struct {
	vCodec   string
	aCodec   string
	width    int
	height   int
	hasAudio bool
	bitRate  int64 // overall bits/sec, 0 if unknown
}

// ffprobeSource inspects the downloaded file. Returns ok=false on any failure
// (e.g. ffprobe missing or unreadable file) so the caller safely falls back to a
// full re-encode.
func ffprobeSource(src string) (srcProbe, bool) {
	out, err := exec.Command("ffprobe", "-v", "error",
		"-show_entries", "stream=codec_type,codec_name,width,height:format=bit_rate",
		"-of", "json", src).Output()
	if err != nil {
		return srcProbe{}, false
	}
	var raw struct {
		Streams []struct {
			CodecType string `json:"codec_type"`
			CodecName string `json:"codec_name"`
			Width     int    `json:"width"`
			Height    int    `json:"height"`
		} `json:"streams"`
		Format struct {
			BitRate string `json:"bit_rate"`
		} `json:"format"`
	}
	if err := json.Unmarshal(out, &raw); err != nil {
		return srcProbe{}, false
	}
	var p srcProbe
	for _, s := range raw.Streams {
		switch s.CodecType {
		case "video":
			if p.vCodec == "" { // first video stream wins
				p.vCodec = s.CodecName
				p.width = s.Width
				p.height = s.Height
			}
		case "audio":
			if !p.hasAudio {
				p.hasAudio = true
				p.aCodec = s.CodecName
			}
		}
	}
	if p.vCodec == "" {
		return srcProbe{}, false
	}
	if v, err := strconv.ParseInt(strings.TrimSpace(raw.Format.BitRate), 10, 64); err == nil {
		p.bitRate = v
	}
	return p, true
}

// canStreamCopy reports whether the source is already a web-ready H.264 stream we
// can segment without re-encoding: H.264 video, neither dimension above 1920, and
// a known overall bitrate already within a streamable range. Unknown or very high
// bitrate takes the capped re-encode instead.
func (p srcProbe) canStreamCopy() bool {
	if p.vCodec != "h264" {
		return false
	}
	if p.width > 1920 || p.height > 1920 {
		return false
	}
	if p.bitRate <= 0 || p.bitRate > 8_000_000 {
		return false
	}
	return true
}
