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
	caller := callerID(c)
	rows, err := h.Pool.Query(c.Context(), `
		SELECT t.id, t.title, t.course_id, COALESCE(c.title,'General'),
		       COALESCE(u.full_name,'Someone'), COALESCE(u.avatar,''),
		       t.created_at, t.author_id,
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
		LIMIT 100`, caller, callerRole(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	staffMod := callerRole(c) == "instructor" || callerRole(c) == "manager" || callerRole(c) == "superadmin"
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, course, author, avatar, snippet string
		var courseID, authorID *string
		var createdAt, lastAt any
		var posts int
		if err := rows.Scan(&id, &title, &courseID, &course, &author, &avatar, &createdAt, &authorID, &posts, &lastAt, &snippet); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		// posts includes the opening post; replies = posts-1 (never negative).
		replies := posts - 1
		if replies < 0 {
			replies = 0
		}
		// "mine" → the caller authored it, so they (and staff) may delete it.
		mine := authorID != nil && *authorID == caller
		out = append(out, fiber.Map{
			"id": id, "title": title, "course_id": derefStr(courseID), "course": course,
			"author": author, "avatar": avatar, "snippet": snippet,
			"replies": replies, "created_at": createdAt, "last_at": lastAt,
			"mine": mine, "can_delete": mine || staffMod,
		})
	}
	return c.JSON(fiber.Map{"forum": out})
}

// GetForumThread returns a thread and all its posts (oldest first).
func (h *Handlers) GetForumThread(c *fiber.Ctx) error {
	threadID := c.Params("id")
	var title, course, authorID string
	var courseID *string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT t.title, t.course_id, COALESCE(c.title,'General'), t.author_id FROM forum_threads t LEFT JOIN courses c ON c.id=t.course_id WHERE t.id=$1`,
		threadID).Scan(&title, &courseID, &course, &authorID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "thread not found")
	}
	// General threads (course_id NULL) are open to everyone; course threads gate on enrolment.
	if courseID != nil && !h.isEnrolled(c, *courseID) && callerRole(c) == "student" {
		return fiber.NewError(fiber.StatusForbidden, "not enrolled")
	}
	rows, err := h.Pool.Query(c.Context(), `
		SELECT p.id, p.body, p.created_at, COALESCE(u.full_name,'Someone'), COALESCE(u.avatar,''), COALESCE(u.role,'student'), p.author_id
		FROM forum_posts p LEFT JOIN users u ON u.id=p.author_id
		WHERE p.thread_id=$1 ORDER BY p.created_at`, threadID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "load failed")
	}
	defer rows.Close()
	caller := callerID(c)
	role := callerRole(c)
	staffMod := role == "instructor" || role == "manager" || role == "superadmin"
	posts := []fiber.Map{}
	idx := 0
	for rows.Next() {
		var id, body, author, avatar, prole, postAuthor string
		var at any
		if err := rows.Scan(&id, &body, &at, &author, &avatar, &prole, &postAuthor); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		staff := prole == "instructor" || prole == "manager" || prole == "superadmin"
		mine := postAuthor == caller
		// The opening post (idx 0) is deleted by deleting the whole discussion;
		// replies are individually deletable by their author (or staff).
		canDel := idx > 0 && (mine || staffMod)
		posts = append(posts, fiber.Map{"id": id, "body": body, "at": at, "author": author, "avatar": avatar, "staff": staff, "mine": mine, "can_delete": canDel})
		idx++
	}
	canDelete := authorID == caller || staffMod
	return c.JSON(fiber.Map{"id": threadID, "title": title, "course": course, "course_id": courseID, "posts": posts, "can_delete": canDelete})
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
	// Create the thread AND its opening post atomically, so a discussion is
	// never half-saved (a thread with no body).
	tx, err := h.Pool.Begin(c.Context())
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "thread failed")
	}
	defer tx.Rollback(c.Context()) //nolint:errcheck // no-op after commit
	var threadID string
	if err := tx.QueryRow(c.Context(),
		`INSERT INTO forum_threads (course_id, author_id, title) VALUES ($1,$2,$3) RETURNING id`,
		courseArg, callerID(c), req.Title).Scan(&threadID); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "thread failed")
	}
	if _, err := tx.Exec(c.Context(),
		`INSERT INTO forum_posts (thread_id, author_id, body) VALUES ($1,$2,$3)`,
		threadID, callerID(c), req.Body); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "post failed")
	}
	if err := tx.Commit(c.Context()); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "save failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"thread_id": threadID})
}

// DeleteForumThread removes a thread (and its posts, via FK cascade). Only the
// thread's author may delete it; course/platform staff may also moderate.
func (h *Handlers) DeleteForumThread(c *fiber.Ctx) error {
	threadID := c.Params("id")
	var authorID string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT author_id FROM forum_threads WHERE id=$1`, threadID).Scan(&authorID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "thread not found")
	}
	role := callerRole(c)
	staffMod := role == "instructor" || role == "manager" || role == "superadmin"
	if authorID != callerID(c) && !staffMod {
		return fiber.NewError(fiber.StatusForbidden, "you can only delete your own discussions")
	}
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM forum_threads WHERE id=$1`, threadID); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// DeleteForumPost removes a single reply. Only the post's author may delete it
// (staff may moderate). The opening post can't be deleted on its own — that is
// done by deleting the whole discussion.
func (h *Handlers) DeleteForumPost(c *fiber.Ctx) error {
	postID := c.Params("postId")
	var authorID, threadID string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT author_id, thread_id FROM forum_posts WHERE id=$1`, postID).Scan(&authorID, &threadID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "reply not found")
	}
	role := callerRole(c)
	staffMod := role == "instructor" || role == "manager" || role == "superadmin"
	if authorID != callerID(c) && !staffMod {
		return fiber.NewError(fiber.StatusForbidden, "you can only delete your own replies")
	}
	// Guard the opening post.
	var openingID string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT id FROM forum_posts WHERE thread_id=$1 ORDER BY created_at LIMIT 1`, threadID).Scan(&openingID); err == nil {
		if openingID == postID {
			return fiber.NewError(fiber.StatusBadRequest, "this is the original message — delete the whole discussion instead")
		}
	}
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM forum_posts WHERE id=$1`, postID); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
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
