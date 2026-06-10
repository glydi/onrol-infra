package handlers

import (
	"errors"

	"github.com/gofiber/fiber/v2"
	"github.com/jackc/pgx/v5"

	"github.com/onrol/lms-backend/internal/middleware"
)

// HLSKey serves the raw 16-byte AES-128 key for a video, but only to an
// authenticated, active device whose user is enrolled. Every delivery is logged
// for forensics. This is a deterrent against casual ripping — NOT DRM (see
// ARCHITECTURE.md §2.2): a rooted device can still extract the key from memory.
func (h *Handlers) HLSKey(c *fiber.Ctx) error {
	userID := c.Locals(middleware.LocalUserID).(string)
	deviceID := c.Locals(middleware.LocalDeviceID).(string)
	videoID := c.Params("video_id")

	// Enrollment + published check, key fetch — all in one query.
	var key []byte
	err := h.Pool.QueryRow(c.Context(),
		`SELECT v.encryption_key
		   FROM videos v
		   JOIN enrollments e ON e.video_id = v.id
		  WHERE v.id = $1 AND e.user_id = $2 AND v.is_published`,
		videoID, userID,
	).Scan(&key)
	if errors.Is(err, pgx.ErrNoRows) {
		// Don't leak whether the video exists vs. the user isn't enrolled.
		return fiber.NewError(fiber.StatusForbidden, "not entitled to this video")
	}
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "key lookup failed")
	}

	// Forensic log (best-effort; never block playback on a log write failure).
	_, _ = h.Pool.Exec(c.Context(),
		`INSERT INTO key_access_log (user_id, device_id, video_id, ip, user_agent)
		 VALUES ($1, $2, $3, $4, $5)`,
		userID, deviceID, videoID, c.IP(), c.Get("User-Agent"))

	c.Set("Content-Type", "application/octet-stream")
	c.Set("Cache-Control", "no-store")
	return c.Send(key)
}
