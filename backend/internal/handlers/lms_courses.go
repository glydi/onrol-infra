package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
)

// ---- Categories ------------------------------------------------------------

func (h *Handlers) CreateCategory(c *fiber.Ctx) error {
	var req struct {
		Name     string `json:"name"`
		ParentID string `json:"parent_id"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	var parent any
	if req.ParentID != "" {
		parent = req.ParentID
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO course_categories (name, parent_id) VALUES ($1,$2) RETURNING id`,
		req.Name, parent).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "name": req.Name})
}

func (h *Handlers) ListCategories(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, name, COALESCE(parent_id::text,'') FROM course_categories ORDER BY name`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name, parent string
		if err := rows.Scan(&id, &name, &parent); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "name": name, "parent_id": parent})
	}
	return c.JSON(fiber.Map{"categories": out})
}

// ---- Courses ---------------------------------------------------------------

func (h *Handlers) CreateCourse(c *fiber.Ctx) error {
	var req struct {
		Title        string `json:"title"`
		Label        string `json:"label"`        // unique Course ID (course-string)
		Description  string `json:"description"`
		CategoryID   string `json:"category_id"`
		GroupID      string `json:"group_id"`
		EnrollType   string `json:"enroll_type"`
		ImageURL     string `json:"image_url"` // cover image (data URI or URL)
		InstructorID string `json:"instructor_id"` // admin assigns the teaching instructor
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Title) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title required")
	}
	if req.EnrollType == "" {
		req.EnrollType = "manual"
	}
	if req.GroupID != "" && callerRole(c) != "superadmin" && callerRole(c) != "manager" {
		if err := h.requireGroupScope(c, req.GroupID); err != nil {
			return err
		}
	}

	// The course owner = its teaching instructor. An admin/manager picks one from
	// the dropdown; otherwise the creator owns it.
	owner := callerID(c)
	if req.InstructorID != "" && (callerRole(c) == "manager" || callerRole(c) == "superadmin") {
		var ok bool
		_ = h.Pool.QueryRow(c.Context(),
			`SELECT EXISTS(SELECT 1 FROM users WHERE id=$1 AND role='instructor' AND is_active)`,
			req.InstructorID).Scan(&ok)
		if !ok {
			return fiber.NewError(fiber.StatusBadRequest, "instructor_id is not a valid instructor")
		}
		owner = req.InstructorID
	}

	var cat, grp any
	if req.CategoryID != "" {
		cat = req.CategoryID
	}
	if req.GroupID != "" {
		grp = req.GroupID
	}
	var img any
	if strings.TrimSpace(req.ImageURL) != "" {
		img = req.ImageURL
	}
	// Course ID (label): the unique course-string. Defaults to a slug of the title
	// when blank. Two courses can never share a Course ID.
	label := slugify(req.Label)
	if label == "" {
		label = slugify(req.Title)
	}
	if label == "" {
		return fiber.NewError(fiber.StatusBadRequest, "course id is required")
	}
	var id string
	err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO courses (title, label, description, category_id, group_id, owner_id, enroll_type, image_url)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id`,
		req.Title, label, req.Description, cat, grp, owner, req.EnrollType, img,
	).Scan(&id)
	if err != nil {
		if strings.Contains(err.Error(), "idx_courses_label") {
			return fiber.NewError(fiber.StatusConflict, "a course with this Course ID already exists")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "title": req.Title, "label": label, "status": "draft"})
}

// slugify turns a free-form string into a lowercase, dash-separated course-id
// (a-z, 0-9, '-'), trimming repeated/edge dashes. Empty in -> empty out.
func slugify(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	var b strings.Builder
	lastDash := false
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			lastDash = false
		} else if !lastDash {
			b.WriteByte('-')
			lastDash = true
		}
	}
	return strings.Trim(b.String(), "-")
}

