package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
)

// ResumeLearning returns the next incomplete lesson to continue for EACH of the
// caller's enrolled courses (newest first) — so they can pick up any course in
// one tap — plus a single `resume` (the most recent course) for compatibility.
func (h *Handlers) ResumeLearning(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT c.id, c.title, COALESCE(c.image_url,''),
		  (SELECT count(*) FROM lessons l JOIN modules m ON m.id=l.module_id WHERE m.course_id=c.id) AS total,
		  (SELECT count(*) FROM lesson_progress lp JOIN lessons l ON l.id=lp.lesson_id
		     JOIN modules m ON m.id=l.module_id WHERE m.course_id=c.id AND lp.user_id=$1) AS done,
		  nl.id, nl.title, nl.type, COALESCE(nl.body,''), COALESCE(nm.title,'')
		FROM course_enrollments ce
		JOIN courses c ON c.id=ce.course_id
		LEFT JOIN LATERAL (
		  SELECT l.id, l.title, l.type, l.body, l.module_id
		  FROM lessons l JOIN modules m ON m.id=l.module_id
		  WHERE m.course_id=c.id
		    AND NOT EXISTS (SELECT 1 FROM lesson_progress lp WHERE lp.user_id=$1 AND lp.lesson_id=l.id)
		  ORDER BY m.position, l.position
		  LIMIT 1
		) nl ON TRUE
		LEFT JOIN modules nm ON nm.id=nl.module_id
		WHERE ce.user_id=$1
		ORDER BY ce.enrolled_at DESC`, callerID(c))
	if err != nil {
		return c.JSON(fiber.Map{"resume": nil, "courses": []fiber.Map{}})
	}
	defer rows.Close()

	courses := []fiber.Map{}
	var first fiber.Map
	for rows.Next() {
		var courseID, course, img string
		var total, done int
		var lessonID, title, ltype, body, module *string
		if err := rows.Scan(&courseID, &course, &img, &total, &done, &lessonID, &title, &ltype, &body, &module); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		if lessonID == nil {
			continue // course fully complete — nothing left to resume
		}
		pct := 0
		if total > 0 {
			pct = done * 100 / total
		}
		entry := fiber.Map{
			"course_id": courseID, "course": course, "image_url": img,
			"total": total, "done": done, "percent": pct,
			"lesson_id": *lessonID, "title": derefStr(title), "type": derefStr(ltype),
			"url": derefStr(body), "module": derefStr(module),
		}
		courses = append(courses, entry)
		if first == nil {
			first = entry
		}
	}

	var resume any
	if first != nil {
		resume = fiber.Map{
			"lesson_id": first["lesson_id"], "title": first["title"], "type": first["type"], "url": first["url"],
			"course": first["course"], "course_id": first["course_id"], "module": first["module"],
		}
	}
	return c.JSON(fiber.Map{"resume": resume, "courses": courses})
}

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

// ListCourseComments returns every module comment/doubt across a course, for
// course staff (the admin/instructor "Doubts & Discussion" view). Doubts first,
// then newest. Each row carries its module so staff know where it was asked.
func (h *Handlers) ListCourseComments(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	rows, err := h.Pool.Query(c.Context(), `
		SELECT mc.id, mc.module_id, COALESCE(m.title,''), mc.body, mc.is_doubt, mc.created_at,
		       COALESCE(u.full_name,'Someone'), COALESCE(u.role,'student')
		FROM module_comments mc
		JOIN modules m ON m.id=mc.module_id
		LEFT JOIN users u ON u.id=mc.user_id
		WHERE m.course_id=$1
		ORDER BY mc.is_doubt DESC, mc.created_at DESC`, courseID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, moduleID, module, body, author, role string
		var isDoubt bool
		var at any
		if err := rows.Scan(&id, &moduleID, &module, &body, &isDoubt, &at, &author, &role); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		staff := role == "instructor" || role == "manager" || role == "superadmin"
		out = append(out, fiber.Map{"id": id, "module_id": moduleID, "module": module,
			"body": body, "is_doubt": isDoubt, "at": at, "author": author, "staff": staff})
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
