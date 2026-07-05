package handlers

import (
	"context"

	"github.com/gofiber/fiber/v2"

	"github.com/onrol/lms-backend/internal/push"
)

// ListAnnouncements returns every announcement (staff view, newest first).
func (h *Handlers) ListAnnouncements(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT a.id, a.title, a.body, a.audience, a.batch_number, a.role, a.created_at,
		       COALESCE(u.full_name,''), COALESCE(c.title,'')
		FROM announcements a
		LEFT JOIN users u ON u.id=a.author_id
		LEFT JOIN courses c ON c.id=a.course_id
		ORDER BY a.created_at DESC LIMIT 200`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	return c.JSON(fiber.Map{"announcements": scanAnnouncements(rows)})
}

// DeleteAnnouncement removes an announcement (staff). It also clears any
// per-user notifications that were spawned from it is not needed — those are a
// separate feed — so this just drops the broadcast.
func (h *Handlers) DeleteAnnouncement(c *fiber.Ctx) error {
	id := c.Params("id")
	ct, err := h.Pool.Exec(c.Context(), `DELETE FROM announcements WHERE id=$1`, id)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "announcement not found")
	}
	return c.JSON(fiber.Map{"id": id, "deleted": true})
}

// MyAnnouncements returns announcements targeted at the caller: those for
// "all", for the caller's batch, for the caller's role, or course-scoped ones
// for courses the caller is enrolled in.
func (h *Handlers) MyAnnouncements(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT a.id, a.title, a.body, a.audience, a.batch_number, a.role, a.created_at,
		       COALESCE(au.full_name,''), COALESCE(c.title,'')
		FROM announcements a
		LEFT JOIN users au ON au.id=a.author_id
		LEFT JOIN courses c ON c.id=a.course_id
		JOIN users me ON me.id=$1
		WHERE (a.course_id IS NULL AND (
		         a.audience='all'
		      OR (a.audience='batch' AND a.batch_number = me.batch)
		      OR (a.audience='role'  AND a.role = me.role)))
		   OR (a.course_id IS NOT NULL AND EXISTS (
		         SELECT 1 FROM course_enrollments ce
		         WHERE ce.course_id=a.course_id AND ce.user_id=me.id))
		ORDER BY a.created_at DESC LIMIT 100`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	return c.JSON(fiber.Map{"announcements": scanAnnouncements(rows)})
}

// notify inserts a per-user notification (best-effort — never fails the caller)
// and fires a Web Push to that user's devices in the background.
func (h *Handlers) notify(c *fiber.Ctx, userID, title, body, kind string) {
	_, _ = h.Pool.Exec(c.Context(),
		`INSERT INTO notifications (user_id, title, body, kind) VALUES ($1,$2,$3,$4)`,
		userID, title, body, kind)
	if h.Push != nil {
		go h.Push.SendToUser(context.Background(), userID, push.Payload{Title: title, Body: body, URL: "/", Tag: kind})
	}
}

// MyNotifications returns the caller's personal notifications (newest first).
func (h *Handlers) MyNotifications(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT id, title, body, kind, read_at IS NOT NULL, created_at
		FROM notifications WHERE user_id=$1 ORDER BY created_at DESC LIMIT 100`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, body, kind string
		var read bool
		var at any
		if err := rows.Scan(&id, &title, &body, &kind, &read, &at); err != nil {
			continue
		}
		out = append(out, fiber.Map{"id": id, "title": title, "body": body, "kind": kind, "read": read, "at": at})
	}
	return c.JSON(fiber.Map{"notifications": out})
}

// MarkNotificationsRead marks all of the caller's notifications read.
func (h *Handlers) MarkNotificationsRead(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(),
		`UPDATE notifications SET read_at=now() WHERE user_id=$1 AND read_at IS NULL`, callerID(c)); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	return c.JSON(fiber.Map{"ok": true})
}

func scanAnnouncements(rows interface {
	Next() bool
	Scan(...any) error
}) []fiber.Map {
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, body, audience, author, course string
		var batch *int
		var role *string
		var at any
		if err := rows.Scan(&id, &title, &body, &audience, &batch, &role, &at, &author, &course); err != nil {
			continue
		}
		out = append(out, fiber.Map{"id": id, "title": title, "body": body, "audience": audience,
			"batch_number": batch, "role": role, "at": at, "author": author, "course": course})
	}
	return out
}
