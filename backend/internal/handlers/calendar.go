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
	BatchNumber *string `json:"batch_number"`
	Role        string  `json:"role"`
	EventType   string  `json:"event_type"` // batch_start | live | exam | holiday | … (app-defined)
}

// eventType returns the type key, defaulting to "general".
func (r *calendarEventReq) eventType() string {
	if strings.TrimSpace(r.EventType) == "" {
		return "general"
	}
	return r.EventType
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
		       audience, batch_number, COALESCE(role,''), COALESCE(event_type,'general')
		FROM calendar_events
		WHERE starts_at >= now() - interval '60 days'
		ORDER BY starts_at`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, desc, loc, audience, role, etype string
		var startsAt any
		var endsAt any
		var batch *string
		if err := rows.Scan(&id, &title, &desc, &loc, &startsAt, &endsAt, &audience, &batch, &role, &etype); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "title": title, "description": desc, "location": loc,
			"starts_at": startsAt, "ends_at": endsAt, "audience": audience, "batch_number": batch, "role": role, "event_type": etype})
	}
	return c.JSON(fiber.Map{"events": out})
}

// ManageCalendarFeed returns the read-only items that should also appear on the
// admin calendar so it's in sync with what students see: live classes,
// assignment/quiz deadlines and announcements. (Editable events come from
// ListCalendarEvents.)
func (h *Handlers) ManageCalendarFeed(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT 'session' AS kind, cs.id::text AS id, cs.title, cs.starts_at AS at, c.title AS course,
		       (now() > COALESCE(cs.ends_at,
		           CASE WHEN cs.media_asset_id IS NOT NULL AND ma.duration_seconds > 0
		                THEN cs.starts_at + make_interval(secs => ma.duration_seconds)
		                ELSE cs.starts_at + interval '2 hours' END)) AS ended
		FROM class_sessions cs JOIN courses c ON c.id=cs.course_id
		LEFT JOIN media_assets ma ON ma.id=cs.media_asset_id
		WHERE cs.starts_at >= now() - interval '180 days'
		UNION ALL
		SELECT 'assessment_due', a.id::text, a.title, a.due_at, c.title, false
		FROM assessments a JOIN courses c ON c.id=a.course_id
		WHERE a.due_at IS NOT NULL AND a.due_at >= now() - interval '45 days' AND a.is_published
		UNION ALL
		SELECT 'announcement', an.id::text, an.title, an.created_at, COALESCE(c.title,''), false
		FROM announcements an LEFT JOIN courses c ON c.id=an.course_id
		WHERE an.created_at >= now() - interval '45 days'
		ORDER BY at`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "feed failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var kind, id, title, course string
		var at any
		var ended bool
		if err := rows.Scan(&kind, &id, &title, &at, &course, &ended); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"kind": kind, "id": id, "title": title, "at": at, "course": course, "ended": ended})
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
		`INSERT INTO calendar_events (title, description, location, starts_at, ends_at, audience, batch_number, role, event_type, created_by)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING id`,
		strings.TrimSpace(req.Title), req.Description, req.Location, req.StartsAt, ends, req.Audience, batch, role, req.eventType(), callerID(c)).Scan(&id); err != nil {
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
		 SET title=$2, description=$3, location=$4, starts_at=$5, ends_at=$6, audience=$7, batch_number=$8, role=$9, event_type=$10
		 WHERE id=$1`,
		id, strings.TrimSpace(req.Title), req.Description, req.Location, req.StartsAt, ends, req.Audience, batch, role, req.eventType())
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

// ClearCalendarHistory bulk-deletes past admin-created calendar events (those
// whose end, else start, time has passed). It ONLY removes calendar events —
// live classes and other feed items are left untouched. Upcoming events are
// kept. Manager/admin only (route-gated).
func (h *Handlers) ClearCalendarHistory(c *fiber.Ctx) error {
	evTag, err := h.Pool.Exec(c.Context(),
		`DELETE FROM calendar_events WHERE COALESCE(ends_at, starts_at) < now()`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "clear failed")
	}
	return c.JSON(fiber.Map{"events_deleted": evTag.RowsAffected()})
}