// UpdateCourse edits title/description/category/status (publish/archive).
func (h *Handlers) UpdateCourse(c *fiber.Ctx) error {
	id := c.Params("id")
	if err := h.canManageCourse(c, id); err != nil {
		return err
	}
	var req struct {
		Title       *string `json:"title"`
		Label       *string `json:"label"`       // unique Course ID
		Description *string `json:"description"`
		Status      *string `json:"status"`
		EnrollType  *string `json:"enroll_type"` // admin controls admission mode
		ImageURL    *string `json:"image_url"`   // cover image (data URI or URL)
		BatchSize   *int    `json:"batch_size"`  // default students per batch
		BatchAuto   *bool   `json:"batch_auto"`  // auto allocation is the default mode
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	var label *string
	if req.Label != nil {
		s := slugify(*req.Label)
		if s == "" {
			return fiber.NewError(fiber.StatusBadRequest, "course id cannot be empty")
		}
		label = &s
	}
	if req.Status != nil {
		switch *req.Status {
		case "draft", "published", "archived":
		default:
			return fiber.NewError(fiber.StatusBadRequest, "invalid status")
		}
	}
	if req.EnrollType != nil {
		switch *req.EnrollType {
		case "self", "manual", "closed":
		default:
			return fiber.NewError(fiber.StatusBadRequest, "invalid enroll_type")
		}
	}
	if req.BatchSize != nil && *req.BatchSize < 0 {
		return fiber.NewError(fiber.StatusBadRequest, "batch_size must be >= 0")
	}
	_, err := h.Pool.Exec(c.Context(), `
		UPDATE courses SET
			title=COALESCE($2,title),
			description=COALESCE($3,description),
			status=COALESCE($4,status),
			enroll_type=COALESCE($5,enroll_type),
			image_url=COALESCE($6,image_url),
			batch_size=COALESCE($7,batch_size),
			batch_auto=COALESCE($8,batch_auto),
			label=COALESCE($9,label)
		WHERE id=$1`, id, req.Title, req.Description, req.Status, req.EnrollType, req.ImageURL,
		req.BatchSize, req.BatchAuto, label)
	if err != nil {
		if strings.Contains(err.Error(), "idx_courses_label") {
			return fiber.NewError(fiber.StatusConflict, "a course with this Course ID already exists")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	return c.JSON(fiber.Map{"id": id, "updated": true})
}

func (h *Handlers) ListCourses(c *fiber.Ctx) error {
	// Admin/manager + superadmin see ALL courses; an instructor sees only theirs.
	q := `SELECT id, title, status, enroll_type, COALESCE(group_id::text,''), COALESCE(image_url,''), COALESCE(label,''), created_at FROM courses`
	args := []any{}
	if callerRole(c) == "instructor" {
		q += ` WHERE owner_id=$1`
		args = append(args, callerID(c))
	}
	q += ` ORDER BY created_at DESC LIMIT 500`
	r, err := h.Pool.Query(c.Context(), q, args...)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer r.Close()
	out := []fiber.Map{}
	for r.Next() {
		var id, title, status, et, grp, img, label string
		var created any
		if err := r.Scan(&id, &title, &status, &et, &grp, &img, &label, &created); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "title": title, "status": status,
			"enroll_type": et, "group_id": grp, "image_url": img, "label": label, "created_at": created})
	}
	return c.JSON(fiber.Map{"courses": out})
}

// ---- Modules & lessons -----------------------------------------------------

func (h *Handlers) AddModule(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Title    string `json:"title"`
		Position int    `json:"position"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Title) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title required")
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO modules (course_id, title, position) VALUES ($1,$2,$3) RETURNING id`,
		courseID, req.Title, req.Position).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "title": req.Title})
}

