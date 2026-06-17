package handlers

import (
	"context"
	"log"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"

	"github.com/minio/minio-go/v7"
)

// transcodeToHLS downloads the source video from R2, segments it into a 720p HLS
// rendition with ffmpeg, uploads the playlist + .ts segments back to R2, and marks
// the asset ready with its HLS url. Runs in its own goroutine; failures flip the
// status to 'failed' (the source mp4 still plays as a fallback).
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

	// Single 720p rendition (scales down only, never up), 6-second segments. Low
	// enough bitrate to stream smoothly even off the dev URL.
	cmd := exec.Command("ffmpeg", "-y", "-i", src,
		"-vf", "scale='min(1280,iw)':-2",
		"-c:v", "libx264", "-preset", "veryfast", "-profile:v", "main",
		"-b:v", "2500k", "-maxrate", "2675k", "-bufsize", "3750k",
		"-c:a", "aac", "-b:a", "128k", "-ac", "2",
		"-f", "hls", "-hls_time", "6", "-hls_playlist_type", "vod", "-hls_flags", "independent_segments",
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
	if _, err := h.Pool.Exec(ctx, `UPDATE media_assets SET status='ready', hls_url=$2 WHERE id=$1`, assetID, hlsURL); err != nil {
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
