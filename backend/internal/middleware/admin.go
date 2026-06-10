package middleware

import (
	"crypto/subtle"

	"github.com/gofiber/fiber/v2"
)

// RequireAdmin gates admin endpoints behind a shared secret in the X-Admin-Key
// header. Simple and sufficient at this scale; swap for a real admin-role JWT if
// you build an admin UI. If ADMIN_API_KEY is unset, admin routes are disabled.
func RequireAdmin(adminKey string) fiber.Handler {
	return func(c *fiber.Ctx) error {
		if adminKey == "" {
			return fiber.NewError(fiber.StatusNotFound, "admin API disabled")
		}
		got := c.Get("X-Admin-Key")
		if subtle.ConstantTimeCompare([]byte(got), []byte(adminKey)) != 1 {
			return fiber.NewError(fiber.StatusUnauthorized, "invalid admin key")
		}
		return c.Next()
	}
}