func (h *Handlers) AddLesson(c *fiber.Ctx) error {
	moduleID := c.Params("id")
	// Resolve the course for scope check.
	var courseID string
	if err := h.Pool.QueryRow(c.Context(), `SELECT course_id FROM modules WHERE id=$1`, moduleID).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "module not found")
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Title        string `json:"title"`
		Type         string `json:"type"`
		VideoID      string `json:"video_id"`
		Body         string `json:"body"`
		Position     int    `json:"position"`
		DayNumber    *int   `json:"day_number"` // which day in the module (NULL = unscheduled)
		Downloadable *bool  `json:"downloadable"` // file lessons: may learners download it?
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Title) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title required")
	}
	if req.Type == "" {
		req.Type = "text"
	}
	var vid any
	if req.VideoID != "" {
		vid = req.VideoID
	}
	downloadable := true
	if req.Downloadable != nil {
		downloadable = *req.Downloadable
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO lessons (module_id, title, type, video_id, body, position, downloadable, day_number)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id`,
		moduleID, req.Title, req.Type, vid, req.Body, req.Position, downloadable, req.DayNumber).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "title": req.Title, "type": req.Type})
}

func (h *Handlers) AddPrerequisite(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		PrereqCourseID string `json:"prereq_course_id"`
	}
	if err := c.BodyParser(&req); err != nil || req.PrereqCourseID == "" {
		return fiber.NewError(fiber.StatusBadRequest, "prereq_course_id required")
	}
	if req.PrereqCourseID == courseID {
		return fiber.NewError(fiber.StatusBadRequest, "a course cannot require itself")
	}
	_, err := h.Pool.Exec(c.Context(),
		`INSERT INTO course_prerequisites (course_id, prereq_course_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`,
		courseID, req.PrereqCourseID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "add failed")
	}
	return c.JSON(fiber.Map{"course_id": courseID, "prereq_course_id": req.PrereqCourseID})
}

// ManualEnroll enrolls one user (by id or email) into a course.
func (h *Handlers) ManualEnroll(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		UserID string `json:"user_id"`
		Email  string `json:"email"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if req.UserID == "" && req.Email != "" {
		if err := h.Pool.QueryRow(c.Context(),
			`SELECT id FROM users WHERE email=$1`, strings.ToLower(strings.TrimSpace(req.Email)),
		).Scan(&req.UserID); err != nil {
			return fiber.NewError(fiber.StatusNotFound, "no user with that email")
		}
	}
	if req.UserID == "" {
		return fiber.NewError(fiber.StatusBadRequest, "user_id or email required")
	}
	if err := h.enrollUserInCourse(c, courseID, req.UserID, callerID(c)); err != nil {
		return err
	}
	// Notify the student that a course was added for them.
	var courseTitle string
	_ = h.Pool.QueryRow(c.Context(), `SELECT title FROM courses WHERE id=$1`, courseID).Scan(&courseTitle)
	if courseTitle == "" {
		courseTitle = "a course"
	}
	h.notify(c, req.UserID, "New course added", "You've been enrolled in "+courseTitle+".", "enrollment")
	return c.JSON(fiber.Map{"course_id": courseID, "user_id": req.UserID, "enrolled": true})
}

// ListCourseStudents returns the students enrolled in a course (instructor view).
func (h *Handlers) ListCourseStudents(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	rows, err := h.Pool.Query(c.Context(), `
		SELECT u.id, u.full_name, u.email, ce.status, u.batch,
		       (SELECT count(*) FROM lesson_progress lp JOIN lessons l ON l.id=lp.lesson_id
		          JOIN modules m ON m.id=l.module_id WHERE m.course_id=$1 AND lp.user_id=u.id) AS done,
		       (SELECT count(*) FROM lessons l JOIN modules m ON m.id=l.module_id WHERE m.course_id=$1) AS total
		FROM course_enrollments ce JOIN users u ON u.id=ce.user_id
		WHERE ce.course_id=$1 ORDER BY u.full_name`, courseID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name, email, status string
		var batch *int
		var done, total int
		if err := rows.Scan(&id, &name, &email, &status, &batch, &done, &total); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		pct := 0
		if total > 0 {
			pct = done * 100 / total
		}
		out = append(out, fiber.Map{"id": id, "name": name, "email": email, "status": status, "percent": pct, "batch": batch})
	}
	return c.JSON(fiber.Map{"students": out})
}

// CourseBatches returns the students of a course grouped by batch. A course is
// linked to its students by its label (the course-label queue): every student
// whose course_label matches is bucketed by batch number, with the unassigned
// queue returned as batch=null first. This is the per-course batch portal.
func (h *Handlers) CourseBatches(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var label *string
	var batchSize *int
	var batchAuto bool
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT label, batch_size, batch_auto FROM courses WHERE id=$1`, courseID,
	).Scan(&label, &batchSize, &batchAuto); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "course not found")
	}
	settings := fiber.Map{"batch_size": batchSize, "batch_auto": batchAuto}
	if label == nil || strings.TrimSpace(*label) == "" {
		return c.JSON(fiber.Map{"label": "", "batches": []fiber.Map{}, "settings": settings})
	}
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, full_name, email, batch FROM users
		  WHERE role='student' AND lower(course_label)=lower($1)
		  ORDER BY batch NULLS FIRST, full_name`, *label)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	// Bucket students by batch, preserving first-seen order (queue first).
	order := []int{}            // -1 sentinel = unassigned/queue
	buckets := map[int][]fiber.Map{}
	for rows.Next() {
		var id, name, email string
		var batch *int
		if err := rows.Scan(&id, &name, &email, &batch); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		key := -1
		if batch != nil {
			key = *batch
		}
		if _, seen := buckets[key]; !seen {
			order = append(order, key)
		}
		buckets[key] = append(buckets[key], fiber.Map{"id": id, "name": name, "email": email})
	}
	out := []fiber.Map{}
	for _, key := range order {
		var b any
		if key >= 0 {
			b = key
		}
		out = append(out, fiber.Map{"batch": b, "count": len(buckets[key]), "students": buckets[key]})
	}
	return c.JSON(fiber.Map{"label": *label, "batches": out, "settings": settings})
}

