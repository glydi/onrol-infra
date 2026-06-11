package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
)

// canAccessModule returns the module's course id if the caller may read/post in
// it — i.e. they're enrolled in the course OR they're course staff.
func (h *Handlers) canAccessModule(c *fiber.Ctx, moduleID string) (string, error) {
	var courseID string
	if err := h.Pool.QueryRow(c.Context(), `SELECT course_id FROM modules WHERE id=$1`, moduleID).Scan(&courseID); err != nil {
		return "", fiber.NewError(fiber.StatusNotFound, "module not found")
	}
	if h.isEnrolled(c, courseID) || h.canManageCourse(c, courseID) == nil {
		return courseID, nil
	}
	return "", fiber.NewError(fiber.StatusForbidden, "not enrolled")
}

// ListModuleComments returns the comment/doubt thread for a module (oldest first).
func (h *Handlers) ListModuleComments(c *fiber.Ctx) error {
	moduleID := c.Params("id")
	if _, err := h.canAccessModule(c, moduleID); err != nil {
		return err
	}
	rows, err := h.Pool.Query(c.Context(), `
		SELECT mc.id, mc.body, mc.is_doubt, mc.created_at,
		       COALESCE(u.full_name,'Someone'), COALESCE(u.role,'student')
		FROM module_comments mc LEFT JOIN users u ON u.id=mc.user_id
		WHERE mc.module_id=$1 ORDER BY mc.created_at`, moduleID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, body, author, role string
		var isDoubt bool
		var at any
		if err := rows.Scan(&id, &body, &isDoubt, &at, &author, &role); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		staff := role == "instructor" || role == "manager" || role == "superadmin"
		out = append(out, fiber.Map{"id": id, "body": body, "is_doubt": isDoubt, "at": at,
			"author": author, "staff": staff})
	}
	return c.JSON(fiber.Map{"comments": out})
}

// PostModuleComment adds a comment (or doubt) to a module thread.
func (h *Handlers) PostModuleComment(c *fiber.Ctx) error {
	moduleID := c.Params("id")
	if _, err := h.canAccessModule(c, moduleID); err != nil {
		return err
	}
	var req struct {
		Body    string `json:"body"`
		IsDoubt bool   `json:"is_doubt"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Body) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "body required")
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO module_comments (module_id, user_id, body, is_doubt) VALUES ($1,$2,$3,$4) RETURNING id`,
		moduleID, callerID(c), req.Body, req.IsDoubt).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "post failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}
