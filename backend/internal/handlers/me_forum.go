package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
)

// Discussion forum for learners: threads live under a course; everyone enrolled
// in that course (plus course staff) can read and post. These endpoints back the
// student "Discussion Forum" panel.

// ListForum returns recent threads across the courses the caller is enrolled in,
// newest-activity first, with author, course, reply count and a snippet.
func (h *Handlers) ListForum(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT t.id, t.title, t.course_id, COALESCE(c.title,'General'),
		       COALESCE(u.full_name,'Someone'), COALESCE(u.avatar,''),
		       t.created_at,
		       (SELECT count(*) FROM forum_posts p WHERE p.thread_id=t.id) AS posts,
		       COALESCE((SELECT max(created_at) FROM forum_posts p WHERE p.thread_id=t.id), t.created_at) AS last_at,
		       COALESCE((SELECT body FROM forum_posts p WHERE p.thread_id=t.id ORDER BY created_at LIMIT 1),'') AS snippet
		FROM forum_threads t
		LEFT JOIN courses c ON c.id=t.course_id
		LEFT JOIN users u ON u.id=t.author_id
		WHERE t.course_id IS NULL
		   OR EXISTS (SELECT 1 FROM course_enrollments ce WHERE ce.course_id=t.course_id AND ce.user_id=$1)
		   OR $2 <> 'student'
		ORDER BY last_at DESC
		LIMIT 100`, callerID(c), callerRole(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, course, author, avatar, snippet string
		var courseID *string
		var createdAt, lastAt any
		var posts int
		if err := rows.Scan(&id, &title, &courseID, &course, &author, &avatar, &createdAt, &posts, &lastAt, &snippet); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		// posts includes the opening post; replies = posts-1 (never negative).
		replies := posts - 1
		if replies < 0 {
			replies = 0
		}
		out = append(out, fiber.Map{
			"id": id, "title": title, "course_id": derefStr(courseID), "course": course,
			"author": author, "avatar": avatar, "snippet": snippet,
			"replies": replies, "created_at": createdAt, "last_at": lastAt,
		})
	}
	return c.JSON(fiber.Map{"forum": out})
}

// GetForumThread returns a thread and all its posts (oldest first).
func (h *Handlers) GetForumThread(c *fiber.Ctx) error {
	threadID := c.Params("id")
	var title, course string
	var courseID *string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT t.title, t.course_id, COALESCE(c.title,'General') FROM forum_threads t LEFT JOIN courses c ON c.id=t.course_id WHERE t.id=$1`,
		threadID).Scan(&title, &courseID, &course); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "thread not found")
	}
	// General threads (course_id NULL) are open to everyone; course threads gate on enrolment.
	if courseID != nil && !h.isEnrolled(c, *courseID) && callerRole(c) == "student" {
		return fiber.NewError(fiber.StatusForbidden, "not enrolled")
	}
	rows, err := h.Pool.Query(c.Context(), `
		SELECT p.id, p.body, p.created_at, COALESCE(u.full_name,'Someone'), COALESCE(u.avatar,''), COALESCE(u.role,'student')
		FROM forum_posts p LEFT JOIN users u ON u.id=p.author_id
		WHERE p.thread_id=$1 ORDER BY p.created_at`, threadID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "load failed")
	}
	defer rows.Close()
	posts := []fiber.Map{}
	for rows.Next() {
		var id, body, author, avatar, role string
		var at any
		if err := rows.Scan(&id, &body, &at, &author, &avatar, &role); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		staff := role == "instructor" || role == "manager" || role == "superadmin"
		posts = append(posts, fiber.Map{"id": id, "body": body, "at": at, "author": author, "avatar": avatar, "staff": staff})
	}
	return c.JSON(fiber.Map{"id": threadID, "title": title, "course": course, "course_id": courseID, "posts": posts})
}

// CreateForumThread starts a new thread (with its opening post) in a course.
func (h *Handlers) CreateForumThread(c *fiber.Ctx) error {
	var req struct {
		CourseID string `json:"course_id"`
		Title    string `json:"title"`
		Body     string `json:"body"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	req.Title = strings.TrimSpace(req.Title)
	req.Body = strings.TrimSpace(req.Body)
	if req.Title == "" || req.Body == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title and message are required")
	}
	// Empty course = a General thread (no course). Course threads gate on enrolment.
	var courseArg any
	if req.CourseID != "" {
		if !h.isEnrolled(c, req.CourseID) && callerRole(c) == "student" {
			return fiber.NewError(fiber.StatusForbidden, "not enrolled in this course")
		}
		courseArg = req.CourseID
	}
	var threadID string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO forum_threads (course_id, author_id, title) VALUES ($1,$2,$3) RETURNING id`,
		courseArg, callerID(c), req.Title).Scan(&threadID); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "thread failed")
	}
	if _, err := h.Pool.Exec(c.Context(),
		`INSERT INTO forum_posts (thread_id, author_id, body) VALUES ($1,$2,$3)`,
		threadID, callerID(c), req.Body); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "post failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"thread_id": threadID})
}

// ReplyForum appends a reply to a thread.
func (h *Handlers) ReplyForum(c *fiber.Ctx) error {
	threadID := c.Params("id")
	var courseID *string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT course_id FROM forum_threads WHERE id=$1`, threadID).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "thread not found")
	}
	if courseID != nil && !h.isEnrolled(c, *courseID) && callerRole(c) == "student" {
		return fiber.NewError(fiber.StatusForbidden, "not enrolled")
	}
	var req struct {
		Body string `json:"body"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Body) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "message required")
	}
	if _, err := h.Pool.Exec(c.Context(),
		`INSERT INTO forum_posts (thread_id, author_id, body) VALUES ($1,$2,$3)`,
		threadID, callerID(c), strings.TrimSpace(req.Body)); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "reply failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"posted": true})
}