// ListEnrollmentRequests returns pending self-enroll requests for courses the
// caller manages (admin sees all; instructor sees their courses').
func (h *Handlers) ListEnrollmentRequests(c *fiber.Ctx) error {
	q := `SELECT er.id, u.full_name, u.email, c.id, c.title, er.created_at
	      FROM enrollment_requests er
	      JOIN users u ON u.id = er.user_id
	      JOIN courses c ON c.id = er.course_id
	      WHERE er.status = 'pending'`
	args := []any{}
	if !(callerRole(c) == "manager" || callerRole(c) == "superadmin") {
		q += ` AND c.owner_id = $1`
		args = append(args, callerID(c))
	}
	q += ` ORDER BY er.created_at`
	rows, err := h.Pool.Query(c.Context(), q, args...)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name, email, courseID, course string
		var createdAt any
		if err := rows.Scan(&id, &name, &email, &courseID, &course, &createdAt); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "student": name, "email": email,
			"course_id": courseID, "course": course, "created_at": createdAt})
	}
	return c.JSON(fiber.Map{"requests": out})
}

// DecideEnrollmentRequest approves (enrolls the student) or rejects a request.
func (h *Handlers) DecideEnrollmentRequest(c *fiber.Ctx) error {
	reqID := c.Params("id")
	approve := c.Params("action") == "approve"
	var courseID, userID string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT course_id, user_id FROM enrollment_requests WHERE id=$1 AND status='pending'`,
		reqID).Scan(&courseID, &userID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "pending request not found")
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	if approve {
		if err := h.enrollUserInCourse(c, courseID, userID, callerID(c)); err != nil {
			return err
		}
	}
	status := "rejected"
	if approve {
		status = "approved"
	}
	_, _ = h.Pool.Exec(c.Context(),
		`UPDATE enrollment_requests SET status=$2, decided_by=$3, decided_at=now() WHERE id=$1`,
		reqID, status, callerID(c))
	return c.JSON(fiber.Map{"id": reqID, "status": status})
}

// DeleteModule removes a module (and its lessons) from a course the caller manages.
func (h *Handlers) DeleteModule(c *fiber.Ctx) error {
	id := c.Params("id")
	var courseID string
	if err := h.Pool.QueryRow(c.Context(), `SELECT course_id FROM modules WHERE id=$1`, id).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "module not found")
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM modules WHERE id=$1`, id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": id})
}

