package handlers

import (
	"encoding/json"
	"strings"

	"github.com/gofiber/fiber/v2"
)

// ---- Analytics -------------------------------------------------------------

// CrmAnalytics returns headline CRM KPIs computed from the existing data.
func (h *Handlers) CrmAnalytics(c *fiber.Ctx) error {
	out := fiber.Map{}
	one := func(q string) int64 {
		var n int64
		_ = h.Pool.QueryRow(c.Context(), q).Scan(&n)
		return n
	}
	out["leads_total"] = one(`SELECT count(*) FROM leads`)
	out["leads_converted"] = one(`SELECT count(*) FROM leads WHERE status='Converted'`)
	out["deals_open"] = one(`SELECT count(*) FROM deals WHERE status='open'`)
	out["deals_open_value"] = one(`SELECT COALESCE(sum(value_paise),0) FROM deals WHERE status='open'`)
	out["deals_won_value"] = one(`SELECT COALESCE(sum(value_paise),0) FROM deals WHERE status='won'`)
	out["revenue_collected"] = one(`SELECT COALESCE(sum(amount),0) FROM payments WHERE status='captured'`)
	out["invoices_outstanding"] = one(`SELECT COALESCE(sum(total),0) FROM invoices WHERE status IN ('draft','sent')`)
	out["accounts_total"] = one(`SELECT count(*) FROM accounts`)
	out["open_tickets"] = one(`SELECT count(*) FROM tickets WHERE status<>'closed'`)

	// Leads per status.
	byStatus := fiber.Map{}
	rows, err := h.Pool.Query(c.Context(), `SELECT status, count(*) FROM leads GROUP BY status`)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var s string
			var n int64
			if rows.Scan(&s, &n) == nil {
				byStatus[s] = n
			}
		}
	}
	out["leads_by_status"] = byStatus
	return c.JSON(out)
}

// ---- Automation rules ------------------------------------------------------

func (h *Handlers) ListAutomationRules(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, name, trigger_status, action, action_value, delay_hours, enabled, created_at
		 FROM automation_rules ORDER BY created_at DESC`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name, trig, action, val string
		var delay int
		var enabled bool
		var created any
		if err := rows.Scan(&id, &name, &trig, &action, &val, &delay, &enabled, &created); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "name": name, "trigger_status": trig, "action": action,
			"action_value": val, "delay_hours": delay, "enabled": enabled, "created_at": created})
	}
	return c.JSON(fiber.Map{"rules": out})
}

func (h *Handlers) CreateAutomationRule(c *fiber.Ctx) error {
	var req struct {
		Name          string `json:"name"`
		TriggerStatus string `json:"trigger_status"`
		Action        string `json:"action"`
		ActionValue   string `json:"action_value"`
		DelayHours    int    `json:"delay_hours"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" || req.TriggerStatus == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name and trigger_status required")
	}
	if req.Action != "log_note" {
		req.Action = "create_task"
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO automation_rules (name, trigger_status, action, action_value, delay_hours)
		 VALUES ($1,$2,$3,$4,$5) RETURNING id`,
		req.Name, req.TriggerStatus, req.Action, req.ActionValue, req.DelayHours).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

func (h *Handlers) ToggleAutomationRule(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(),
		`UPDATE automation_rules SET enabled = NOT enabled, updated_at=now() WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	return c.JSON(fiber.Map{"ok": true})
}

