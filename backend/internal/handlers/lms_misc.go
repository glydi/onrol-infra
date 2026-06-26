package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
)

// ---- Reporting -------------------------------------------------------------

// CompletionReport: per-enrolled-student lesson completion ratio for a course.
func (h *Handlers) CompletionReport(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	rows, err := h.Pool.Query(c.Context(), `
		WITH lc AS (SELECT count(*) n FROM lessons l JOIN modules m ON m.id=l.module_id WHERE m.course_id=$1)
		SELECT u.id, u.full_name, ce.status,
		       (SELECT count(*) FROM lesson_progress lp
		          JOIN lessons l ON l.id=lp.lesson_id JOIN modules m ON m.id=l.module_id
		         WHERE m.course_id=$1 AND lp.user_id=u.id) AS done,
		       (SELECT n FROM lc) AS total
		FROM course_enrollments ce JOIN users u ON u.id=ce.user_id
		WHERE ce.course_id=$1 ORDER BY u.full_name`, courseID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "report failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var uid, name, status string
		var done, total int
		if err := rows.Scan(&uid, &name, &status, &done, &total); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		pct := 0
		if total > 0 {
			pct = done * 100 / total
		}
		out = append(out, fiber.Map{"user_id": uid, "student": name, "status": status,
			"lessons_done": done, "lessons_total": total, "percent": pct})
	}
	return c.JSON(fiber.Map{"course_id": courseID, "completion": out})
}

// GradesReport: per-assessment average/min/max and submission counts.
func (h *Handlers) GradesReport(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	rows, err := h.Pool.Query(c.Context(), `
		SELECT a.id, a.title, count(s.id) FILTER (WHERE s.status='graded') AS graded,
		       count(s.id) AS submissions,
		       round(avg(s.score) FILTER (WHERE s.status='graded'),2) AS avg_score,
		       min(s.score) FILTER (WHERE s.status='graded') AS min_score,
		       max(s.score) FILTER (WHERE s.status='graded') AS max_score
		FROM assessments a LEFT JOIN submissions s ON s.assessment_id=a.id
		WHERE a.course_id=$1 GROUP BY a.id, a.title ORDER BY a.created_at`, courseID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "report failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title string
		var graded, subs int
		var avg, mn, mx *float64
		if err := rows.Scan(&id, &title, &graded, &subs, &avg, &mn, &mx); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"assessment_id": id, "title": title, "graded": graded,
			"submissions": subs, "avg": avg, "min": mn, "max": mx})
	}
	return c.JSON(fiber.Map{"course_id": courseID, "grades": out})
}

// AttendanceReport: per-session present/absent/excused counts.
func (h *Handlers) AttendanceReport(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	rows, err := h.Pool.Query(c.Context(), `
		SELECT cs.id, cs.title, cs.starts_at,
		       count(*) FILTER (WHERE sa.status='present') AS present,
		       count(*) FILTER (WHERE sa.status='absent')  AS absent,
		       count(*) FILTER (WHERE sa.status='excused') AS excused
		FROM class_sessions cs LEFT JOIN session_attendance sa ON sa.session_id=cs.id
		WHERE cs.course_id=$1 GROUP BY cs.id, cs.title, cs.starts_at ORDER BY cs.starts_at`, courseID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "report failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title string
		var starts any
		var present, absent, excused int
		if err := rows.Scan(&id, &title, &starts, &present, &absent, &excused); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"session_id": id, "title": title, "starts_at": starts,
			"present": present, "absent": absent, "excused": excused})
	}
	return c.JSON(fiber.Map{"course_id": courseID, "attendance": out})
}

// ---- Communication ---------------------------------------------------------

func (h *Handlers) CreateAnnouncement(c *fiber.Ctx) error {
	var req struct {
		CourseID    string `json:"course_id"`
		Title       string `json:"title"`
		Body        string `json:"body"`
		Audience    string `json:"audience"`     // all | batch | role (used when no course_id)
		BatchNumber *int   `json:"batch_number"` // for audience=batch
		Role        string `json:"role"`         // for audience=role
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Title) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title required")
	}
	// Course-scoped announcement: gated to that course's staff.
	if req.CourseID != "" {
		if err := h.canManageCourse(c, req.CourseID); err != nil {
			return err
		}
		var id string
		if err := h.Pool.QueryRow(c.Context(),
			`INSERT INTO announcements (course_id, author_id, title, body, audience) VALUES ($1,$2,$3,$4,'all') RETURNING id`,
			req.CourseID, callerID(c), req.Title, req.Body).Scan(&id); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "create failed")
		}
		go h.pushAnnouncement(req.CourseID, "all", req.Title, req.Body, nil, "")
		return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "title": req.Title})
	}
	// Targeted broadcast (all / batch / role).
	switch req.Audience {
	case "", "all":
		req.Audience = "all"
		req.BatchNumber = nil
		req.Role = ""
	case "batch":
		if req.BatchNumber == nil {
			return fiber.NewError(fiber.StatusBadRequest, "batch_number required for batch audience")
		}
		req.Role = ""
	case "role":
		if req.Role == "" {
			return fiber.NewError(fiber.StatusBadRequest, "role required for role audience")
		}
		req.BatchNumber = nil
	default:
		return fiber.NewError(fiber.StatusBadRequest, "audience must be all, batch, or role")
	}
	var roleVal any
	if req.Role != "" {
		roleVal = req.Role
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO announcements (author_id, title, body, audience, batch_number, role)
		 VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
		callerID(c), req.Title, req.Body, req.Audience, req.BatchNumber, roleVal).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	go h.pushAnnouncement("", req.Audience, req.Title, req.Body, req.BatchNumber, req.Role)
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "title": req.Title})
}

