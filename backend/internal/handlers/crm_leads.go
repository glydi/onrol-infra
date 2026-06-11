package handlers

import (
	"strconv"
	"strings"

	"github.com/gofiber/fiber/v2"
)

// ---- Leads -----------------------------------------------------------------

var leadStatuses = map[string]bool{
	"New Lead": true, "Registered": true, "Attended": true, "Not Attended": true,
	"Interested": true, "Payment Pending": true, "Converted": true,
}

// ListLeads returns leads with optional status / counsellor / search filters,
// plus a per-status count summary for the pipeline header.
func (h *Handlers) ListLeads(c *fiber.Ctx) error {
	status := c.Query("status")
	counsellor := c.Query("counsellor")
	q := strings.TrimSpace(c.Query("q"))

	sql := `SELECT id, name, phone, email, source, campaign, status, assigned_counsellor,
	               score, notes, do_not_contact, created_at, updated_at
	        FROM leads WHERE 1=1`
	args := []any{}
	if status != "" {
		args = append(args, status)
		sql += " AND status=$" + strconv.Itoa(len(args))
	}
	if counsellor != "" {
		args = append(args, counsellor)
		sql += " AND assigned_counsellor=$" + strconv.Itoa(len(args))
	}
	if q != "" {
		args = append(args, "%"+strings.ToLower(q)+"%")
		n := strconv.Itoa(len(args))
		sql += " AND (lower(name) LIKE $" + n + " OR lower(email) LIKE $" + n + " OR phone LIKE $" + n + ")"
	}
	sql += " ORDER BY updated_at DESC LIMIT 500"

	rows, err := h.Pool.Query(c.Context(), sql, args...)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name, phone, email, source, campaign, st, counsellor2, notes string
		var score int
		var dnc bool
		var created, updated any
		if err := rows.Scan(&id, &name, &phone, &email, &source, &campaign, &st, &counsellor2,
			&score, &notes, &dnc, &created, &updated); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "name": name, "phone": phone, "email": email,
			"source": source, "campaign": campaign, "status": st, "assigned_counsellor": counsellor2,
			"score": score, "notes": notes, "do_not_contact": dnc, "created_at": created, "updated_at": updated})
	}

	// Pipeline counts per status.
	counts := fiber.Map{}
	crows, err := h.Pool.Query(c.Context(), `SELECT status, count(*) FROM leads GROUP BY status`)
	if err == nil {
		defer crows.Close()
		for crows.Next() {
			var st string
			var n int
			if crows.Scan(&st, &n) == nil {
				counts[st] = n
			}
		}
	}
	return c.JSON(fiber.Map{"leads": out, "counts": counts})
}

// CreateLead adds a new lead.
func (h *Handlers) CreateLead(c *fiber.Ctx) error {
	var req struct {
		Name               string `json:"name"`
		Phone              string `json:"phone"`
		Email              string `json:"email"`
		Source             string `json:"source"`
		Campaign           string `json:"campaign"`
		Status             string `json:"status"`
		AssignedCounsellor string `json:"assigned_counsellor"`
		Notes              string `json:"notes"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	if req.Status == "" {
		req.Status = "New Lead"
	}
	if !leadStatuses[req.Status] {
		return fiber.NewError(fiber.StatusBadRequest, "invalid status")
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO leads (name, phone, email, source, campaign, status, assigned_counsellor, notes)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id`,
		req.Name, req.Phone, req.Email, req.Source, req.Campaign, req.Status, req.AssignedCounsellor, req.Notes).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

// UpdateLead edits a lead's editable fields (COALESCE keeps omitted ones).
func (h *Handlers) UpdateLead(c *fiber.Ctx) error {
	id := c.Params("id")
	var req struct {
		Name               *string `json:"name"`
		Phone              *string `json:"phone"`
		Email              *string `json:"email"`
		Source             *string `json:"source"`
		Campaign           *string `json:"campaign"`
		AssignedCounsellor *string `json:"assigned_counsellor"`
		Notes              *string `json:"notes"`
		Score              *int    `json:"score"`
		DoNotContact       *bool   `json:"do_not_contact"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	ct, err := h.Pool.Exec(c.Context(), `
		UPDATE leads SET
		  name = COALESCE($2, name),
		  phone = COALESCE($3, phone),
		  email = COALESCE($4, email),
		  source = COALESCE($5, source),
		  campaign = COALESCE($6, campaign),
		  assigned_counsellor = COALESCE($7, assigned_counsellor),
		  notes = COALESCE($8, notes),
		  score = COALESCE($9, score),
		  do_not_contact = COALESCE($10, do_not_contact),
		  updated_at = now()
		WHERE id=$1`,
		id, req.Name, req.Phone, req.Email, req.Source, req.Campaign, req.AssignedCounsellor,
		req.Notes, req.Score, req.DoNotContact)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "lead not found")
	}
	return c.JSON(fiber.Map{"id": id, "updated": true})
}

// SetLeadStatus moves a lead through the pipeline and appends to its history.
func (h *Handlers) SetLeadStatus(c *fiber.Ctx) error {
	id := c.Params("id")
	var req struct {
		Status string `json:"status"`
	}
	if err := c.BodyParser(&req); err != nil || !leadStatuses[req.Status] {
		return fiber.NewError(fiber.StatusBadRequest, "valid status required")
	}
	ct, err := h.Pool.Exec(c.Context(), `
		UPDATE leads SET
		  status = $2,
		  updated_at = now(),
		  history = history || jsonb_build_object(
		      'at', now(), 'from', status, 'to', $2, 'by', $3::text)
		WHERE id=$1`, id, req.Status, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "status update failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "lead not found")
	}
	return c.JSON(fiber.Map{"id": id, "status": req.Status})
}

// DeleteLead removes a lead (and cascades activities/tasks).
func (h *Handlers) DeleteLead(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM leads WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// ---- Activities ------------------------------------------------------------

// ListLeadActivities returns a lead's activity timeline (newest first).
func (h *Handlers) ListLeadActivities(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT a.id, a.type, a.direction, a.status, a.subject, a.message, a.created_at,
		       COALESCE(u.full_name,'')
		FROM lead_activities a LEFT JOIN users u ON u.id=a.created_by
		WHERE a.lead_id=$1 ORDER BY a.created_at DESC LIMIT 200`, c.Params("id"))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var aid, typ, dir, st, subject, msg, author string
		var at any
		if err := rows.Scan(&aid, &typ, &dir, &st, &subject, &msg, &at, &author); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": aid, "type": typ, "direction": dir, "status": st,
			"subject": subject, "message": msg, "at": at, "author": author})
	}
	return c.JSON(fiber.Map{"activities": out})
}

