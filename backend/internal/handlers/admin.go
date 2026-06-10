package handlers

import (
	"crypto/rand"
	"encoding/hex"
	"strings"

	"github.com/gofiber/fiber/v2"
)

// CreateVideo registers a VOD and GENERATES its AES-128 key server-side. The key
// is returned ONCE (hex) so you can package the HLS with the matching key via
// scripts/package_hls.sh; it is never exposed again except to entitled players.
func (h *Handlers) CreateVideo(c *fiber.Ctx) error {
	var req struct {
		Title       string `json:"title"`
		HLSPath     string `json:"hls_path"`
		KeyID       string `json:"key_id"`
		IsPublished bool   `json:"is_published"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if req.Title == "" || req.HLSPath == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title and hls_path are required")
	}
	if req.KeyID == "" {
		req.KeyID = "k1"
	}

	key := make([]byte, 16) // AES-128
	if _, err := rand.Read(key); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "key gen failed")
	}

	var id string
	err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO videos (title, hls_path, encryption_key, key_id, is_published)
		 VALUES ($1,$2,$3,$4,$5) RETURNING id`,
		req.Title, req.HLSPath, key, req.KeyID, req.IsPublished,
	).Scan(&id)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{
		"id":      id,
		"key_id":  req.KeyID,
		"key_hex": hex.EncodeToString(key),
		"note":    "feed key_hex into scripts/package_hls.sh; it won't be shown again",
	})
}

// EnrollUser grants a user access to a video.
func (h *Handlers) EnrollUser(c *fiber.Ctx) error {
	var req struct {
		UserID  string `json:"user_id"`
		VideoID string `json:"video_id"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if req.UserID == "" || req.VideoID == "" {
		return fiber.NewError(fiber.StatusBadRequest, "user_id and video_id are required")
	}
	_, err := h.Pool.Exec(c.Context(),
		`INSERT INTO enrollments (user_id, video_id) VALUES ($1,$2)
		 ON CONFLICT DO NOTHING`, req.UserID, req.VideoID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "enroll failed")
	}
	return c.JSON(fiber.Map{"enrolled": true, "user_id": req.UserID, "video_id": req.VideoID})
}

// AdminDeleteAllCourses removes every course (and cascaded content). Gated by
// the admin key — superadmin-level, irreversible.
func (h *Handlers) AdminDeleteAllCourses(c *fiber.Ctx) error {
	tag, err := h.Pool.Exec(c.Context(), `DELETE FROM courses`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted_courses": tag.RowsAffected()})
}

// CreateWebinar stores the per-webinar Zoho tokens (copied from the embed form).
func (h *Handlers) CreateWebinar(c *fiber.Ctx) error {
	var req struct {
		Title          string `json:"title"`
		EmbedSessionID string `json:"embed_session_id"`
		WebformURL     string `json:"webform_url"`
		WebformSysID   string `json:"webform_sys_id"`
		WebformDigest  string `json:"webform_digest"`
		WebformEnc     string `json:"webform_enc"`
		ReturnURL      string `json:"return_url"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if strings.TrimSpace(req.Title) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title is required")
	}
	if req.EmbedSessionID == "" && req.WebformSysID == "" {
		return fiber.NewError(fiber.StatusBadRequest, "need embed_session_id or webform_sys_id")
	}

	var id string
	err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO webinars
		   (title, embed_session_id, webform_url, webform_sys_id, webform_digest, webform_enc, return_url)
		 VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
		req.Title, req.EmbedSessionID, req.WebformURL, req.WebformSysID,
		req.WebformDigest, req.WebformEnc, req.ReturnURL,
	).Scan(&id)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "title": req.Title})
}
