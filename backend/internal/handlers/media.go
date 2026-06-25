package handlers

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/cors"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

func (h *Handlers) r2options() *minio.Options {
	return &minio.Options{
		Creds:  credentials.NewStaticV4(h.Cfg.R2.AccessKey, h.Cfg.R2.SecretKey, ""),
		Secure: true,
		Region: "auto",
	}
}

// r2client builds an S3 client for the configured Cloudflare R2 bucket.
func (h *Handlers) r2client() (*minio.Client, error) {
	if !h.Cfg.R2.Enabled() {
		return nil, fmt.Errorf("R2 not configured")
	}
	return minio.New(h.Cfg.R2.Endpoint(), h.r2options())
}

// r2core exposes the low-level multipart API for chunked uploads.
func (h *Handlers) r2core() (*minio.Core, error) {
	if !h.Cfg.R2.Enabled() {
		return nil, fmt.Errorf("R2 not configured")
	}
	return minio.NewCore(h.Cfg.R2.Endpoint(), h.r2options())
}

// --- Chunked upload (so very large videos upload reliably in pieces, then R2
// reassembles them into a single object — the admin only ever sees one video) ---

// InitVideoUpload starts an R2 multipart upload and returns the key + upload id.
func (h *Handlers) InitVideoUpload(c *fiber.Ctx) error {
	if !h.Cfg.R2.Enabled() {
		return fiber.NewError(fiber.StatusServiceUnavailable, "video storage (R2) is not configured")
	}
	var req struct {
		Filename    string `json:"filename"`
		ContentType string `json:"content_type"`
	}
	_ = c.BodyParser(&req)
	ct := req.ContentType
	if ct == "" {
		ct = "video/mp4"
	}
	key := "videos/" + uuid.NewString() + path.Ext(req.Filename)
	core, err := h.r2core()
	if err != nil {
		return fiber.NewError(fiber.StatusServiceUnavailable, "R2 unavailable")
	}
	uploadID, err := core.NewMultipartUpload(c.Context(), h.Cfg.R2.Bucket, key, minio.PutObjectOptions{ContentType: ct})
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "init failed: "+err.Error())
	}
	return c.JSON(fiber.Map{"upload_id": uploadID, "key": key})
}

// UploadVideoPart uploads one chunk (raw body). Returns the part's ETag.
func (h *Handlers) UploadVideoPart(c *fiber.Ctx) error {
	uploadID := c.Query("upload_id")
	key := c.Query("key")
	partNum, _ := strconv.Atoi(c.Query("part"))
	if uploadID == "" || key == "" || partNum < 1 {
		return fiber.NewError(fiber.StatusBadRequest, "upload_id, key, part required")
	}
	body := c.Body()
	if len(body) == 0 {
		return fiber.NewError(fiber.StatusBadRequest, "empty chunk")
	}
	core, err := h.r2core()
	if err != nil {
		return fiber.NewError(fiber.StatusServiceUnavailable, "R2 unavailable")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	part, err := core.PutObjectPart(ctx, h.Cfg.R2.Bucket, key, uploadID, partNum,
		bytes.NewReader(body), int64(len(body)), minio.PutObjectPartOptions{})
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "part upload failed: "+err.Error())
	}
	return c.JSON(fiber.Map{"part_number": partNum, "etag": part.ETag})
}

// EnsureR2Cors sets a CORS policy on the bucket so the browser can upload parts
// DIRECTLY to R2 (PUT) and read the part ETag back — this is what lets multi-GB
// uploads run at the user's full bandwidth instead of being throttled by a
// double hop through this server. Best-effort: if it fails, the client falls
// back to the proxy upload path. Run once at startup.
func (h *Handlers) EnsureR2Cors(ctx context.Context) {
	if !h.Cfg.R2.Enabled() {
		return
	}
	cl, err := h.r2client()
	if err != nil {
		log.Printf("r2 cors: client: %v", err)
		return
	}
	cfg := cors.NewConfig([]cors.Rule{{
		AllowedOrigin: []string{"*"}, // presigned URL + admin auth are the real gate
		AllowedMethod: []string{"GET", "PUT", "HEAD"},
		AllowedHeader: []string{"*"},
		ExposeHeader:  []string{"ETag"},
		MaxAgeSeconds: 3600,
	}})
	if err := cl.SetBucketCors(ctx, h.Cfg.R2.Bucket, cfg); err != nil {
		log.Printf("r2 cors: set failed (direct browser upload will fall back to proxy): %v", err)
		return
	}
	log.Printf("r2 cors configured for direct browser uploads")
}

