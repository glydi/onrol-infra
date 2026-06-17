package handlers

import (
	"bytes"
	"context"
	"fmt"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
	"github.com/minio/minio-go/v7"
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
		`INSERT INTO media_assets (title, object_key, url, content_type, size_bytes, created_by)
		 VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
		title, req.Key, url, "video/mp4", req.Size, callerID(c)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "uploaded but DB record failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "title": title, "url": url, "size_bytes": req.Size})
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
		`INSERT INTO media_assets (title, object_key, url, content_type, size_bytes, created_by)
		 VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
		title, key, url, ct, fh.Size, callerID(c)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "saved to R2 but DB record failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "title": title, "url": url, "size_bytes": fh.Size})
}

// ListVideos lists the actual objects in the R2 bucket (the video folder) so the
// admin can select any video that's there — including ones uploaded via the
// Cloudflare dashboard, not just app uploads. Titles come from media_assets when
// known, otherwise the filename.
func (h *Handlers) ListVideos(c *fiber.Ctx) error {
	if !h.Cfg.R2.Enabled() {
		return c.JSON(fiber.Map{"videos": []fiber.Map{}, "r2_enabled": false})
	}
	cl, err := h.r2client()
	if err != nil {
		return fiber.NewError(fiber.StatusServiceUnavailable, "R2 unavailable")
	}
	// Titles from the library, keyed by object key.
	titleByKey := map[string]string{}
	if rows, err := h.Pool.Query(c.Context(), `SELECT object_key, title FROM media_assets`); err == nil {
		defer rows.Close()
		for rows.Next() {
			var k, t string
			if rows.Scan(&k, &t) == nil {
				titleByKey[k] = t
			}
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out := []fiber.Map{}
	for obj := range cl.ListObjects(ctx, h.Cfg.R2.Bucket, minio.ListObjectsOptions{Recursive: true}) {
		if obj.Err != nil || strings.HasSuffix(obj.Key, "/") {
			continue
		}
		title := titleByKey[obj.Key]
		if title == "" {
			title = path.Base(obj.Key)
		}
		out = append(out, fiber.Map{
			"key":        obj.Key,
			"title":      title,
			"url":        strings.TrimRight(h.Cfg.R2.PublicBase, "/") + "/" + obj.Key,
			"size_bytes": obj.Size,
		})
	}
	return c.JSON(fiber.Map{"videos": out, "r2_enabled": true})
}

// DeleteVideo removes an R2 object (by ?key=) and any matching library record.
func (h *Handlers) DeleteVideo(c *fiber.Ctx) error {
	key := c.Query("key")
	if key == "" {
		return fiber.NewError(fiber.StatusBadRequest, "key is required")
	}
	if cl, err := h.r2client(); err == nil {
		_ = cl.RemoveObject(c.Context(), h.Cfg.R2.Bucket, key, minio.RemoveObjectOptions{})
	}
	_, _ = h.Pool.Exec(c.Context(), `DELETE FROM media_assets WHERE object_key=$1`, key)
	return c.JSON(fiber.Map{"key": key, "deleted": true})
}
