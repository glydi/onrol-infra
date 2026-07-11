package handlers

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"math"
	"strconv"
	"strings"

	"github.com/gofiber/fiber/v2"
	"github.com/jackc/pgx/v5"
)

// playURLExpr resolves a lesson's stored video URL (lessons alias `l`) to the
// CURRENT playable URL. Lessons freeze a static URL at pick time, so a video
// "Used" before transcode finished would forever play the raw source mp4 (which
// won't stream for large files). For a video lesson whose stored URL matches a
// media_assets row that's finished transcoding, this returns the HLS m3u8
// (segmented — streams at any size, incl. multi-GB); otherwise the stored body.
const playURLExpr = `COALESCE(
	CASE WHEN l.type='video' THEN
		(SELECT CASE WHEN ma.status='ready' AND ma.hls_url <> '' THEN ma.hls_url ELSE l.body END
		   FROM media_assets ma WHERE ma.url = l.body OR ma.hls_url = l.body LIMIT 1)
	END,
	l.body, '')`

// ---- Profile & preferences -------------------------------------------------

func (h *Handlers) GetMyProfile(c *fiber.Ctx) error {
	var email, name, phone, role, avatar, username, occupation, location, linkedin, github, courseLabel, courseName, loginID string
	var batch *string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT COALESCE(u.email,''), u.full_name, COALESCE(u.phone,''), u.role, COALESCE(u.avatar,''),
		        COALESCE(u.username,''), COALESCE(u.occupation,''), COALESCE(u.location,''),
		        COALESCE(u.linkedin,''), COALESCE(u.github,''),
		        u.batch, COALESCE(u.course_label,''), COALESCE(c.title,''), COALESCE(u.login_id,'')
		   FROM users u
		   LEFT JOIN courses c ON lower(c.label)=lower(u.course_label)
		  WHERE u.id=$1`, callerID(c),
	).Scan(&email, &name, &phone, &role, &avatar, &username, &occupation, &location, &linkedin, &github,
		&batch, &courseLabel, &courseName, &loginID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "user not found")
	}
	return c.JSON(fiber.Map{
		"id": callerID(c), "email": email, "full_name": name, "phone": phone, "role": role, "avatar": avatar,
		"username": username, "occupation": occupation, "location": location, "linkedin": linkedin, "github": github,
		"batch": batch, "course_label": courseLabel, "course": courseName, "login_id": loginID,
	})
}

// Max inline avatar payload (~1 MB of base64) — keeps the users row small.
const maxAvatarLen = 1_400_000

func (h *Handlers) UpdateMyProfile(c *fiber.Ctx) error {
	var req struct {
		FullName   *string `json:"full_name"`
		Phone      *string `json:"phone"`
		Avatar     *string `json:"avatar"`
		Username   *string `json:"username"`
		Occupation *string `json:"occupation"`
		Location   *string `json:"location"`
		Linkedin   *string `json:"linkedin"`
		Github     *string `json:"github"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if req.Avatar != nil && len(*req.Avatar) > maxAvatarLen {
		return fiber.NewError(fiber.StatusRequestEntityTooLarge, "image too large")
	}
	_, err := h.Pool.Exec(c.Context(),
		`UPDATE users SET
		   full_name=COALESCE($2,full_name), phone=COALESCE($3,phone), avatar=COALESCE($4,avatar),
		   username=COALESCE($5,username), occupation=COALESCE($6,occupation), location=COALESCE($7,location),
		   linkedin=COALESCE($8,linkedin), github=COALESCE($9,github), updated_at=now()
		 WHERE id=$1`,
		callerID(c), req.FullName, req.Phone, req.Avatar, req.Username, req.Occupation, req.Location, req.Linkedin, req.Github)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	return c.JSON(fiber.Map{"updated": true})
}

func (h *Handlers) GetPreferences(c *fiber.Ctx) error {
	var lang, tz string
	var email, push bool
	err := h.Pool.QueryRow(c.Context(),
		`SELECT language, timezone, email_notifications, push_notifications FROM user_preferences WHERE user_id=$1`,
		callerID(c)).Scan(&lang, &tz, &email, &push)
	if err != nil {
		// Defaults if not set yet.
		return c.JSON(fiber.Map{"language": "en", "timezone": "Asia/Kolkata", "email_notifications": true, "push_notifications": true})
	}
	return c.JSON(fiber.Map{"language": lang, "timezone": tz, "email_notifications": email, "push_notifications": push})
}

