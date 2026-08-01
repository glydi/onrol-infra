package handlers

import (
	"crypto/subtle"
	"strings"

	"github.com/gofiber/fiber/v2"
)

// RelayStreamKey is called by the MediaMTX relay (from localhost) when a host
// starts publishing to path `live-<sessionId>`. It returns that session's
// YouTube stream key so the relay's ffmpeg can push RTMP to YouTube. Gated by a
// shared secret (RELAY_SECRET) so only the relay can read keys.
func (h *Handlers) RelayStreamKey(c *fiber.Ctx) error {
	secret := h.Cfg.RelaySecret
	if secret == "" {
		return fiber.NewError(fiber.StatusServiceUnavailable, "relay not configured")
	}
	tok := c.Query("token")
	if subtle.ConstantTimeCompare([]byte(tok), []byte(secret)) != 1 {
		return fiber.NewError(fiber.StatusUnauthorized, "bad token")
	}
	sid := c.Params("id")
	var key string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT COALESCE(yt_stream_key,'') FROM class_sessions WHERE id=$1`, sid).Scan(&key); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "session not found")
	}
	key = strings.TrimSpace(key)
	if key == "" {
		return fiber.NewError(fiber.StatusNotFound, "no stream key")
	}
	// Plain text — the relay reads the raw body as the key.
	c.Set("Content-Type", "text/plain")
	return c.SendString(key)
}
