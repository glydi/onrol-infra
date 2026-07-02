package handlers

import (
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"
)

// Personal study notes — each user's own, private to them.

// MyNotes lists the caller's notes, newest-edited first.
func (h *Handlers) MyNotes(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, title, body, updated_at FROM notes WHERE user_id=$1 ORDER BY updated_at DESC LIMIT 500`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "notes load failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, body string
		var at time.Time
		if err := rows.Scan(&id, &title, &body, &at); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "title": title, "body": body, "updated_at": at.UTC().Format(time.RFC3339)})
	}
	return c.JSON(fiber.Map{"notes": out})
}

// noteBody parses {title, body}; requires at least one non-empty, caps lengths.
func noteBody(c *fiber.Ctx) (title, body string, err error) {
	var req struct {
		Title string `json:"title"`
		Body  string `json:"body"`
	}
	if e := c.BodyParser(&req); e != nil {
		return "", "", fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	title = strings.TrimSpace(req.Title)
	body = strings.TrimSpace(req.Body)
	if title == "" && body == "" {
		return "", "", fiber.NewError(fiber.StatusBadRequest, "note is empty")
	}
	if len(title) > 200 {
		title = title[:200]
	}
	if len(body) > 20000 {
		body = body[:20000]
	}
	return title, body, nil
}

// CreateNote adds a note for the caller.
func (h *Handlers) CreateNote(c *fiber.Ctx) error {
	title, body, perr := noteBody(c)
	if perr != nil {
		return perr
	}
	var id string
	var at time.Time
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO notes (user_id, title, body) VALUES ($1,$2,$3) RETURNING id, updated_at`,
		callerID(c), title, body).Scan(&id, &at); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "title": title, "body": body, "updated_at": at.UTC().Format(time.RFC3339)})
}

// UpdateNote edits one of the caller's notes.
func (h *Handlers) UpdateNote(c *fiber.Ctx) error {
	title, body, perr := noteBody(c)
	if perr != nil {
		return perr
	}
	ct, err := h.Pool.Exec(c.Context(),
		`UPDATE notes SET title=$3, body=$4, updated_at=now() WHERE id=$1 AND user_id=$2`,
		c.Params("id"), callerID(c), title, body)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "note not found")
	}
	return c.JSON(fiber.Map{"id": c.Params("id"), "updated": true})
}

// DeleteNote removes one of the caller's notes.
func (h *Handlers) DeleteNote(c *fiber.Ctx) error {
	ct, err := h.Pool.Exec(c.Context(), `DELETE FROM notes WHERE id=$1 AND user_id=$2`, c.Params("id"), callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "note not found")
	}
	return c.JSON(fiber.Map{"id": c.Params("id"), "deleted": true})
}
