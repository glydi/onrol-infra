package handlers

import (
	"context"

	"github.com/gofiber/fiber/v2"

	"github.com/onrol/lms-backend/internal/push"
)

// PushPublicKey returns the server's VAPID public key so the browser can
// subscribe. `enabled:false` tells the client Web Push isn't available.
func (h *Handlers) PushPublicKey(c *fiber.Ctx) error {
	if h.Push == nil {
		return c.JSON(fiber.Map{"enabled": false, "public_key": ""})
	}
	return c.JSON(fiber.Map{"enabled": true, "public_key": h.Push.PublicKey()})
}

// PushSubscribe stores the caller's browser push subscription.
func (h *Handlers) PushSubscribe(c *fiber.Ctx) error {
	if h.Push == nil {
		return fiber.NewError(fiber.StatusServiceUnavailable, "push not available")
	}
	var req struct {
		Endpoint string `json:"endpoint"`
		Keys     struct {
			P256dh string `json:"p256dh"`
			Auth   string `json:"auth"`
		} `json:"keys"`
	}
	if err := c.BodyParser(&req); err != nil || req.Endpoint == "" || req.Keys.P256dh == "" || req.Keys.Auth == "" {
		return fiber.NewError(fiber.StatusBadRequest, "endpoint and keys required")
	}
	if err := h.Push.Subscribe(c.Context(), callerID(c), req.Endpoint, req.Keys.P256dh, req.Keys.Auth); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "subscribe failed")
	}
	return c.JSON(fiber.Map{"subscribed": true})
}

// PushUnsubscribe drops a subscription (e.g. the user turned push off).
func (h *Handlers) PushUnsubscribe(c *fiber.Ctx) error {
	if h.Push == nil {
		return c.JSON(fiber.Map{"unsubscribed": true})
	}
	var req struct {
		Endpoint string `json:"endpoint"`
	}
	if err := c.BodyParser(&req); err != nil || req.Endpoint == "" {
		return fiber.NewError(fiber.StatusBadRequest, "endpoint required")
	}
	_ = h.Push.Unsubscribe(c.Context(), req.Endpoint)
	return c.JSON(fiber.Map{"unsubscribed": true})
}

// pushAudience resolves an announcement's audience to user IDs and pushes to
// them. Runs in its own goroutine (background ctx) — never blocks the request.
func (h *Handlers) pushAnnouncement(courseID, audience, title, body string, batch *string, role string) {
	if h.Push == nil {
		return
	}
	ctx := context.Background()
	payload := push.Payload{Title: title, Body: body, URL: "/", Tag: "announcement"}
	if courseID != "" {
		ids := h.collectIDs(ctx, `SELECT user_id FROM course_enrollments WHERE course_id=$1 AND status='active'`, courseID)
		h.Push.SendToUsers(ctx, ids, payload)
		return
	}
	switch audience {
	case "batch":
		if batch != nil {
			ids := h.collectIDs(ctx, `SELECT id FROM users WHERE batch=$1 AND is_active`, *batch)
			h.Push.SendToUsers(ctx, ids, payload)
		}
	case "role":
		if role != "" {
			ids := h.collectIDs(ctx, `SELECT id FROM users WHERE role=$1 AND is_active`, role)
			h.Push.SendToUsers(ctx, ids, payload)
		}
	default: // all
		h.Push.SendToAll(ctx, payload)
	}
}

// collectIDs runs a one-column id query and returns the values.
func (h *Handlers) collectIDs(ctx context.Context, query string, args ...any) []string {
	rows, err := h.Pool.Query(ctx, query, args...)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	return ids
}