func (h *Handlers) UpdatePreferences(c *fiber.Ctx) error {
	var req struct {
		Language           string `json:"language"`
		Timezone           string `json:"timezone"`
		EmailNotifications *bool  `json:"email_notifications"`
		PushNotifications  *bool  `json:"push_notifications"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if req.Language == "" {
		req.Language = "en"
	}
	if req.Timezone == "" {
		req.Timezone = "Asia/Kolkata"
	}
	email := req.EmailNotifications == nil || *req.EmailNotifications
	push := req.PushNotifications == nil || *req.PushNotifications
	_, err := h.Pool.Exec(c.Context(), `
		INSERT INTO user_preferences (user_id, language, timezone, email_notifications, push_notifications)
		VALUES ($1,$2,$3,$4,$5)
		ON CONFLICT (user_id) DO UPDATE SET language=EXCLUDED.language, timezone=EXCLUDED.timezone,
			email_notifications=EXCLUDED.email_notifications, push_notifications=EXCLUDED.push_notifications, updated_at=now()`,
		callerID(c), req.Language, req.Timezone, email, push)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	return c.JSON(fiber.Map{"updated": true})
}

// ---- Catalog & enrollment --------------------------------------------------

// Catalog lists published courses (browse before enrolling).
func (h *Handlers) Catalog(c *fiber.Ctx) error {
	// Only courses the student is NOT already enrolled in (and hasn't a pending
	// request for) — so the catalog only offers courses they can newly join.
	rows, err := h.Pool.Query(c.Context(), `
		SELECT c.id, c.title, c.description, c.enroll_type, COALESCE(cc.name,''), COALESCE(c.image_url,''), COALESCE(c.explore_link,'')
		FROM courses c LEFT JOIN course_categories cc ON cc.id=c.category_id
		WHERE (c.status='published' OR c.in_explore) AND c.status<>'archived'
		  AND NOT EXISTS (SELECT 1 FROM course_enrollments ce WHERE ce.course_id=c.id AND ce.user_id=$1)
		  AND NOT EXISTS (SELECT 1 FROM enrollment_requests er WHERE er.course_id=c.id AND er.user_id=$1 AND er.status='pending')
		ORDER BY c.created_at DESC LIMIT 500`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "catalog failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, desc, et, cat, img, link string
		if err := rows.Scan(&id, &title, &desc, &et, &cat, &img, &link); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "title": title, "description": desc, "enroll_type": et, "category": cat, "image_url": img, "explore_link": link})
	}
	return c.JSON(fiber.Map{"catalog": out})
}

// SelfEnroll: for enroll_type='self' the student is enrolled immediately;
// otherwise an enrollment request is created for manager approval.
func (h *Handlers) SelfEnroll(c *fiber.Ctx) error {
	courseID := c.Params("id")
	var status, enrollType string
	var inExplore bool
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT status, enroll_type, in_explore FROM courses WHERE id=$1`, courseID).Scan(&status, &enrollType, &inExplore); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "course not found")
	}
	// A course is joinable if it's published OR explicitly listed in Explore.
	if status != "published" && !inExplore {
		return fiber.NewError(fiber.StatusForbidden, "course not open")
	}
	// Enforce prerequisites (must be completed).
	var missing int
	_ = h.Pool.QueryRow(c.Context(), `
		SELECT count(*) FROM course_prerequisites p
		WHERE p.course_id=$1 AND NOT EXISTS (
			SELECT 1 FROM course_enrollments ce
			WHERE ce.user_id=$2 AND ce.course_id=p.prereq_course_id AND ce.status='completed')`,
		courseID, callerID(c)).Scan(&missing)
	if missing > 0 {
		return fiber.NewError(fiber.StatusForbidden, "unmet prerequisites")
	}

	if enrollType == "closed" {
		return fiber.NewError(fiber.StatusForbidden, "enrollment is closed — the admin enrolls students for this course")
	}
	if enrollType == "self" {
		if err := h.enrollUserInCourse(c, courseID, callerID(c), callerID(c)); err != nil {
			return err
		}
		return c.JSON(fiber.Map{"course_id": courseID, "enrolled": true})
	}
	// Request approval (manual / cohort).
	_, err := h.Pool.Exec(c.Context(),
		`INSERT INTO enrollment_requests (course_id, user_id) VALUES ($1,$2)
		 ON CONFLICT (course_id, user_id) DO NOTHING`, courseID, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "request failed")
	}
	return c.JSON(fiber.Map{"course_id": courseID, "enrollment_requested": true})
}

