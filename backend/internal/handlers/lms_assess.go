package handlers

import (
	"encoding/json"
	"strings"

	"github.com/gofiber/fiber/v2"
)

// ListCourseAssessments returns a course's quizzes & assignments (with a
// question count) so the console can show and manage them.
func (h *Handlers) ListCourseAssessments(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	rows, err := h.Pool.Query(c.Context(),
		`SELECT a.id, a.title, a.type, a.max_score, COALESCE(a.due_at::text,''), a.is_published, a.day_number,
		        a.module_id, COALESCE(m.title,''),
		        (SELECT count(*) FROM questions q WHERE q.assessment_id=a.id) AS qcount
		 FROM assessments a LEFT JOIN modules m ON m.id=a.module_id
		 WHERE a.course_id=$1
		 ORDER BY a.day_number NULLS LAST, a.created_at DESC`, courseID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, typ, due, moduleTitle string
		var maxScore float64
		var pub bool
		var day *int
		var moduleID *string
		var qc int
		if err := rows.Scan(&id, &title, &typ, &maxScore, &due, &pub, &day, &moduleID, &moduleTitle, &qc); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "title": title, "type": typ, "max_score": maxScore,
			"due_at": due, "is_published": pub, "day_number": day, "module_id": moduleID,
			"module": moduleTitle, "questions": qc})
	}
	return c.JSON(fiber.Map{"assessments": out})
}

// CreateAssessment adds a quiz/assignment to a course.
func (h *Handlers) CreateAssessment(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Title       string  `json:"title"`
		Type        string  `json:"type"`
		MaxScore    float64 `json:"max_score"`
		DueAt       string  `json:"due_at"`
		DayNumber   *int    `json:"day_number"`
		ModuleID    string  `json:"module_id"`
		IsPublished bool    `json:"is_published"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Title) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title required")
	}
	if req.Type == "" {
		req.Type = "quiz"
	}
	if req.MaxScore == 0 {
		req.MaxScore = 100
	}
	var due any
	if req.DueAt != "" {
		due = req.DueAt
	}
	var module any
	if req.ModuleID != "" {
		module = req.ModuleID
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO assessments (course_id, module_id, title, type, max_score, due_at, day_number, is_published, created_by)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING id`,
		courseID, module, req.Title, req.Type, req.MaxScore, due, req.DayNumber, req.IsPublished, callerID(c)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "title": req.Title, "type": req.Type})
}

// DeleteAssessment removes a quiz/assignment (and its questions).
func (h *Handlers) DeleteAssessment(c *fiber.Ctx) error {
	assessID := c.Params("id")
	courseID, err := h.assessmentCourse(c, assessID)
	if err != nil {
		return err
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM assessments WHERE id=$1`, assessID); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// ListQuestions returns a quiz's questions WITH correct answers — the staff
// quiz-builder view (students get them without answers via TakeAssessment).
func (h *Handlers) ListQuestions(c *fiber.Ctx) error {
	assessID := c.Params("id")
	courseID, err := h.assessmentCourse(c, assessID)
	if err != nil {
		return err
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, prompt, type, COALESCE(options::text,'[]'), COALESCE(correct,''), points, position
		 FROM questions WHERE assessment_id=$1 ORDER BY position, created_at`, assessID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, prompt, typ, optsJSON, correct string
		var points float64
		var pos int
		if err := rows.Scan(&id, &prompt, &typ, &optsJSON, &correct, &points, &pos); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		var opts []string
		_ = json.Unmarshal([]byte(optsJSON), &opts)
		out = append(out, fiber.Map{"id": id, "prompt": prompt, "type": typ, "options": opts,
			"correct": correct, "points": points, "position": pos})
	}
	return c.JSON(fiber.Map{"questions": out})
}

// DeleteQuestion removes a single question from a quiz.
func (h *Handlers) DeleteQuestion(c *fiber.Ctx) error {
	qid := c.Params("id")
	var courseID string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT a.course_id FROM questions q JOIN assessments a ON a.id=q.assessment_id WHERE q.id=$1`,
		qid).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "question not found")
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM questions WHERE id=$1`, qid); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// AddQuestion appends a question to an assessment.
func (h *Handlers) AddQuestion(c *fiber.Ctx) error {
	assessID := c.Params("id")
	courseID, err := h.assessmentCourse(c, assessID)
	if err != nil {
		return err
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Prompt   string   `json:"prompt"`
		Type     string   `json:"type"`
		Options  []string `json:"options"`
		Correct  string   `json:"correct"`
		Points   float64  `json:"points"`
		Position int      `json:"position"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Prompt) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "prompt required")
	}
	if req.Type == "" {
		req.Type = "mcq"
	}
	if req.Points == 0 {
		req.Points = 1
	}
	// The console doesn't send a position — append after the last question so
	// manually-added questions keep their insertion order (not all stacked at 0).
	if req.Position == 0 {
		var maxPos int
		_ = h.Pool.QueryRow(c.Context(),
			`SELECT COALESCE(MAX(position),0) FROM questions WHERE assessment_id=$1`, assessID).Scan(&maxPos)
		req.Position = maxPos + 1
	}
	opts, _ := json.Marshal(req.Options)
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO questions (assessment_id, prompt, type, options, correct, points, position)
		 VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
		assessID, req.Prompt, req.Type, string(opts), req.Correct, req.Points, req.Position).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

// ListSubmissions returns submissions for an assessment (graders only).
func (h *Handlers) ListSubmissions(c *fiber.Ctx) error {
	assessID := c.Params("id")
	courseID, err := h.assessmentCourse(c, assessID)
	if err != nil {
		return err
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	rows, err := h.Pool.Query(c.Context(), `
		SELECT s.id, s.user_id, u.full_name, s.status, s.score, s.submitted_at
		FROM submissions s JOIN users u ON u.id=s.user_id
		WHERE s.assessment_id=$1 ORDER BY s.submitted_at`, assessID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, uid, name, status string
		var score *float64
		var at any
		if err := rows.Scan(&id, &uid, &name, &status, &score, &at); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "user_id": uid, "student": name,
			"status": status, "score": score, "submitted_at": at})
	}
	return c.JSON(fiber.Map{"submissions": out})
}

// GradeSubmission applies a manual score + feedback and releases the grade.
func (h *Handlers) GradeSubmission(c *fiber.Ctx) error {
	subID := c.Params("id")
	var courseID string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT a.course_id FROM submissions s JOIN assessments a ON a.id=s.assessment_id WHERE s.id=$1`,
		subID).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "submission not found")
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Score    float64 `json:"score"`
		Feedback string  `json:"feedback"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	_, err := h.Pool.Exec(c.Context(),
		`UPDATE submissions SET score=$2, feedback=$3, status='graded', graded_by=$4, graded_at=now() WHERE id=$1`,
		subID, req.Score, req.Feedback, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "grade failed")
	}
	return c.JSON(fiber.Map{"id": subID, "score": req.Score, "status": "graded"})
}

func (h *Handlers) assessmentCourse(c *fiber.Ctx, assessID string) (string, error) {
	var courseID string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT course_id FROM assessments WHERE id=$1`, assessID).Scan(&courseID); err != nil {
		return "", fiber.NewError(fiber.StatusNotFound, "assessment not found")
	}
	return courseID, nil
}