// AddLeadActivity logs an activity (note/call/email/whatsapp) on a lead.
func (h *Handlers) AddLeadActivity(c *fiber.Ctx) error {
	leadID := c.Params("id")
	var req struct {
		Type      string `json:"type"`
		Direction string `json:"direction"`
		Subject   string `json:"subject"`
		Message   string `json:"message"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	switch req.Type {
	case "note", "call", "email", "whatsapp":
	default:
		return fiber.NewError(fiber.StatusBadRequest, "type must be note, call, email, or whatsapp")
	}
	if req.Direction == "" {
		req.Direction = "internal"
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO lead_activities (lead_id, type, direction, subject, message, created_by)
		 VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
		leadID, req.Type, req.Direction, req.Subject, req.Message, callerID(c)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	_, _ = h.Pool.Exec(c.Context(), `UPDATE leads SET updated_at=now() WHERE id=$1`, leadID)
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

// ---- Tasks -----------------------------------------------------------------

// ListLeadTasks returns a lead's tasks (open first, by due date).
func (h *Handlers) ListLeadTasks(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT id, title, due_at, status, priority, assigned_counsellor
		FROM lead_tasks WHERE lead_id=$1 ORDER BY status, due_at`, c.Params("id"))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, st, pri, counsellor string
		var due any
		if err := rows.Scan(&id, &title, &due, &st, &pri, &counsellor); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "title": title, "due_at": due, "status": st,
			"priority": pri, "assigned_counsellor": counsellor})
	}
	return c.JSON(fiber.Map{"tasks": out})
}

// AddLeadTask schedules a follow-up task on a lead.
func (h *Handlers) AddLeadTask(c *fiber.Ctx) error {
	leadID := c.Params("id")
	var req struct {
		Title              string `json:"title"`
		DueAt              string `json:"due_at"`
		Priority           string `json:"priority"`
		AssignedCounsellor string `json:"assigned_counsellor"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Title) == "" || req.DueAt == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title and due_at required")
	}
	if req.Priority != "high" {
		req.Priority = "normal"
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO lead_tasks (lead_id, title, due_at, priority, assigned_counsellor)
		 VALUES ($1,$2,$3,$4,$5) RETURNING id`,
		leadID, req.Title, req.DueAt, req.Priority, req.AssignedCounsellor).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

// CompleteLeadTask marks a task done (or reopens it).
func (h *Handlers) CompleteLeadTask(c *fiber.Ctx) error {
	var req struct {
		Status string `json:"status"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if req.Status != "open" {
		req.Status = "completed"
	}
	if _, err := h.Pool.Exec(c.Context(),
		`UPDATE lead_tasks SET status=$2, updated_at=now() WHERE id=$1`, c.Params("taskId"), req.Status); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	return c.JSON(fiber.Map{"id": c.Params("taskId"), "status": req.Status})
}
