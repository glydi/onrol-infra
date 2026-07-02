package handlers

import (
	"encoding/json"
	"strings"

	"github.com/gofiber/fiber/v2"
)

// trimmedPtr returns a pointer to the trimmed string, or nil if blank — used so a
// blank/absent field in a PATCH body leaves the column untouched (COALESCE).
func trimmedPtr(s *string) *string {
	if s == nil {
		return nil
	}
	t := strings.TrimSpace(*s)
	if t == "" {
		return nil
	}
	return &t
}

// UpdateModule renames or repositions a module.
func (h *Handlers) UpdateModule(c *fiber.Ctx) error {
	id := c.Params("id")
	var courseID string
	if err := h.Pool.QueryRow(c.Context(), `SELECT course_id FROM modules WHERE id=$1`, id).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "module not found")
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Title    *string `json:"title"`
		Position *int    `json:"position"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if _, err := h.Pool.Exec(c.Context(),
		`UPDATE modules SET title=COALESCE($2, title), position=COALESCE($3, position) WHERE id=$1`,
		id, trimmedPtr(req.Title), req.Position); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	return c.JSON(fiber.Map{"id": id, "updated": true})
}

// UpdateLesson edits a lesson's title/type/content/download flag/position.
func (h *Handlers) UpdateLesson(c *fiber.Ctx) error {
	id := c.Params("id")
	var courseID string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT m.course_id FROM lessons l JOIN modules m ON m.id=l.module_id WHERE l.id=$1`, id).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "lesson not found")
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Title        *string `json:"title"`
		Type         *string `json:"type"`
		Body         *string `json:"body"`
		Position     *int    `json:"position"`
		Downloadable *bool   `json:"downloadable"`
		DayNumber    *int    `json:"day_number"` // set the module day
		ClearDay     bool    `json:"clear_day"`  // move back to "unscheduled"
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if _, err := h.Pool.Exec(c.Context(),
		`UPDATE lessons SET
		   title        = COALESCE($2, title),
		   type         = COALESCE($3, type),
		   body         = COALESCE($4, body),
		   position     = COALESCE($5, position),
		   downloadable = COALESCE($6, downloadable),
		   day_number   = COALESCE($7, day_number)
		 WHERE id=$1`,
		id, trimmedPtr(req.Title), trimmedPtr(req.Type), req.Body, req.Position, req.Downloadable, req.DayNumber); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if req.ClearDay {
		_, _ = h.Pool.Exec(c.Context(), `UPDATE lessons SET day_number=NULL WHERE id=$1`, id)
	}
	return c.JSON(fiber.Map{"id": id, "updated": true})
}

// UpdateAssessment edits a quiz/assignment's details and its scope — either a
// module (module-wise) or a day number (date-wise), kept mutually exclusive.
func (h *Handlers) UpdateAssessment(c *fiber.Ctx) error {
	id := c.Params("id")
	courseID, err := h.assessmentCourse(c, id)
	if err != nil {
		return err
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Title       *string  `json:"title"`
		Type        *string  `json:"type"`
		MaxScore    *float64 `json:"max_score"`
		IsPublished *bool    `json:"is_published"`
		DueAt       *string  `json:"due_at"`     // ISO8601; "" clears
		ModuleID    *string  `json:"module_id"`  // "" clears; a value also clears day_number
		DayNumber   *int     `json:"day_number"` // a value also clears module_id
		ClearDay    bool     `json:"clear_day"`
		AutoAward   *bool    `json:"auto_award"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if _, err := h.Pool.Exec(c.Context(),
		`UPDATE assessments SET
		   title        = COALESCE($2, title),
		   type         = COALESCE($3, type),
		   max_score    = COALESCE($4, max_score),
		   is_published = COALESCE($5, is_published),
		   auto_award   = COALESCE($6, auto_award)
		 WHERE id=$1`,
		id, trimmedPtr(req.Title), trimmedPtr(req.Type), req.MaxScore, req.IsPublished, req.AutoAward); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if req.DueAt != nil {
		if strings.TrimSpace(*req.DueAt) == "" {
			_, _ = h.Pool.Exec(c.Context(), `UPDATE assessments SET due_at=NULL WHERE id=$1`, id)
		} else {
			_, _ = h.Pool.Exec(c.Context(), `UPDATE assessments SET due_at=$2::timestamptz WHERE id=$1`, id, strings.TrimSpace(*req.DueAt))
		}
	}
	// Scope is module-wise OR date-wise — setting one clears the other.
	if req.ModuleID != nil {
		if strings.TrimSpace(*req.ModuleID) == "" {
			_, _ = h.Pool.Exec(c.Context(), `UPDATE assessments SET module_id=NULL WHERE id=$1`, id)
		} else {
			_, _ = h.Pool.Exec(c.Context(), `UPDATE assessments SET module_id=$2, day_number=NULL WHERE id=$1`, id, strings.TrimSpace(*req.ModuleID))
		}
	}
	if req.DayNumber != nil {
		_, _ = h.Pool.Exec(c.Context(), `UPDATE assessments SET day_number=$2, module_id=NULL WHERE id=$1`, id, *req.DayNumber)
	}
	if req.ClearDay {
		_, _ = h.Pool.Exec(c.Context(), `UPDATE assessments SET day_number=NULL WHERE id=$1`, id)
	}
	return c.JSON(fiber.Map{"id": id, "updated": true})
}

// UpdateQuestion edits a question's prompt/type/options/answer/points/position.
func (h *Handlers) UpdateQuestion(c *fiber.Ctx) error {
	id := c.Params("id")
	var courseID string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT a.course_id FROM questions q JOIN assessments a ON a.id=q.assessment_id WHERE q.id=$1`, id).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "question not found")
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Prompt   *string   `json:"prompt"`
		Type     *string   `json:"type"`
		Options  *[]string `json:"options"`
		Correct  *string   `json:"correct"`
		Points   *float64  `json:"points"`
		Position *int      `json:"position"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	var opts *string
	if req.Options != nil {
		b, _ := json.Marshal(*req.Options)
		s := string(b)
		opts = &s
	}
	if _, err := h.Pool.Exec(c.Context(),
		`UPDATE questions SET
		   prompt   = COALESCE($2, prompt),
		   type     = COALESCE($3, type),
		   options  = COALESCE($4::jsonb, options),
		   correct  = COALESCE($5, correct),
		   points   = COALESCE($6, points),
		   position = COALESCE($7, position)
		 WHERE id=$1`,
		id, trimmedPtr(req.Prompt), trimmedPtr(req.Type), opts, req.Correct, req.Points, req.Position); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	return c.JSON(fiber.Map{"id": id, "updated": true})
}