// SignUploadParts returns short-lived presigned PUT URLs, one per requested part
// number, so the browser can upload each chunk straight to R2.
func (h *Handlers) SignUploadParts(c *fiber.Ctx) error {
	if !h.Cfg.R2.Enabled() {
		return fiber.NewError(fiber.StatusServiceUnavailable, "video storage (R2) is not configured")
	}
	var req struct {
		Key      string `json:"key"`
		UploadID string `json:"upload_id"`
		Parts    []int  `json:"parts"`
	}
	if err := c.BodyParser(&req); err != nil || req.Key == "" || req.UploadID == "" || len(req.Parts) == 0 {
		return fiber.NewError(fiber.StatusBadRequest, "key, upload_id, parts required")
	}
	cl, err := h.r2client()
	if err != nil {
		return fiber.NewError(fiber.StatusServiceUnavailable, "R2 unavailable")
	}
	urls := make(map[string]string, len(req.Parts))
	for _, pn := range req.Parts {
		if pn < 1 {
			continue
		}
		vals := url.Values{}
		vals.Set("partNumber", strconv.Itoa(pn))
		vals.Set("uploadId", req.UploadID)
		u, perr := cl.Presign(c.Context(), "PUT", h.Cfg.R2.Bucket, req.Key, 6*time.Hour, vals)
		if perr != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "presign failed: "+perr.Error())
		}
		urls[strconv.Itoa(pn)] = u.String()
	}
	return c.JSON(fiber.Map{"urls": urls})
}

// CompleteVideoUpload finalises the multipart upload (R2 stitches the pieces into
// one object) and records it in the video store.
func (h *Handlers) CompleteVideoUpload(c *fiber.Ctx) error {
	var req struct {
		UploadID string `json:"upload_id"`
		Key      string `json:"key"`
		Title    string `json:"title"`
		Size     int64  `json:"size"`
		Parts    []struct {
			PartNumber int    `json:"part_number"`
			ETag       string `json:"etag"`
		} `json:"parts"`
	}
	if err := c.BodyParser(&req); err != nil || req.UploadID == "" || req.Key == "" || len(req.Parts) == 0 {
		return fiber.NewError(fiber.StatusBadRequest, "upload_id, key, parts required")
	}
	core, err := h.r2core()
	if err != nil {
		return fiber.NewError(fiber.StatusServiceUnavailable, "R2 unavailable")
	}
	parts := make([]minio.CompletePart, len(req.Parts))
	for i, p := range req.Parts {
		parts[i] = minio.CompletePart{PartNumber: p.PartNumber, ETag: p.ETag}
	}
	if _, err := core.CompleteMultipartUpload(c.Context(), h.Cfg.R2.Bucket, req.Key, req.UploadID, parts, minio.PutObjectOptions{}); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "complete failed: "+err.Error())
	}
	title := strings.TrimSpace(req.Title)
	if title == "" {
		title = path.Base(req.Key)
	}
	url := strings.TrimRight(h.Cfg.R2.PublicBase, "/") + "/" + req.Key
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO media_assets (title, object_key, url, content_type, size_bytes, created_by, status)
		 VALUES ($1,$2,$3,$4,$5,$6,'processing') RETURNING id`,
		title, req.Key, url, "video/mp4", req.Size, callerID(c)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "uploaded but DB record failed")
	}
	go h.transcodeToHLS(id, req.Key) // segment to HLS for smooth streaming
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "title": title, "url": url, "size_bytes": req.Size, "status": "processing"})
}

// UploadVideo streams a multipart "file" straight to R2 and records it in the
// media_assets library (the "video store"). Returns the public playback URL.
func (h *Handlers) UploadVideo(c *fiber.Ctx) error {
	if !h.Cfg.R2.Enabled() {
		return fiber.NewError(fiber.StatusServiceUnavailable, "video storage (R2) is not configured")
	}
	fh, err := c.FormFile("file")
	if err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "file is required")
	}
	title := strings.TrimSpace(c.FormValue("title"))
	if title == "" {
		title = fh.Filename
	}
	f, err := fh.Open()
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "could not read upload")
	}
	defer f.Close()

	ct := fh.Header.Get("Content-Type")
	if ct == "" {
		ct = "video/mp4"
	}
	key := "videos/" + uuid.NewString() + path.Ext(fh.Filename)

	cl, err := h.r2client()
	if err != nil {
		return fiber.NewError(fiber.StatusServiceUnavailable, "R2 unavailable")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	if _, err := cl.PutObject(ctx, h.Cfg.R2.Bucket, key, f, fh.Size, minio.PutObjectOptions{ContentType: ct}); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "upload failed: "+err.Error())
	}
	url := strings.TrimRight(h.Cfg.R2.PublicBase, "/") + "/" + key

	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO media_assets (title, object_key, url, content_type, size_bytes, created_by, status)
		 VALUES ($1,$2,$3,$4,$5,$6,'processing') RETURNING id`,
		title, key, url, ct, fh.Size, callerID(c)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "saved to R2 but DB record failed")
	}
	go h.transcodeToHLS(id, key)
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "title": title, "url": url, "size_bytes": fh.Size, "status": "processing"})
}