// MyCourses: enrolled courses with completion percentage.
func (h *Handlers) MyCourses(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT c.id, c.title, ce.status, COALESCE(c.image_url,''),
		  (SELECT count(*) FROM lessons l JOIN modules m ON m.id=l.module_id WHERE m.course_id=c.id) AS total,
		  (SELECT count(*) FROM lesson_progress lp JOIN lessons l ON l.id=lp.lesson_id
		     JOIN modules m ON m.id=l.module_id WHERE m.course_id=c.id AND lp.user_id=$1) AS done,
		  (SELECT ROUND(AVG(s.score)) FROM submissions s JOIN assessments a ON a.id=s.assessment_id
		     WHERE a.course_id=c.id AND a.type='quiz' AND s.user_id=$1 AND s.score IS NOT NULL) AS grade
		FROM course_enrollments ce JOIN courses c ON c.id=ce.course_id
		WHERE ce.user_id=$1 ORDER BY ce.enrolled_at DESC`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, status, img string
		var total, done int
		var grade *float64 // NULL when the student has no graded quiz in the course
		if err := rows.Scan(&id, &title, &status, &img, &total, &done, &grade); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		pct := 0
		if total > 0 {
			pct = done * 100 / total
		}
		var gradeVal any
		if grade != nil {
			gradeVal = int(*grade + 0.5)
		}
		out = append(out, fiber.Map{"id": id, "title": title, "status": status, "percent": pct,
			"image_url": img, "lessons_done": done, "lessons_total": total, "grade": gradeVal})
	}
	return c.JSON(fiber.Map{"my_courses": out})
}

// CourseContent: modules + lessons, only if the caller is enrolled.
func (h *Handlers) CourseContent(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if !h.isEnrolled(c, courseID) {
		return fiber.NewError(fiber.StatusForbidden, "not enrolled in this course")
	}
	rows, err := h.Pool.Query(c.Context(), `
		SELECT m.id, m.title, m.position, m.parent_module_id::text, l.id, l.title, l.type, `+playURLExpr+`, l.position, l.day_number,
		       COALESCE(l.downloadable, true),
		       EXISTS(SELECT 1 FROM lesson_progress lp WHERE lp.user_id=$2 AND lp.lesson_id=l.id)
		FROM modules m LEFT JOIN lessons l ON l.module_id=m.id AND l.is_published AND (l.publish_at IS NULL OR l.publish_at <= now())
		WHERE m.course_id=$1 ORDER BY m.position, l.day_number NULLS LAST, l.position`, courseID, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "content failed")
	}
	defer rows.Close()
	modules := map[string]fiber.Map{}
	parent := map[string]*string{}
	order := []string{}
	for rows.Next() {
		var mid, mtitle string
		var mpos int
		var mparent, lid, ltitle, ltype, lbody *string
		var lpos, day *int
		var done *bool
		var downloadable bool
		if err := rows.Scan(&mid, &mtitle, &mpos, &mparent, &lid, &ltitle, &ltype, &lbody, &lpos, &day, &downloadable, &done); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		if _, ok := modules[mid]; !ok {
			modules[mid] = fiber.Map{"id": mid, "title": mtitle, "parent_module_id": derefStr(mparent), "lessons": []fiber.Map{}, "submodules": []fiber.Map{}, "day_labels": map[string]string{}}
			parent[mid] = mparent
			order = append(order, mid)
		}
		if lid != nil {
			m := modules[mid]
			m["lessons"] = append(m["lessons"].([]fiber.Map), fiber.Map{
				"id": *lid, "title": *ltitle, "type": *ltype, "day_number": day,
				"url": derefStr(lbody), "downloadable": downloadable, "completed": done != nil && *done})
		}
	}
	// Attach each module's quiz grade (average of the student's quiz % on quizzes
	// scoped to that module) and the course-wide grade — both percentages, NULL
	// until the student has a graded quiz.
	if gr, gerr := h.Pool.Query(c.Context(),
		`SELECT a.module_id::text, ROUND(AVG(s.score))::int
		   FROM assessments a JOIN submissions s ON s.assessment_id=a.id AND s.user_id=$2 AND s.score IS NOT NULL
		  WHERE a.course_id=$1 AND a.type='quiz' AND a.module_id IS NOT NULL
		  GROUP BY a.module_id`, courseID, callerID(c)); gerr == nil {
		for gr.Next() {
			var mid string
			var g int
			if gr.Scan(&mid, &g) == nil {
				if m, ok := modules[mid]; ok {
					m["grade"] = g
				}
			}
		}
		gr.Close()
	}
	var courseGrade *int
	_ = h.Pool.QueryRow(c.Context(),
		`SELECT ROUND(AVG(s.score))::int FROM assessments a JOIN submissions s ON s.assessment_id=a.id AND s.user_id=$2 AND s.score IS NOT NULL
		  WHERE a.course_id=$1 AND a.type='quiz'`, courseID, callerID(c)).Scan(&courseGrade)
	// Custom day names (so students see "Kickoff" etc., not just "Day N").
	if lrows, lerr := h.Pool.Query(c.Context(),
		`SELECT dl.module_id::text, dl.day_number, dl.label
		 FROM module_day_labels dl JOIN modules m ON m.id=dl.module_id WHERE m.course_id=$1`, courseID); lerr == nil {
		for lrows.Next() {
			var mid, label string
			var day int
			if lrows.Scan(&mid, &day, &label) == nil {
				if mm, ok := modules[mid]; ok {
					if dl, ok := mm["day_labels"].(map[string]string); ok {
						dl[strconv.Itoa(day)] = label
					}
				}
			}
		}
		lrows.Close()
	}
	ordered := nestModules(modules, parent, order)
	return c.JSON(fiber.Map{"course_id": courseID, "modules": ordered, "course_grade": courseGrade})
}

// CompleteLesson marks a lesson done and, if it completes the course, issues a
// certificate and flips the enrollment to 'completed'.
func (h *Handlers) CompleteLesson(c *fiber.Ctx) error {
	lessonID := c.Params("id")
	var courseID string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT m.course_id FROM lessons l JOIN modules m ON m.id=l.module_id WHERE l.id=$1`,
		lessonID).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "lesson not found")
	}
	if !h.isEnrolled(c, courseID) {
		return fiber.NewError(fiber.StatusForbidden, "not enrolled")
	}
	_, _ = h.Pool.Exec(c.Context(),
		`INSERT INTO lesson_progress (user_id, lesson_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`,
		callerID(c), lessonID)

	// Course complete? (all lessons done)
	var total, done int
	_ = h.Pool.QueryRow(c.Context(), `
		SELECT (SELECT count(*) FROM lessons l JOIN modules m ON m.id=l.module_id WHERE m.course_id=$1),
		       (SELECT count(*) FROM lesson_progress lp JOIN lessons l ON l.id=lp.lesson_id
		          JOIN modules m ON m.id=l.module_id WHERE m.course_id=$1 AND lp.user_id=$2)`,
		courseID, callerID(c)).Scan(&total, &done)
	completed := total > 0 && done >= total
	if completed {
		_, _ = h.Pool.Exec(c.Context(),
			`UPDATE course_enrollments SET status='completed', completed_at=now()
			 WHERE course_id=$1 AND user_id=$2 AND status<>'completed'`, courseID, callerID(c))
		h.issueCertificate(c, courseID)
	}
	return c.JSON(fiber.Map{"lesson_id": lessonID, "completed": true, "course_completed": completed})
}