func (h *Handlers) DeleteAutomationRule(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM automation_rules WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// ---- Surveys ---------------------------------------------------------------

func (h *Handlers) ListSurveys(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT s.id, s.slug, s.title, s.enabled, s.questions, s.created_at,
		       (SELECT count(*) FROM survey_responses r WHERE r.survey_id=s.id)
		FROM surveys s ORDER BY s.created_at DESC`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, slug, title string
		var enabled bool
		var questions []byte
		var created any
		var responses int
		if err := rows.Scan(&id, &slug, &title, &enabled, &questions, &created, &responses); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "slug": slug, "title": title, "enabled": enabled,
			"questions": rawJSON(questions), "responses": responses, "created_at": created})
	}
	return c.JSON(fiber.Map{"surveys": out})
}

func (h *Handlers) CreateSurvey(c *fiber.Ctx) error {
	var req struct {
		Title     string   `json:"title"`
		Slug      string   `json:"slug"`
		Questions []string `json:"questions"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Title) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title required")
	}
	slug := strings.ToLower(strings.TrimSpace(req.Slug))
	if slug == "" {
		slug = strings.ReplaceAll(strings.ToLower(strings.TrimSpace(req.Title)), " ", "-")
	}
	q, _ := json.Marshal(req.Questions)
	var id string
	err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO surveys (slug, title, questions) VALUES ($1,$2,$3) RETURNING id`, slug, req.Title, string(q)).Scan(&id)
	if err != nil {
		if strings.Contains(err.Error(), "surveys_slug_key") {
			return fiber.NewError(fiber.StatusConflict, "slug already in use")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "slug": slug})
}

func (h *Handlers) DeleteSurvey(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM surveys WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

func (h *Handlers) ListSurveyResponses(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, answers, created_at FROM survey_responses WHERE survey_id=$1 ORDER BY created_at DESC LIMIT 500`, c.Params("id"))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id string
		var answers []byte
		var at any
		if err := rows.Scan(&id, &answers, &at); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "answers": rawJSON(answers), "created_at": at})
	}
	return c.JSON(fiber.Map{"responses": out})
}

// SubmitSurvey is the PUBLIC endpoint a hosted survey posts to.
func (h *Handlers) SubmitSurvey(c *fiber.Ctx) error {
	var surveyID string
	var enabled bool
	if err := h.Pool.QueryRow(c.Context(), `SELECT id, enabled FROM surveys WHERE slug=$1`, c.Params("slug")).Scan(&surveyID, &enabled); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "survey not found")
	}
	if !enabled {
		return fiber.NewError(fiber.StatusForbidden, "survey is closed")
	}
	var answers map[string]any
	if err := c.BodyParser(&answers); err != nil || len(answers) == 0 {
		return fiber.NewError(fiber.StatusBadRequest, "no answers")
	}
	raw, _ := json.Marshal(answers)
	_, _ = h.Pool.Exec(c.Context(), `INSERT INTO survey_responses (survey_id, answers) VALUES ($1,$2)`, surveyID, string(raw))
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"ok": true})
}

// ---- Reviews ---------------------------------------------------------------

func (h *Handlers) ListReviews(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, author, rating, body, status, created_at FROM reviews ORDER BY created_at DESC LIMIT 500`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, author, body, status string
		var rating int
		var at any
		if err := rows.Scan(&id, &author, &rating, &body, &status, &at); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "author": author, "rating": rating, "body": body, "status": status, "created_at": at})
	}
	return c.JSON(fiber.Map{"reviews": out})
}

func (h *Handlers) CreateReview(c *fiber.Ctx) error {
	var req struct {
		Author string `json:"author"`
		Rating int    `json:"rating"`
		Body   string `json:"body"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if req.Rating < 1 || req.Rating > 5 {
		req.Rating = 5
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO reviews (author, rating, body) VALUES ($1,$2,$3) RETURNING id`, req.Author, req.Rating, req.Body).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

func (h *Handlers) SetReviewStatus(c *fiber.Ctx) error {
	var req struct {
		Status string `json:"status"`
	}
	if err := c.BodyParser(&req); err != nil || (req.Status != "pending" && req.Status != "approved" && req.Status != "hidden") {
		return fiber.NewError(fiber.StatusBadRequest, "valid status required")
	}
	if _, err := h.Pool.Exec(c.Context(), `UPDATE reviews SET status=$2 WHERE id=$1`, c.Params("id"), req.Status); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	return c.JSON(fiber.Map{"id": c.Params("id"), "status": req.Status})
}

func (h *Handlers) DeleteReview(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM reviews WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// ---- Calendar events -------------------------------------------------------

func (h *Handlers) ListEvents(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, title, starts_at, kind, notes FROM crm_events ORDER BY starts_at DESC LIMIT 500`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, kind, notes string
		var at any
		if err := rows.Scan(&id, &title, &at, &kind, &notes); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "title": title, "starts_at": at, "kind": kind, "notes": notes})
	}
	return c.JSON(fiber.Map{"events": out})
}

