package handlers

import (
	"encoding/json"
	"strings"

	"github.com/gofiber/fiber/v2"
)

// study kinds the editor/store understands.
var studyKinds = map[string]bool{
	"guides": true, "cheats": true, "mindmap": true, "flashcards": true, "formulas": true,
}

// studyRow reads one material row and shapes it for JSON, decoding the items
// blob so the client gets a real array/object (not a JSON string).
func scanStudyRows(rows interface {
	Next() bool
	Scan(...any) error
	Close()
}) ([]fiber.Map, error) {
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, kind, title, body, note string
		var itemsRaw []byte
		var pos int
		if err := rows.Scan(&id, &kind, &title, &body, &note, &itemsRaw, &pos); err != nil {
			return nil, err
		}
		var items any
		if len(itemsRaw) > 0 {
			_ = json.Unmarshal(itemsRaw, &items)
		}
		if items == nil {
			items = []any{}
		}
		out = append(out, fiber.Map{"id": id, "kind": kind, "title": title,
			"body": body, "note": note, "items": items, "position": pos})
	}
	return out, nil
}

// ListCourseStudy returns all Study Hub material for a course (instructor view).
func (h *Handlers) ListCourseStudy(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, kind, title, body, note, COALESCE(items::text,'[]'), position
		 FROM study_materials WHERE course_id=$1 ORDER BY kind, position, created_at`, courseID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	out, err := scanStudyRows(rows)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
	}
	return c.JSON(fiber.Map{"materials": out})
}

type studyBody struct {
	Kind     string          `json:"kind"`
	Title    string          `json:"title"`
	Body     string          `json:"body"`
	Note     string          `json:"note"`
	Items    json.RawMessage `json:"items"` // array (guides/cheats) or [{name,leaves}] (mindmap)
	Position int             `json:"position"`
}

// itemsText validates the items blob and returns its text form ('[]' when empty).
func itemsText(raw json.RawMessage) string {
	s := strings.TrimSpace(string(raw))
	if s == "" || s == "null" {
		return "[]"
	}
	var probe any
	if json.Unmarshal(raw, &probe) != nil {
		return "[]"
	}
	return s
}

// AddStudyMaterial appends a card to a course's Study Hub.
func (h *Handlers) AddStudyMaterial(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req studyBody
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	req.Kind = strings.TrimSpace(req.Kind)
	if !studyKinds[req.Kind] {
		return fiber.NewError(fiber.StatusBadRequest, "unknown kind")
	}
	if strings.TrimSpace(req.Title) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title required")
	}
	if req.Position == 0 {
		var maxPos int
		_ = h.Pool.QueryRow(c.Context(),
			`SELECT COALESCE(MAX(position),0) FROM study_materials WHERE course_id=$1 AND kind=$2`,
			courseID, req.Kind).Scan(&maxPos)
		req.Position = maxPos + 1
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO study_materials (course_id, kind, title, body, note, items, position)
		 VALUES ($1,$2,$3,$4,$5,$6::jsonb,$7) RETURNING id`,
		courseID, req.Kind, strings.TrimSpace(req.Title), req.Body, req.Note, itemsText(req.Items), req.Position).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

// studyCourse returns the course a material belongs to (for auth scoping).
func (h *Handlers) studyCourse(c *fiber.Ctx, id string) (string, error) {
	var courseID string
	if err := h.Pool.QueryRow(c.Context(), `SELECT course_id FROM study_materials WHERE id=$1`, id).Scan(&courseID); err != nil {
		return "", fiber.NewError(fiber.StatusNotFound, "material not found")
	}
	return courseID, nil
}

// UpdateStudyMaterial edits a Study Hub card (partial — blank fields untouched).
func (h *Handlers) UpdateStudyMaterial(c *fiber.Ctx) error {
	id := c.Params("id")
	courseID, err := h.studyCourse(c, id)
	if err != nil {
		return err
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Title    *string         `json:"title"`
		Body     *string         `json:"body"`
		Note     *string         `json:"note"`
		Items    json.RawMessage `json:"items"`
		Position *int            `json:"position"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	var itemsPtr *string
	if len(req.Items) > 0 {
		s := itemsText(req.Items)
		itemsPtr = &s
	}
	if _, err := h.Pool.Exec(c.Context(),
		`UPDATE study_materials SET
		   title    = COALESCE($2, title),
		   body     = COALESCE($3, body),
		   note     = COALESCE($4, note),
		   items    = COALESCE($5::jsonb, items),
		   position = COALESCE($6, position)
		 WHERE id=$1`,
		id, trimmedPtr(req.Title), req.Body, req.Note, itemsPtr, req.Position); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	return c.JSON(fiber.Map{"id": id, "updated": true})
}

// DeleteStudyMaterial removes one Study Hub card.
func (h *Handlers) DeleteStudyMaterial(c *fiber.Ctx) error {
	id := c.Params("id")
	courseID, err := h.studyCourse(c, id)
	if err != nil {
		return err
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM study_materials WHERE id=$1`, id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// MyStudyMaterials returns a course's Study Hub material for an enrolled student.
func (h *Handlers) MyStudyMaterials(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if !h.isEnrolled(c, courseID) {
		return fiber.NewError(fiber.StatusForbidden, "not enrolled")
	}
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, kind, title, body, note, COALESCE(items::text,'[]'), position
		 FROM study_materials WHERE course_id=$1 ORDER BY kind, position, created_at`, courseID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	out, err := scanStudyRows(rows)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
	}
	return c.JSON(fiber.Map{"materials": out})
}