// ---- Assessments (student) -------------------------------------------------

// TakeAssessment returns the questions WITHOUT the correct answers.
func (h *Handlers) TakeAssessment(c *fiber.Ctx) error {
	assessID := c.Params("id")
	var courseID, title, atype, desc, due string
	var maxScore float64
	var published, autoAward bool
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT course_id, title, type, description, max_score, COALESCE(due_at::text,''), is_published, auto_award FROM assessments WHERE id=$1`,
		assessID).Scan(&courseID, &title, &atype, &desc, &maxScore, &due, &published, &autoAward); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "assessment not found")
	}
	if !published || !h.isEnrolled(c, courseID) {
		return fiber.NewError(fiber.StatusForbidden, "not available")
	}
	// The caller's existing submission (so the client can show status / grade /
	// prior assignment text on reopen).
	var subBody, subLink, subStatus, subFeedback string
	var subScore *float64
	var subAnswers []byte
	_ = h.Pool.QueryRow(c.Context(),
		`SELECT body, link, COALESCE(status,''), feedback, score, answers FROM submissions WHERE assessment_id=$1 AND user_id=$2`,
		assessID, callerID(c)).Scan(&subBody, &subLink, &subStatus, &subFeedback, &subScore, &subAnswers)
	answersMap := map[string]any{}
	if len(subAnswers) > 0 {
		_ = json.Unmarshal(subAnswers, &answersMap)
	}
	// Reveal the correct answers ONLY after the caller has submitted (so a review
	// can mark right/wrong) — never before.
	submitted := len(answersMap) > 0

	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, prompt, type, options, points, correct FROM questions WHERE assessment_id=$1 ORDER BY position`, assessID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "load failed")
	}
	defer rows.Close()
	qs := []fiber.Map{}
	for rows.Next() {
		var id, prompt, qtype, correct string
		var optsRaw []byte
		var points float64
		if err := rows.Scan(&id, &prompt, &qtype, &optsRaw, &points, &correct); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		var opts []string
		_ = json.Unmarshal(optsRaw, &opts)
		qm := fiber.Map{"id": id, "prompt": prompt, "type": qtype, "options": opts, "points": points}
		if submitted {
			qm["correct"] = correct
		}
		qs = append(qs, qm)
	}
	files := []fiber.Map{}
	if frows, ferr := h.Pool.Query(c.Context(),
		`SELECT id, filename, size FROM submission_files WHERE assessment_id=$1 AND user_id=$2 ORDER BY created_at`,
		assessID, callerID(c)); ferr == nil {
		defer frows.Close()
		for frows.Next() {
			var fid, fn string
			var sz int
			if frows.Scan(&fid, &fn, &sz) == nil {
				files = append(files, fiber.Map{"id": fid, "filename": fn, "size": sz})
			}
		}
	}
	return c.JSON(fiber.Map{
		"assessment_id": assessID, "title": title, "type": atype, "description": desc, "max_score": maxScore, "due_at": due, "auto_award": autoAward,
		"questions":  qs,
		"submission": fiber.Map{"body": subBody, "link": subLink, "status": subStatus, "feedback": subFeedback, "score": subScore, "files": files, "answers": answersMap},
	})
}

