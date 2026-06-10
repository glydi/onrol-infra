package handlers

import (
	"context"
	"time"

	"github.com/gofiber/fiber/v2"
)

// Healthz is a liveness + DB-readiness probe.
func (h *Handlers) Healthz(c *fiber.Ctx) error {
	ctx, cancel := context.WithTimeout(c.Context(), 2*time.Second)
	defer cancel()
	if err := h.Pool.Ping(ctx); err != nil {
		return c.Status(fiber.StatusServiceUnavailable).JSON(fiber.Map{
			"status": "degraded",
			"db":     "down",
		})
	}
	return c.JSON(fiber.Map{"status": "ok", "db": "up"})
}