// ListVideos returns the video library (logical videos). play_url is the HLS
// stream once transcoded (smooth, no stalls), else the source mp4; status shows
// processing/ready/failed.
func (h *Handlers) ListVideos(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, title, status,
		        CASE WHEN status='ready' AND hls_url<>'' THEN hls_url ELSE url END AS play_url,
		        size_bytes, created_at
		   FROM media_assets ORDER BY created_at DESC LIMIT 500`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, status, url string
		var size int64
		var created any
		if err := rows.Scan(&id, &title, &status, &url, &size, &created); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "title": title, "status": status, "url": url, "size_bytes": size, "created_at": created})
	}
	return c.JSON(fiber.Map{"videos": out, "r2_enabled": h.Cfg.R2.Enabled()})
}

// MediaHLSKey serves the AES-128 key for an encrypted video-store asset. Auth is
// enforced by middleware, so only logged-in users get it (deterrent, not DRM).
func (h *Handlers) MediaHLSKey(c *fiber.Ctx) error {
	id := c.Params("id")
	var key []byte
	if err := h.Pool.QueryRow(c.Context(), `SELECT enc_key FROM media_assets WHERE id=$1`, id).Scan(&key); err != nil || len(key) == 0 {
		return fiber.NewError(fiber.StatusNotFound, "no key")
	}
	c.Set("Content-Type", "application/octet-stream")
	c.Set("Cache-Control", "no-store")
	return c.Send(key)
}

// RetranscodeVideo re-runs HLS segmentation for an existing asset (e.g. after the
// pipeline changed). The source object must still be in R2.
func (h *Handlers) RetranscodeVideo(c *fiber.Ctx) error {
	id := c.Params("id")
	var key string
	if err := h.Pool.QueryRow(c.Context(), `SELECT object_key FROM media_assets WHERE id=$1`, id).Scan(&key); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "not found")
	}
	if _, err := h.Pool.Exec(c.Context(), `UPDATE media_assets SET status='processing' WHERE id=$1`, id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	go h.transcodeToHLS(id, key)
	return c.JSON(fiber.Map{"id": id, "status": "processing"})
}

// DeleteVideo removes the library record, the source object, and the HLS folder.
func (h *Handlers) DeleteVideo(c *fiber.Ctx) error {
	id := c.Params("id")
	var key string
	if err := h.Pool.QueryRow(c.Context(), `SELECT object_key FROM media_assets WHERE id=$1`, id).Scan(&key); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "not found")
	}
	if cl, err := h.r2client(); err == nil {
		_ = cl.RemoveObject(c.Context(), h.Cfg.R2.Bucket, key, minio.RemoveObjectOptions{})
		// Remove the per-asset HLS folder (playlist + segments).
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		for obj := range cl.ListObjects(ctx, h.Cfg.R2.Bucket, minio.ListObjectsOptions{Prefix: "videos/" + id + "/", Recursive: true}) {
			if obj.Err == nil {
				_ = cl.RemoveObject(ctx, h.Cfg.R2.Bucket, obj.Key, minio.RemoveObjectOptions{})
			}
		}
	}
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM media_assets WHERE id=$1`, id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"id": id, "deleted": true})
}