// SubmitAssessment stores answers, auto-grades objective questions, and leaves
// essay/short answers for manual grading.
func (h *Handlers) SubmitAssessment(c *fiber.Ctx) error {
	assessID := c.Params("id")
	var courseID, atype string
	var published, autoAward bool
	var maxScore float64
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT course_id, type, is_published, auto_award, max_score FROM assessments WHERE id=$1`, assessID).
		Scan(&courseID, &atype, &published, &autoAward, &maxScore); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "assessment not found")
	}
	if !published || !h.isEnrolled(c, courseID) {
		return fiber.NewError(fiber.StatusForbidden, "not available")
	}
	// Assignment: a free-text response and/or a link. Auto-award grants full
	// marks immediately; otherwise it waits for manual grading.
	if atype == "assignment" {
		var req struct {
			Body string `json:"body"`
			Link string `json:"link"`
		}
		if err := c.BodyParser(&req); err != nil {
			return fiber.NewError(fiber.StatusBadRequest, "invalid body")
		}
		body := strings.TrimSpace(req.Body)
		link := strings.TrimSpace(req.Link)
		if body == "" && link == "" {
			return fiber.NewError(fiber.StatusBadRequest, "add a response or a link")
		}
		status := "submitted"
		var score any
		if autoAward {
			status = "graded"
			score = maxScore
		}
		if _, err := h.Pool.Exec(c.Context(), `
			INSERT INTO submissions (assessment_id, user_id, body, link, status, score)
			VALUES ($1,$2,$3,$4,$5,$6)
			ON CONFLICT (assessment_id, user_id)
			DO UPDATE SET body=EXCLUDED.body, link=EXCLUDED.link, submitted_at=now(),
			   status=EXCLUDED.status,
			   score = CASE WHEN EXCLUDED.status='graded' THEN EXCLUDED.score ELSE submissions.score END`,
			assessID, callerID(c), body, link, status, score); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "submit failed")
		}
		return c.JSON(fiber.Map{"assessment_id": assessID, "status": status})
	}
	// Quizzes are single-attempt: once answers are recorded, no re-editing.
	// (An empty "{}" from a file-only upload still allows the first answer submit.)
	var prevAnswers []byte
	_ = h.Pool.QueryRow(c.Context(),
		`SELECT answers FROM submissions WHERE assessment_id=$1 AND user_id=$2`, assessID, callerID(c)).Scan(&prevAnswers)
	if len(prevAnswers) > 2 {
		return fiber.NewError(fiber.StatusConflict, "already submitted")
	}
	var req struct {
		Answers map[string]string `json:"answers"` // {question_id: answer}
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}

	// Grade objective questions; detect if any need manual grading.
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, type, correct, points FROM questions WHERE assessment_id=$1`, assessID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "grade load failed")
	}
	defer rows.Close()
	var autoScore, totalPoints float64
	total, correctCount := 0, 0
	needsManual := false
	for rows.Next() {
		var id, qtype, correct string
		var points float64
		if err := rows.Scan(&id, &qtype, &correct, &points); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		total++
		totalPoints += points
		switch qtype {
		case "mcq", "truefalse":
			if strings.EqualFold(strings.TrimSpace(req.Answers[id]), strings.TrimSpace(correct)) {
				autoScore += points
				correctCount++
			}
		case "short", "fill":
			// Case-insensitive; the answer key may list accepted answers with "|".
			if matchShortAnswer(req.Answers[id], correct) {
				autoScore += points
				correctCount++
			}
		case "numeric":
			if matchNumeric(req.Answers[id], correct) {
				autoScore += points
				correctCount++
			}
		case "multi":
			if matchMultiSet(req.Answers[id], correct) {
				autoScore += points
				correctCount++
			}
		default: // essay / upload — needs a human
			needsManual = true
		}
	}
	answersJSON, _ := json.Marshal(req.Answers)
	// Score is a PERCENTAGE (0-100): every question is worth 1 point, so this is
	// just correct/total. Stored as the submission's score so it reads as "N%".
	percent := 0
	if totalPoints > 0 {
		percent = int(math.Round(autoScore / totalPoints * 100))
	}
	status := "graded"
	var score any = percent
	if needsManual {
		status = "submitted"
		score = nil // pending manual grading
	}
	// Retakes are allowed; we keep the BEST score. GREATEST ignores NULLs, so an
	// essay retake (score pending) never wipes a previous graded score.
	_, err = h.Pool.Exec(c.Context(), `
		INSERT INTO submissions (assessment_id, user_id, answers, score, status)
		VALUES ($1,$2,$3,$4,$5)
		ON CONFLICT (assessment_id, user_id)
		DO UPDATE SET answers=EXCLUDED.answers, submitted_at=now(),
		   score  = GREATEST(submissions.score, EXCLUDED.score),
		   status = CASE WHEN 'graded' IN (submissions.status, EXCLUDED.status) THEN 'graded' ELSE EXCLUDED.status END`,
		assessID, callerID(c), string(answersJSON), score, status)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "submit failed")
	}
	return c.JSON(fiber.Map{
		"assessment_id": assessID, "status": status,
		"needs_manual_grading": needsManual,
		"score":                percent, "percent": percent,
		"correct": correctCount, "total": total,
	})
}

