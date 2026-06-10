package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
)

// canAccessCourse: enrolled students OR staff who can manage the course.
func (h *Handlers) canAccessCourse(c *fiber.Ctx, courseID string) bool {
	if callerRole(c) == "superadmin" || callerRole(c) == "manager" {
		return true
	}
	if h.canManageCourse(c, courseID) == nil { // instructor owner
		return true
	}
	return h.isEnrolled(c, courseID)
}

// ListDiscussion returns the course's doubts/discussion as threaded posts.
func (h *Handlers) ListDiscussion(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if !h.canAccessCourse(c, courseID) {
		return fiber.NewError(fiber.StatusForbidden, "not part of this course")
	}
	rows, err := h.Pool.Query(c.Context(), `
		SELECT d.id, COALESCE(d.parent_id::text,''), COALESCE(u.full_name,'Someone'),
		       COALESCE(u.role,'student'), d.body, d.created_at
		FROM course_discussion d LEFT JOIN users u ON u.id = d.user_id
		WHERE d.course_id = $1 ORDER BY d.created_at`, courseID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "load failed")
	}
	defer rows.Close()
	// Build top-level posts with nested replies.
	type post struct {
		fiber.Map
		replies []fiber.Map
	}
	posts := map[string]*post{}
	order := []string{}
	replies := []fiber.Map{}
	for rows.Next() {
		var id, parent, author, role, body string
		var at any
		if err := rows.Scan(&id, &parent, &author, &role, &body, &at); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		m := fiber.Map{"id": id, "author": author, "role": role, "body": body, "created_at": at, "is_staff": role != "student"}
		if parent == "" {
			posts[id] = &post{Map: m, replies: []fiber.Map{}}
			order = append(order, id)
		} else {
			m["parent_id"] = parent
			replies = append(replies, m)
		}
	}
	for _, r := range replies {
		if p, ok := posts[r["parent_id"].(string)]; ok {
			p.replies = append(p.replies, r)
		}
	}
	out := make([]fiber.Map, 0, len(order))
	for _, id := range order {
		p := posts[id]
		p.Map["replies"] = p.replies
		out = append(out, p.Map)
	}
	return c.JSON(fiber.Map{"discussion": out})
}

// PostDiscussion adds a post (a doubt/comment) or a reply (parent_id set).
func (h *Handlers) PostDiscussion(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if !h.canAccessCourse(c, courseID) {
		return fiber.NewError(fiber.StatusForbidden, "not part of this course")
	}
	var req struct {
		Body     string `json:"body"`
		ParentID string `json:"parent_id"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Body) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "body required")
	}
	var parent any
	if req.ParentID != "" {
		parent = req.ParentID
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO course_discussion (course_id, user_id, parent_id, body) VALUES ($1,$2,$3,$4) RETURNING id`,
		courseID, callerID(c), parent, strings.TrimSpace(req.Body)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "post failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}
