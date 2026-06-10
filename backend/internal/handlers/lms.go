package handlers

import (
	"context"

	"github.com/gofiber/fiber/v2"

	"github.com/onrol/lms-backend/internal/middleware"
)

// callerID / callerRole read what RequireAuth stashed on the request.
func callerID(c *fiber.Ctx) string {
	id, _ := c.Locals(middleware.LocalUserID).(string)
	return id
}
func callerRole(c *fiber.Ctx) string {
	r, _ := c.Locals(middleware.LocalRole).(string)
	return r
}

// managerCovers reports whether a manager's scope includes a group — i.e. the
// group is directly scoped to them or is a descendant of a scoped group.
// Superadmins are handled by callers (they bypass scope entirely).
func (h *Handlers) managerCovers(ctx context.Context, managerID, groupID string) (bool, error) {
	if groupID == "" {
		return false, nil
	}
	var covered bool
	err := h.Pool.QueryRow(ctx, `
		WITH RECURSIVE scope AS (
			SELECT group_id FROM manager_scopes WHERE user_id=$1
			UNION
			SELECT g.id FROM groups g JOIN scope s ON g.parent_id = s.group_id
		)
		SELECT EXISTS(SELECT 1 FROM scope WHERE group_id=$2)`,
		managerID, groupID,
	).Scan(&covered)
	return covered, err
}

// requireGroupScope enforces that the caller may act on the given group:
// superadmin always may; a manager may only within their scope. Returns a Fiber
// error to return directly, or nil if allowed.
func (h *Handlers) requireGroupScope(c *fiber.Ctx, groupID string) error {
	if callerRole(c) == "superadmin" {
		return nil
	}
	if callerRole(c) != "manager" {
		return fiber.NewError(fiber.StatusForbidden, "requires manager role")
	}
	ok, err := h.managerCovers(c.Context(), callerID(c), groupID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "scope check failed")
	}
	if !ok {
		return fiber.NewError(fiber.StatusForbidden, "group is outside your managed scope")
	}
	return nil
}

// canManageCourse: superadmin and manager (the LMS admin) can edit ANY course;
// an instructor can edit only courses they own.
func (h *Handlers) canManageCourse(c *fiber.Ctx, courseID string) error {
	if callerRole(c) == "superadmin" || callerRole(c) == "manager" {
		return nil
	}
	var ownerID, groupID string
	err := h.Pool.QueryRow(c.Context(),
		`SELECT COALESCE(owner_id::text,''), COALESCE(group_id::text,'') FROM courses WHERE id=$1`,
		courseID,
	).Scan(&ownerID, &groupID)
	if err != nil {
		return fiber.NewError(fiber.StatusNotFound, "course not found")
	}
	if ownerID != "" && ownerID == callerID(c) {
		return nil
	}
	if callerRole(c) == "manager" && groupID != "" {
		if ok, _ := h.managerCovers(c.Context(), callerID(c), groupID); ok {
			return nil
		}
	}
	return fiber.NewError(fiber.StatusForbidden, "not allowed to manage this course")
}