// matchShortAnswer compares a short answer case-insensitively; the answer key may
// list several accepted answers separated by "|".
func matchShortAnswer(ans, correct string) bool {
	a := strings.ToLower(strings.TrimSpace(ans))
	if a == "" {
		return false
	}
	for _, acc := range strings.Split(correct, "|") {
		if a == strings.ToLower(strings.TrimSpace(acc)) {
			return true
		}
	}
	return false
}

// matchNumeric compares two numbers within a small tolerance.
func matchNumeric(ans, correct string) bool {
	a, e1 := strconv.ParseFloat(strings.TrimSpace(ans), 64)
	c, e2 := strconv.ParseFloat(strings.TrimSpace(correct), 64)
	if e1 != nil || e2 != nil {
		return false
	}
	return math.Abs(a-c) < 1e-6
}

// matchMultiSet compares a multiple-response answer to the key. Both are JSON
// arrays of option strings; order-insensitive, case-insensitive exact-set match.
func matchMultiSet(ans, correct string) bool {
	var a, c []string
	if json.Unmarshal([]byte(strings.TrimSpace(ans)), &a) != nil {
		return false
	}
	if json.Unmarshal([]byte(strings.TrimSpace(correct)), &c) != nil {
		return false
	}
	if len(a) == 0 || len(a) != len(c) {
		return false
	}
	want := map[string]bool{}
	for _, x := range c {
		want[strings.ToLower(strings.TrimSpace(x))] = true
	}
	for _, x := range a {
		if !want[strings.ToLower(strings.TrimSpace(x))] {
			return false
		}
	}
	return true
}

// MyGrades: the caller's graded submissions.
func (h *Handlers) MyGrades(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT a.title, c.title, s.score, a.max_score, s.status, s.feedback
		FROM submissions s JOIN assessments a ON a.id=s.assessment_id JOIN courses c ON c.id=a.course_id
		WHERE s.user_id=$1 ORDER BY s.submitted_at DESC`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "load failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var atitle, ctitle, status, feedback string
		var score, max *float64
		if err := rows.Scan(&atitle, &ctitle, &score, &max, &status, &feedback); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"assessment": atitle, "course": ctitle, "score": score,
			"max_score": max, "status": status, "feedback": feedback})
	}
	return c.JSON(fiber.Map{"grades": out})
}

// MyTranscript: dashboard summary (counts + certificates + quiz XP).
func (h *Handlers) MyTranscript(c *fiber.Ctx) error {
	var enrolled, completed, certs, quizXP int
	_ = h.Pool.QueryRow(c.Context(), `
		SELECT (SELECT count(*) FROM course_enrollments WHERE user_id=$1),
		       (SELECT count(*) FROM course_enrollments WHERE user_id=$1 AND status='completed'),
		       (SELECT count(*) FROM certificates WHERE user_id=$1),
		       COALESCE((SELECT ROUND(SUM(score)) FROM submissions WHERE user_id=$1 AND score IS NOT NULL),0)::int`,
		callerID(c)).Scan(&enrolled, &completed, &certs, &quizXP)
	return c.JSON(fiber.Map{"enrolled": enrolled, "completed": completed, "certificates": certs, "quiz_xp": quizXP})
}

func (h *Handlers) MyCertificates(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT cert.serial, c.title, cert.issued_at FROM certificates cert
		JOIN courses c ON c.id=cert.course_id WHERE cert.user_id=$1 ORDER BY cert.issued_at DESC`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "load failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var serial, title string
		var at any
		if err := rows.Scan(&serial, &title, &at); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"serial": serial, "course": title, "issued_at": at})
	}
	return c.JSON(fiber.Map{"certificates": out})
}

