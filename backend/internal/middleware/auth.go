package middleware

import (
	"context"
	"strings"

	"github.com/gofiber/fiber/v2"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/onrol/lms-backend/internal/auth"
)

// Context keys for values stashed on the Fiber request locals.
const (
	LocalUserID   = "user_id"
	LocalDeviceID = "device_id"
	LocalRole     = "role"
)

// RequireAuth validates the Bearer JWT, confirms the token's device matches the
// X-Device-UUID header, and confirms that device is still active for the user.
// This is what stops a leaked token from being replayed after a device is
// revoked.
func RequireAuth(jwtm *auth.Manager, pool *pgxpool.Pool) fiber.Handler {
	return func(c *fiber.Ctx) error {
		raw := c.Get("Authorization")
		if !strings.HasPrefix(raw, "Bearer ") {
			return fiber.NewError(fiber.StatusUnauthorized, "missing bearer token")
		}
		claims, err := jwtm.Parse(strings.TrimPrefix(raw, "Bearer "))
		if err != nil {
			return fiber.NewError(fiber.StatusUnauthorized, "invalid token")
		}

		// The token is bound to a device; the request must present the same one.
		if hdr := c.Get("X-Device-UUID"); hdr == "" || hdr != claims.DeviceID {
			return fiber.NewError(fiber.StatusUnauthorized, "device mismatch")
		}

		// The device must still be active, and we load the user's current role in
		// the same round-trip so role changes take effect without re-login.
		var active bool
		var role string
		err = pool.QueryRow(context.Background(),
			`SELECT d.is_active, u.role
			   FROM devices d JOIN users u ON u.id = d.user_id
			  WHERE d.user_id=$1 AND d.device_id=$2`,
			claims.UserID, claims.DeviceID,
		).Scan(&active, &role)
		if err != nil || !active {
			return fiber.NewError(fiber.StatusUnauthorized, "device not active")
		}

		c.Locals(LocalUserID, claims.UserID)
		c.Locals(LocalDeviceID, claims.DeviceID)
		c.Locals(LocalRole, role)
		return c.Next()
	}
}

// RequireToken validates the JWT and sets the caller, but SKIPS the per-request
// X-Device-UUID header check. It's for sub-resources the in-browser player fetches
// itself (the AES-128 HLS key), where hls.js can only attach the bearer token, not
// our device header — without this the key request 401s and encrypted HLS won't
// play. The key is a deterrent, not DRM, so a valid logged-in token suffices.
func RequireToken(jwtm *auth.Manager) fiber.Handler {
	return func(c *fiber.Ctx) error {
		raw := c.Get("Authorization")
		if !strings.HasPrefix(raw, "Bearer ") {
			return fiber.NewError(fiber.StatusUnauthorized, "missing bearer token")
		}
		claims, err := jwtm.Parse(strings.TrimPrefix(raw, "Bearer "))
		if err != nil {
			return fiber.NewError(fiber.StatusUnauthorized, "invalid token")
		}
		c.Locals(LocalUserID, claims.UserID)
		c.Locals(LocalDeviceID, claims.DeviceID)
		return c.Next()
	}
}

// roleRank orders roles for "at least" checks.
var roleRank = map[string]int{"student": 0, "instructor": 1, "manager": 2, "superadmin": 3}

// RequireRole allows the request only if the caller's role is at least `min`.
// Must run after RequireAuth (it reads the role from locals).
func RequireRole(min string) fiber.Handler {
	want := roleRank[min]
	return func(c *fiber.Ctx) error {
		role, _ := c.Locals(LocalRole).(string)
		if roleRank[role] < want {
			return fiber.NewError(fiber.StatusForbidden, "requires "+min+" role")
		}
		return c.Next()
	}
}

// RequireAnyRole allows the request if the caller holds one of the listed
// (parallel, non-hierarchical) portal roles — OR is an admin (manager /
// superadmin), who can access every portal. Used to gate the per-portal
// self-service endpoints (Ambassador, Franchise Partner, …).
func RequireAnyRole(roles ...string) fiber.Handler {
	allowed := map[string]bool{"manager": true, "superadmin": true}
	for _, r := range roles {
		allowed[r] = true
	}
	return func(c *fiber.Ctx) error {
		role, _ := c.Locals(LocalRole).(string)
		if !allowed[role] {
			return fiber.NewError(fiber.StatusForbidden, "not permitted for your role")
		}
		return c.Next()
	}
}