// ---- Scheduling ------------------------------------------------------------

func (h *Handlers) CreateSession(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Title     string `json:"title"`
		StartsAt  string `json:"starts_at"`
		EndsAt    string `json:"ends_at"`
		Location  string `json:"location"`
		Capacity  int    `json:"capacity"`
		WebinarID string `json:"webinar_id"`
		JoinURL   string `json:"join_url"` // direct live link (Zoho/Meet/etc.) students join
		HostURL   string `json:"host_url"` // host/start link instructors use to run + record
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Title) == "" || req.StartsAt == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title and starts_at required")
	}
	var ends, webinar any
	if req.EndsAt != "" {
		ends = req.EndsAt
	}
	if req.WebinarID != "" {
		webinar = req.WebinarID
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO class_sessions (course_id, title, starts_at, ends_at, location, instructor_id, capacity, webinar_id, join_url, host_url)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING id`,
		courseID, req.Title, req.StartsAt, ends, req.Location, callerID(c), req.Capacity, webinar, req.JoinURL, req.HostURL).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "title": req.Title})
}

// UpdateSession edits a live session — primarily to update/replace the live
// video (join) link, but title and start time can be changed too.
func (h *Handlers) UpdateSession(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	var courseID string
	if err := h.Pool.QueryRow(c.Context(), `SELECT course_id FROM class_sessions WHERE id=$1`, sessionID).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "session not found")
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Title    *string `json:"title"`
		JoinURL  *string `json:"join_url"`
		HostURL  *string `json:"host_url"`
		StartsAt *string `json:"starts_at"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	// COALESCE keeps existing values for any field omitted from the request.
	var starts any
	if req.StartsAt != nil && *req.StartsAt != "" {
		starts = *req.StartsAt
	}
	if _, err := h.Pool.Exec(c.Context(), `
		UPDATE class_sessions
		SET title    = COALESCE($2, title),
		    join_url = COALESCE($3, join_url),
		    host_url = COALESCE($4, host_url),
		    starts_at = COALESCE($5, starts_at)
		WHERE id=$1`, sessionID, req.Title, req.JoinURL, req.HostURL, starts); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	return c.JSON(fiber.Map{"id": sessionID, "updated": true})
}

// ListCourseSessions returns a course's live sessions for staff (console).
func (h *Handlers) ListCourseSessions(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, title, starts_at, COALESCE(join_url,''), COALESCE(host_url,''), COALESCE(location,'')
		 FROM class_sessions WHERE course_id=$1 ORDER BY starts_at`, courseID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, joinURL, hostURL, loc string
		var startsAt any
		if err := rows.Scan(&id, &title, &startsAt, &joinURL, &hostURL, &loc); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "title": title, "starts_at": startsAt, "join_url": joinURL, "host_url": hostURL, "location": loc})
	}
	return c.JSON(fiber.Map{"sessions": out})
}

// MyLive returns upcoming/ongoing live sessions for the student's enrolled
// courses, with the join link. Only enrolled students see them.
func (h *Handlers) MyLive(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT cs.id, cs.title, cs.starts_at, cs.ends_at, COALESCE(cs.join_url,''), COALESCE(cs.location,''), c.title
		FROM class_sessions cs
		JOIN courses c ON c.id = cs.course_id
		JOIN course_enrollments ce ON ce.course_id = c.id AND ce.user_id = $1
		WHERE cs.starts_at >= now() - interval '3 hours'
		ORDER BY cs.starts_at`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "live load failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, joinURL, location, course string
		var startsAt, endsAt any
		if err := rows.Scan(&id, &title, &startsAt, &endsAt, &joinURL, &location, &course); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		// Fall back to a join link stored in `location` if join_url is unset.
		if joinURL == "" && (strings.HasPrefix(location, "http://") || strings.HasPrefix(location, "https://")) {
			joinURL = location
		}
		out = append(out, fiber.Map{"id": id, "title": title, "starts_at": startsAt, "ends_at": endsAt, "join_url": joinURL, "course": course})
	}
	return c.JSON(fiber.Map{"live": out})
}

func (h *Handlers) MarkAttendance(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	var courseID string
	if err := h.Pool.QueryRow(c.Context(), `SELECT course_id FROM class_sessions WHERE id=$1`, sessionID).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "session not found")
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		UserID string `json:"user_id"`
		Status string `json:"status"`
	}
	if err := c.BodyParser(&req); err != nil || req.UserID == "" {
		return fiber.NewError(fiber.StatusBadRequest, "user_id required")
	}
	switch req.Status {
	case "present", "absent", "excused":
	default:
		req.Status = "present"
	}
	_, err := h.Pool.Exec(c.Context(),
		`INSERT INTO session_attendance (session_id, user_id, status, marked_by) VALUES ($1,$2,$3,$4)
		 ON CONFLICT (session_id, user_id) DO UPDATE SET status=EXCLUDED.status, marked_by=EXCLUDED.marked_by, marked_at=now()`,
		sessionID, req.UserID, req.Status, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "mark failed")
	}
	return c.JSON(fiber.Map{"session_id": sessionID, "user_id": req.UserID, "status": req.Status})
}