// MyCalendar: upcoming sessions + assessment due dates for enrolled courses.
func (h *Handlers) MyCalendar(c *fiber.Ctx) error {
	// Aggregates everything the admin/mentor schedules for the student:
	// live classes, assignment/quiz deadlines, and announcements (activities).
	// Includes a short recent window so just-passed items still show.
	// ref_id/live_kind/join_url are only meaningful for 'session' rows (so the
	// calendar can open a live class); empty for the other event kinds.
	rows, err := h.Pool.Query(c.Context(), `
		SELECT 'session' AS kind, cs.title, cs.starts_at AS at, c.title AS course,
		       cs.id::text AS ref_id,
		       CASE WHEN cs.media_asset_id IS NOT NULL THEN 'simulated' ELSE 'external' END AS live_kind,
		       COALESCE(cs.join_url,'') AS join_url,
		       COALESCE(cs.webinar_id::text,'') AS webinar_id,
		       (now() > COALESCE(cs.ends_at,
		           CASE WHEN cs.media_asset_id IS NOT NULL AND ma.duration_seconds > 0
		                THEN cs.starts_at + make_interval(secs => ma.duration_seconds)
		                ELSE cs.starts_at + interval '2 hours' END)) AS ended
		FROM class_sessions cs JOIN courses c ON c.id=cs.course_id
		JOIN course_enrollments ce ON ce.course_id=c.id AND ce.user_id=$1
		LEFT JOIN media_assets ma ON ma.id=cs.media_asset_id
		WHERE cs.starts_at >= now() - interval '180 days'
		  AND (cs.batch_number IS NULL OR cs.batch_number = (SELECT batch FROM users WHERE id=$1))
		UNION ALL
		SELECT 'assessment_due', a.title, a.due_at, c.title, ''::text, ''::text, ''::text, ''::text, false
		FROM assessments a JOIN courses c ON c.id=a.course_id
		JOIN course_enrollments ce ON ce.course_id=c.id AND ce.user_id=$1
		WHERE a.due_at IS NOT NULL AND a.due_at >= now() - interval '7 days' AND a.is_published
		UNION ALL
		SELECT 'announcement', an.title, an.created_at, COALESCE(c.title,''), ''::text, ''::text, ''::text, ''::text, false
		FROM announcements an
		LEFT JOIN courses c ON c.id=an.course_id
		JOIN users me ON me.id=$1
		WHERE an.created_at >= now() - interval '30 days'
		  AND ( (an.course_id IS NULL AND (
		            an.audience='all'
		         OR (an.audience='batch' AND an.batch_number = me.batch)
		         OR (an.audience='role'  AND an.role = me.role)))
		     OR (an.course_id IS NOT NULL AND EXISTS (
		            SELECT 1 FROM course_enrollments ce WHERE ce.course_id=an.course_id AND ce.user_id=me.id)) )
		UNION ALL
		SELECT 'event', e.title, e.starts_at, COALESCE(e.location,''), ''::text, ''::text, ''::text, ''::text, false
		FROM calendar_events e JOIN users me ON me.id=$1
		WHERE e.starts_at >= now() - interval '7 days'
		  AND ( e.audience='all'
		     OR (e.audience='batch' AND e.batch_number = me.batch)
		     OR (e.audience='role'  AND e.role = me.role) )
		ORDER BY at`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "calendar failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var kind, title, course, refID, liveKind, joinURL, webinarID string
		var at any
		var ended bool
		if err := rows.Scan(&kind, &title, &at, &course, &refID, &liveKind, &joinURL, &webinarID, &ended); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		row := fiber.Map{"kind": kind, "title": title, "at": at, "course": course}
		if kind == "session" {
			row["id"] = refID
			row["live_kind"] = liveKind
			row["join_url"] = joinURL
			row["webinar_id"] = webinarID
			row["ended"] = ended
		}
		out = append(out, row)
	}
	return c.JSON(fiber.Map{"calendar": out})
}

