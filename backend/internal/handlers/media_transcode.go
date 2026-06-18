package handlers

import (
	"context"
	"crypto/rand"
	"log"
	"os"
	"os/exec"
	"path"
	"path/filepath"
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

	src := filepath.Join(tmp, "src"+path.Ext(sourceKey))
	if err := cl.FGetObject(ctx, h.Cfg.R2.Bucket, sourceKey, src, minio.GetObjectOptions{}); err != nil {
		fail("download", err)
		return
	}
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

	// Map exactly one video + (optional) one audio stream — ignores junk/data
	// tracks. Scale down to <=1080p, CRF 21 for near-transparent quality, capped at
	// 6 Mbps so it streams smoothly anywhere. 6-second AES-128-encrypted segments.
	cmd := exec.Command("ffmpeg", "-y", "-i", src,
		"-map", "0:v:0", "-map", "0:a:0?",
		"-vf", "scale='min(1920,iw)':'-2'",
		"-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-pix_fmt", "yuv420p",
		"-crf", "21", "-maxrate", "6M", "-bufsize", "12M",
		"-c:a", "aac", "-b:a", "128k", "-ac", "2",
		"-f", "hls", "-hls_time", "6", "-hls_playlist_type", "vod", "-hls_flags", "independent_segments",
		"-hls_key_info_file", keyInfo,
		"-hls_segment_filename", filepath.Join(out, "seg_%03d.ts"),
		filepath.Join(out, "index.m3u8"))
	if logBytes, err := cmd.CombinedOutput(); err != nil {
		log.Printf("transcode %s ffmpeg output: %s", assetID, tail(string(logBytes), 600))
		fail("ffmpeg", err)
		return
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