func (h *Handlers) CreateEvent(c *fiber.Ctx) error {
	var req struct {
		Title    string `json:"title"`
		StartsAt string `json:"starts_at"`
		Kind     string `json:"kind"`
		Notes    string `json:"notes"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Title) == "" || req.StartsAt == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title and starts_at required")
	}
	if req.Kind == "" {
		req.Kind = "event"
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO crm_events (title, starts_at, kind, notes, created_by) VALUES ($1,$2,$3,$4,$5) RETURNING id`,
		req.Title, req.StartsAt, req.Kind, req.Notes, callerID(c)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

func (h *Handlers) DeleteEvent(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM crm_events WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// ---- Newsfeed --------------------------------------------------------------

func (h *Handlers) ListFeed(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT f.id, f.body, f.created_at, COALESCE(u.full_name,'')
		FROM feed_posts f LEFT JOIN users u ON u.id=f.author_id
		ORDER BY f.created_at DESC LIMIT 200`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, body, author string
		var at any
		if err := rows.Scan(&id, &body, &at, &author); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "body": body, "at": at, "author": author})
	}
	return c.JSON(fiber.Map{"posts": out})
}

func (h *Handlers) CreateFeedPost(c *fiber.Ctx) error {
	var req struct {
		Body string `json:"body"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Body) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "body required")
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO feed_posts (author_id, body) VALUES ($1,$2) RETURNING id`, callerID(c), req.Body).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

func (h *Handlers) DeleteFeedPost(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM feed_posts WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// ---- Support tickets -------------------------------------------------------

func (h *Handlers) ListTickets(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT t.id, t.subject, t.body, t.status, t.priority, t.created_at, COALESCE(l.name,'')
		FROM tickets t LEFT JOIN leads l ON l.id=t.lead_id
		ORDER BY (t.status='closed'), t.created_at DESC LIMIT 500`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, subject, body, status, priority, lead string
		var at any
		if err := rows.Scan(&id, &subject, &body, &status, &priority, &at, &lead); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "subject": subject, "body": body, "status": status,
			"priority": priority, "created_at": at, "lead": lead})
	}
	return c.JSON(fiber.Map{"tickets": out})
}

