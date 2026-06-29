package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
)

// Admin-managed calendar events. Manager/superadmin only (gated at the router).
// They surface on students' calendars via MyCalendar.

// calendarEventReq is the create/update body. audience: all | batch | role.
type calendarEventReq struct {
	Title       string  `json:"title"`
	Description string  `json:"description"`
	Location    string  `json:"location"`
	StartsAt    string  `json:"starts_at"`
	EndsAt      string  `json:"ends_at"`
	Audience    string  `json:"audience"`
	BatchNumber *int    `json:"batch_number"`
	Role        string  `json:"role"`
}

// normalize cleans the audience fields the same way CreateAnnouncement does.
func (r *calendarEventReq) normalize() (batch any, role any) {
	switch r.Audience {
	case "batch":
		if r.BatchNumber != nil {
			batch = *r.BatchNumber
		}
		r.Role = ""
	case "role":
		if r.Role != "" {
			role = r.Role
		}
		r.BatchNumber = nil
	default:
		r.Audience = "all"
		r.BatchNumber = nil
		r.Role = ""
	}
	return
}

// ListCalendarEvents returns events for the admin calendar (recent + upcoming).
func (h *Handlers) ListCalendarEvents(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT id, title, description, COALESCE(location,''), starts_at, ends_at,
		       audience, batch_number, COALESCE(role,'')
		FROM calendar_events
		WHERE starts_at >= now() - interval '60 days'
		ORDER BY starts_at`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, desc, loc, audience, role string
		var startsAt any
		var endsAt any
		var batch *int
		if err := rows.Scan(&id, &title, &desc, &loc, &startsAt, &endsAt, &audience, &batch, &role); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "title": title, "description": desc, "location": loc,
			"starts_at": startsAt, "ends_at": endsAt, "audience": audience, "batch_number": batch, "role": role})
	}
	return c.JSON(fiber.Map{"events": out})
}

// ManageCalendarFeed returns the read-only items that should also appear on the
// admin calendar so it's in sync with what students see: live classes,
// assignment/quiz deadlines and announcements. (Editable events come from
// ListCalendarEvents.)
func (h *Handlers) ManageCalendarFeed(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT 'session' AS kind, cs.title, cs.starts_at AS at, c.title AS course
		FROM class_sessions cs JOIN courses c ON c.id=cs.course_id
		WHERE cs.starts_at >= now() - interval '45 days'
		UNION ALL
		SELECT 'assessment_due', a.title, a.due_at, c.title
		FROM assessments a JOIN courses c ON c.id=a.course_id
		WHERE a.due_at IS NOT NULL AND a.due_at >= now() - interval '45 days' AND a.is_published
		UNION ALL
		SELECT 'announcement', an.title, an.created_at, COALESCE(c.title,'')
		FROM announcements an LEFT JOIN courses c ON c.id=an.course_id
		WHERE an.created_at >= now() - interval '45 days'
		ORDER BY at`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "feed failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var kind, title, course string
		var at any
		if err := rows.Scan(&kind, &title, &at, &course); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"kind": kind, "title": title, "at": at, "course": course})
	}
	return c.JSON(fiber.Map{"items": out})
}

// CreateCalendarEvent adds an event.
func (h *Handlers) CreateCalendarEvent(c *fiber.Ctx) error {
	var req calendarEventReq
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Title) == "" || req.StartsAt == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title and starts_at required")
	}
	batch, role := req.normalize()
	var ends any
	if req.EndsAt != "" {
		ends = req.EndsAt
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO calendar_events (title, description, location, starts_at, ends_at, audience, batch_number, role, created_by)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING id`,
		strings.TrimSpace(req.Title), req.Description, req.Location, req.StartsAt, ends, req.Audience, batch, role, callerID(c)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

// UpdateCalendarEvent edits an event (full replace of the editable fields).
func (h *Handlers) UpdateCalendarEvent(c *fiber.Ctx) error {
	id := c.Params("id")
	var req calendarEventReq
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Title) == "" || req.StartsAt == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title and starts_at required")
	}
	batch, role := req.normalize()
	var ends any
	if req.EndsAt != "" {
		ends = req.EndsAt
	}
	ct, err := h.Pool.Exec(c.Context(),
		`UPDATE calendar_events
		 SET title=$2, description=$3, location=$4, starts_at=$5, ends_at=$6, audience=$7, batch_number=$8, role=$9
		 WHERE id=$1`,
		id, strings.TrimSpace(req.Title), req.Description, req.Location, req.StartsAt, ends, req.Audience, batch, role)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "event not found")
	}
	return c.JSON(fiber.Map{"id": id, "updated": true})
}

// DeleteCalendarEvent removes an event.
func (h *Handlers) DeleteCalendarEvent(c *fiber.Ctx) error {
	id := c.Params("id")
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM calendar_events WHERE id=$1`, id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"id": id, "deleted": true})
}