// DeleteLesson removes a single lesson.
func (h *Handlers) DeleteLesson(c *fiber.Ctx) error {
	id := c.Params("id")
	var courseID string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT m.course_id FROM lessons l JOIN modules m ON m.id=l.module_id WHERE l.id=$1`, id).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "lesson not found")
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM lessons WHERE id=$1`, id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": id})
}

// DeleteCourse permanently deletes a course the caller can manage (cascades to
// modules, lessons, enrollments, assessments, sessions, etc. via FKs).
func (h *Handlers) DeleteCourse(c *fiber.Ctx) error {
	id := c.Params("id")
	if err := h.canManageCourse(c, id); err != nil {
		return err
	}
	tag, err := h.Pool.Exec(c.Context(), `DELETE FROM courses WHERE id=$1`, id)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	if tag.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "course not found")
	}
	return c.JSON(fiber.Map{"deleted": id})
}

// GetManagedCourse returns a course's full structure (modules + lessons) for
// staff who can manage it — used by the console's course editor.
func (h *Handlers) GetManagedCourse(c *fiber.Ctx) error {
	id := c.Params("id")
	if err := h.canManageCourse(c, id); err != nil {
		return err
	}
	var title, status, enrollType, desc string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT title, status, enroll_type, description FROM courses WHERE id=$1`, id,
	).Scan(&title, &status, &enrollType, &desc); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "course not found")
	}
	rows, err := h.Pool.Query(c.Context(), `
		SELECT m.id, m.title, l.id, l.title, l.type, l.day_number
		FROM modules m LEFT JOIN lessons l ON l.module_id=m.id
		WHERE m.course_id=$1 ORDER BY m.position, l.day_number NULLS LAST, l.position`, id)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "load failed")
	}
	defer rows.Close()
	mods := map[string]fiber.Map{}
	order := []string{}
	for rows.Next() {
		var mid, mtitle string
		var lid, ltitle, ltype *string
		var day *int
		if err := rows.Scan(&mid, &mtitle, &lid, &ltitle, &ltype, &day); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		if _, ok := mods[mid]; !ok {
			mods[mid] = fiber.Map{"id": mid, "title": mtitle, "lessons": []fiber.Map{}}
			order = append(order, mid)
		}
		if lid != nil {
			m := mods[mid]
			m["lessons"] = append(m["lessons"].([]fiber.Map), fiber.Map{"id": *lid, "title": *ltitle, "type": *ltype, "day_number": day})
		}
	}
	ordered := make([]fiber.Map, 0, len(order))
	for _, k := range order {
		ordered = append(ordered, mods[k])
	}
	return c.JSON(fiber.Map{"id": id, "title": title, "status": status,
		"enroll_type": enrollType, "description": desc, "modules": ordered})
}

// enrollUserInCourse upserts a course enrollment and grants entitlements to the
// course's video lessons (so HLS key delivery works for enrolled students).
func (h *Handlers) enrollUserInCourse(c *fiber.Ctx, courseID, userID, byID string) error {
	_, err := h.Pool.Exec(c.Context(),
		`INSERT INTO course_enrollments (course_id, user_id, enrolled_by)
		 VALUES ($1,$2,$3) ON CONFLICT (course_id, user_id) DO NOTHING`,
		courseID, userID, byID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "enroll failed")
	}
	_, _ = h.Pool.Exec(c.Context(), `
		INSERT INTO enrollments (user_id, video_id)
		SELECT $2, l.video_id FROM modules m JOIN lessons l ON l.module_id=m.id
		WHERE m.course_id=$1 AND l.video_id IS NOT NULL
		ON CONFLICT DO NOTHING`, courseID, userID)
	return nil
}
