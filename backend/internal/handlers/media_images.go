package handlers

import (
	"context"
	"path"
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
	"github.com/minio/minio-go/v7"
)

// --- Image library (R2-backed) ---------------------------------------------
// A sibling of the video store for reusable images (thumbnails, banners, art).
// No transcode step — the object is served straight from R2 by its public URL.

// UploadImage stores an uploaded image in R2 and records it in image_assets.
func (h *Handlers) UploadImage(c *fiber.Ctx) error {
	if !h.Cfg.R2.Enabled() {
		return fiber.NewError(fiber.StatusServiceUnavailable, "image storage (R2) is not configured")
	}
	fh, err := c.FormFile("file")
	if err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "file is required")
	}
	ct := fh.Header.Get("Content-Type")
	if ct == "" || !strings.HasPrefix(ct, "image/") {
		// Fall back to the extension; reject clearly non-images.
		switch strings.ToLower(path.Ext(fh.Filename)) {
		case ".png":
			ct = "image/png"
		case ".jpg", ".jpeg":
			ct = "image/jpeg"
		case ".gif":
			ct = "image/gif"
		case ".webp":
			ct = "image/webp"
		case ".svg":
			ct = "image/svg+xml"
		default:
			return fiber.NewError(fiber.StatusBadRequest, "not an image file")
		}
	}
	title := strings.TrimSpace(c.FormValue("title"))
	if title == "" {
		title = fh.Filename
	}
	folderID := strings.TrimSpace(c.FormValue("folder_id"))

	f, err := fh.Open()
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "could not read upload")
	}
	defer f.Close()

	key := "images/" + uuid.NewString() + path.Ext(fh.Filename)
	cl, err := h.r2client()
	if err != nil {
		return fiber.NewError(fiber.StatusServiceUnavailable, "R2 unavailable")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	if _, err := cl.PutObject(ctx, h.Cfg.R2.Bucket, key, f, fh.Size, minio.PutObjectOptions{ContentType: ct}); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "upload failed: "+err.Error())
	}
	imgURL := strings.TrimRight(h.Cfg.R2.PublicBase, "/") + "/" + key

	var folder any
	if folderID != "" {
		folder = folderID
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO image_assets (title, object_key, url, content_type, size_bytes, folder_id, created_by)
		 VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
		title, key, imgURL, ct, fh.Size, folder, callerID(c)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "saved to R2 but DB record failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "title": title, "url": imgURL, "size_bytes": fh.Size})
}

// ListImages returns the image library, newest first.
func (h *Handlers) ListImages(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, title, url, COALESCE(content_type,''), size_bytes, created_at, COALESCE(folder_id::text,'')
		   FROM image_assets ORDER BY created_at DESC LIMIT 1000`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, imgURL, ctype, folderID string
		var size int64
		var created any
		if err := rows.Scan(&id, &title, &imgURL, &ctype, &size, &created, &folderID); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "title": title, "url": imgURL, "content_type": ctype,
			"size_bytes": size, "created_at": created, "folder_id": folderID})
	}
	return c.JSON(fiber.Map{"images": out, "r2_enabled": h.Cfg.R2.Enabled()})
}

// RenameImage updates an image's display title.
func (h *Handlers) RenameImage(c *fiber.Ctx) error {
	var req struct {
		Title string `json:"title"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Title) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title required")
	}
	ct, err := h.Pool.Exec(c.Context(), `UPDATE image_assets SET title=$2 WHERE id=$1`, c.Params("id"), strings.TrimSpace(req.Title))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "rename failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "not found")
	}
	return c.JSON(fiber.Map{"ok": true})
}

// DeleteImage removes an image from the library (and best-effort from R2).
func (h *Handlers) DeleteImage(c *fiber.Ctx) error {
	id := c.Params("id")
	var key string
	if err := h.Pool.QueryRow(c.Context(), `SELECT object_key FROM image_assets WHERE id=$1`, id).Scan(&key); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "not found")
	}
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM image_assets WHERE id=$1`, id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	if cl, err := h.r2client(); err == nil && key != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		_ = cl.RemoveObject(ctx, h.Cfg.R2.Bucket, key, minio.RemoveObjectOptions{})
	}
	return c.JSON(fiber.Map{"ok": true})
}

// MoveImage moves an image into a folder (folder_id empty = unfile it).
func (h *Handlers) MoveImage(c *fiber.Ctx) error {
	var req struct {
		FolderID string `json:"folder_id"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "bad request")
	}
	var folder any
	if f := strings.TrimSpace(req.FolderID); f != "" {
		folder = f
	}
	ct, err := h.Pool.Exec(c.Context(), `UPDATE image_assets SET folder_id=$2 WHERE id=$1`, c.Params("id"), folder)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "move failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "not found")
	}
	return c.JSON(fiber.Map{"ok": true})
}

// --- Image-library folders (mirror of the video-store folders) --------------

func (h *Handlers) ListImageFolders(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT f.id, f.name,
		        (SELECT count(*) FROM image_assets a WHERE a.folder_id=f.id) AS images
		   FROM image_folders f ORDER BY lower(f.name)`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name string
		var count int
		if err := rows.Scan(&id, &name, &count); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "name": name, "images": count})
	}
	return c.JSON(fiber.Map{"folders": out})
}

func (h *Handlers) CreateImageFolder(c *fiber.Ctx) error {
	var req struct {
		Name string `json:"name"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO image_folders (name) VALUES ($1) RETURNING id`, strings.TrimSpace(req.Name)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "name": strings.TrimSpace(req.Name)})
}

func (h *Handlers) RenameImageFolder(c *fiber.Ctx) error {
	var req struct {
		Name string `json:"name"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	ct, err := h.Pool.Exec(c.Context(), `UPDATE image_folders SET name=$2 WHERE id=$1`, c.Params("id"), strings.TrimSpace(req.Name))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "rename failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "not found")
	}
	return c.JSON(fiber.Map{"ok": true})
}

func (h *Handlers) DeleteImageFolder(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM image_folders WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"ok": true})
}