func (h *Handlers) CreateTicket(c *fiber.Ctx) error {
	var req struct {
		Subject  string `json:"subject"`
		Body     string `json:"body"`
		Priority string `json:"priority"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Subject) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "subject required")
	}
	if req.Priority != "low" && req.Priority != "high" {
		req.Priority = "normal"
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO tickets (subject, body, priority, created_by) VALUES ($1,$2,$3,$4) RETURNING id`,
		req.Subject, req.Body, req.Priority, callerID(c)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

func (h *Handlers) SetTicketStatus(c *fiber.Ctx) error {
	var req struct {
		Status string `json:"status"`
	}
	if err := c.BodyParser(&req); err != nil || (req.Status != "open" && req.Status != "pending" && req.Status != "closed") {
		return fiber.NewError(fiber.StatusBadRequest, "valid status required")
	}
	if _, err := h.Pool.Exec(c.Context(),
		`UPDATE tickets SET status=$2, updated_at=now() WHERE id=$1`, c.Params("id"), req.Status); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	return c.JSON(fiber.Map{"id": c.Params("id"), "status": req.Status})
}

// ---- Webhooks --------------------------------------------------------------

func (h *Handlers) ListWebhooks(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, url, event, enabled, created_at FROM webhooks ORDER BY created_at DESC`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, url, event string
		var enabled bool
		var at any
		if err := rows.Scan(&id, &url, &event, &enabled, &at); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "url": url, "event": event, "enabled": enabled, "created_at": at})
	}
	return c.JSON(fiber.Map{"webhooks": out})
}

func (h *Handlers) CreateWebhook(c *fiber.Ctx) error {
	var req struct {
		URL   string `json:"url"`
		Event string `json:"event"`
	}
	if err := c.BodyParser(&req); err != nil || !strings.HasPrefix(req.URL, "http") {
		return fiber.NewError(fiber.StatusBadRequest, "valid url required")
	}
	if req.Event == "" {
		req.Event = "lead.created"
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO webhooks (url, event) VALUES ($1,$2) RETURNING id`, req.URL, req.Event).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

func (h *Handlers) DeleteWebhook(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM webhooks WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// ---- Affiliates + commissions ----------------------------------------------

func (h *Handlers) ListAffiliates(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT a.id, a.name, a.email, a.code, a.commission_rate, a.status,
		       COALESCE((SELECT sum(amount) FROM commissions cm WHERE cm.affiliate_id=a.id AND cm.status='pending'),0),
		       COALESCE((SELECT sum(amount) FROM commissions cm WHERE cm.affiliate_id=a.id AND cm.status='paid'),0)
		FROM affiliates a ORDER BY a.created_at DESC`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name, email, code, status string
		var rate float64
		var pending, paid int64
		if err := rows.Scan(&id, &name, &email, &code, &rate, &status, &pending, &paid); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "name": name, "email": email, "code": code,
			"commission_rate": rate, "status": status, "pending": pending, "paid": paid})
	}
	return c.JSON(fiber.Map{"affiliates": out})
}

func (h *Handlers) CreateAffiliate(c *fiber.Ctx) error {
	var req struct {
		Name           string  `json:"name"`
		Email          string  `json:"email"`
		Code           string  `json:"code"`
		CommissionRate float64 `json:"commission_rate"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	code := strings.ToUpper(strings.TrimSpace(req.Code))
	if code == "" {
		code = strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(req.Name), " ", ""))
	}
	var id string
	err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO affiliates (name, email, code, commission_rate) VALUES ($1,$2,$3,$4) RETURNING id`,
		req.Name, req.Email, code, req.CommissionRate).Scan(&id)
	if err != nil {
		if strings.Contains(err.Error(), "affiliates_code_key") {
			return fiber.NewError(fiber.StatusConflict, "code already in use")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "code": code})
}

func (h *Handlers) DeleteAffiliate(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM affiliates WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

func (h *Handlers) ListCommissions(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, amount, status, note, created_at FROM commissions WHERE affiliate_id=$1 ORDER BY created_at DESC`, c.Params("id"))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, status, note string
		var amount int64
		var at any
		if err := rows.Scan(&id, &amount, &status, &note, &at); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "amount": amount, "status": status, "note": note, "created_at": at})
	}
	return c.JSON(fiber.Map{"commissions": out})
}

func (h *Handlers) AddCommission(c *fiber.Ctx) error {
	affiliateID := c.Params("id")
	var req struct {
		Amount int64  `json:"amount"`
		Note   string `json:"note"`
	}
	if err := c.BodyParser(&req); err != nil || req.Amount <= 0 {
		return fiber.NewError(fiber.StatusBadRequest, "amount (in paise) required")
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO commissions (affiliate_id, amount, note) VALUES ($1,$2,$3) RETURNING id`,
		affiliateID, req.Amount, req.Note).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

func (h *Handlers) PayCommission(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `UPDATE commissions SET status='paid' WHERE id=$1`, c.Params("cid")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	return c.JSON(fiber.Map{"ok": true})
}