// MyAssessments lists the published quizzes/assignments across the student's
// enrolled courses, ordered by course day so the app can show a day-by-day plan
// (Day 1, Day 2, …). Items without a day_number sort last.
func (h *Handlers) MyAssessments(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT a.id, a.title, a.type, a.max_score, a.day_number,
		       COALESCE(a.due_at::text,''), c.title AS course,
		       (SELECT count(*) FROM questions q WHERE q.assessment_id=a.id) AS qcount,
		       s.id IS NOT NULL AS submitted,
		       s.score, COALESCE(s.status,'') AS sub_status
		FROM assessments a
		JOIN courses c ON c.id=a.course_id
		JOIN course_enrollments ce ON ce.course_id=c.id AND ce.user_id=$1
		LEFT JOIN submissions s ON s.assessment_id=a.id AND s.user_id=$1
		WHERE a.is_published
		ORDER BY a.day_number NULLS LAST, c.title, a.created_at`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "load failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, typ, due, course, subStatus string
		var maxScore float64
		var day *int
		var qc int
		var submitted bool
		var score *float64
		if err := rows.Scan(&id, &title, &typ, &maxScore, &day, &due, &course, &qc, &submitted, &score, &subStatus); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "title": title, "type": typ, "max_score": maxScore,
			"day_number": day, "due_at": due, "course": course, "questions": qc, "submitted": submitted,
			"score": score, "status": subStatus})
	}
	return c.JSON(fiber.Map{"assessments": out})
}

// SendMessage: direct message to another user.
func (h *Handlers) SendMessage(c *fiber.Ctx) error {
	var req struct {
		RecipientID string `json:"recipient_id"`
		Body        string `json:"body"`
	}
	if err := c.BodyParser(&req); err != nil || req.RecipientID == "" || strings.TrimSpace(req.Body) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "recipient_id and body required")
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO messages (sender_id, recipient_id, body) VALUES ($1,$2,$3) RETURNING id`,
		callerID(c), req.RecipientID, req.Body).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "send failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "sent": true})
}

// Inbox: messages received by the caller.
func (h *Handlers) Inbox(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT m.id, u.full_name, m.body, m.read_at IS NOT NULL, m.created_at
		FROM messages m JOIN users u ON u.id=m.sender_id
		WHERE m.recipient_id=$1 ORDER BY m.created_at DESC LIMIT 200`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "load failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, from, body string
		var read bool
		var at any
		if err := rows.Scan(&id, &from, &body, &read, &at); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "from": from, "body": body, "read": read, "at": at})
	}
	return c.JSON(fiber.Map{"inbox": out})
}

// PostForum: create or append to a course forum thread (enrolled users).
func (h *Handlers) PostForum(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if !h.isEnrolled(c, courseID) && callerRole(c) == "student" {
		return fiber.NewError(fiber.StatusForbidden, "not enrolled")
	}
	var req struct {
		ThreadID string `json:"thread_id"`
		Title    string `json:"title"`
		Body     string `json:"body"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Body) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "body required")
	}
	threadID := req.ThreadID
	if threadID == "" {
		if strings.TrimSpace(req.Title) == "" {
			return fiber.NewError(fiber.StatusBadRequest, "title required for a new thread")
		}
		if err := h.Pool.QueryRow(c.Context(),
			`INSERT INTO forum_threads (course_id, author_id, title) VALUES ($1,$2,$3) RETURNING id`,
			courseID, callerID(c), req.Title).Scan(&threadID); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "thread failed")
		}
	}
	var pid string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO forum_posts (thread_id, author_id, body) VALUES ($1,$2,$3) RETURNING id`,
		threadID, callerID(c), req.Body).Scan(&pid); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "post failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"thread_id": threadID, "post_id": pid})
}

// ---- helpers ---------------------------------------------------------------

func derefStr(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func (h *Handlers) isEnrolled(c *fiber.Ctx, courseID string) bool {
	var ok bool
	_ = h.Pool.QueryRow(c.Context(),
		`SELECT EXISTS(SELECT 1 FROM course_enrollments WHERE course_id=$1 AND user_id=$2)`,
		courseID, callerID(c)).Scan(&ok)
	return ok
}

func (h *Handlers) issueCertificate(c *fiber.Ctx, courseID string) {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	serial := "ONROL-" + strings.ToUpper(hex.EncodeToString(b))
	_, _ = h.Pool.Exec(c.Context(),
		`INSERT INTO certificates (user_id, course_id, serial) VALUES ($1,$2,$3)
		 ON CONFLICT (user_id, course_id) DO NOTHING`, callerID(c), courseID, serial)
}

// (unused import guard removed at build) — pgx kept for potential row helpers.
var _ = pgx.ErrNoRows
