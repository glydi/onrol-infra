package handlers

import (
	"encoding/json"
	"strings"

	"github.com/gofiber/fiber/v2"
)

// ---- Invoices --------------------------------------------------------------

func (h *Handlers) ListInvoices(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT i.id, i.number, i.status, i.currency, i.total, i.notes,
		       COALESCE(i.due_date::text,''), i.created_at,
		       COALESCE(l.name,''), COALESCE(a.name,''),
		       COALESCE((SELECT sum(p.amount) FROM payments p WHERE p.invoice_id=i.id AND p.status='captured'),0)
		FROM invoices i
		LEFT JOIN leads l ON l.id=i.lead_id
		LEFT JOIN accounts a ON a.id=i.account_id
		ORDER BY i.created_at DESC LIMIT 500`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, status, currency, notes, due, lead, account string
		var number int
		var total, paid int64
		var created any
		if err := rows.Scan(&id, &number, &status, &currency, &total, &notes, &due, &created, &lead, &account, &paid); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "number": number, "status": status, "currency": currency,
			"total": total, "paid": paid, "notes": notes, "due_date": due, "created_at": created,
			"lead": lead, "account": account})
	}
	return c.JSON(fiber.Map{"invoices": out})
}

func (h *Handlers) CreateInvoice(c *fiber.Ctx) error {
	var req struct {
		LeadID    string  `json:"lead_id"`
		AccountID string  `json:"account_id"`
		Total     int64   `json:"total"`
		TaxRate   float64 `json:"tax_rate"`
		DueDate   string  `json:"due_date"`
		Notes     string  `json:"notes"`
		LineItems any     `json:"line_items"`
	}
	if err := c.BodyParser(&req); err != nil || req.Total <= 0 {
		return fiber.NewError(fiber.StatusBadRequest, "total (in paise) required")
	}
	items, _ := json.Marshal(req.LineItems)
	if len(items) == 0 || string(items) == "null" {
		items = []byte("[]")
	}
	// Treat the supplied total as the grand total; derive subtotal/tax for display.
	subtotal := req.Total
	var tax int64
	if req.TaxRate > 0 {
		subtotal = int64(float64(req.Total) / (1 + req.TaxRate/100))
		tax = req.Total - subtotal
	}
	var id string
	var number int
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO invoices (lead_id, account_id, total, subtotal, tax_rate, tax_amount, due_date, notes, line_items, created_by)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING id, number`,
		nullUUID(req.LeadID), nullUUID(req.AccountID), req.Total, subtotal, req.TaxRate, tax,
		nullStr(req.DueDate), req.Notes, string(items), callerID(c)).Scan(&id, &number); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "number": number})
}

// SetInvoiceStatus transitions an invoice (draft → sent → paid / cancelled),
// stamping sent_at / paid_at as appropriate.
func (h *Handlers) SetInvoiceStatus(c *fiber.Ctx) error {
	var req struct {
		Status string `json:"status"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	switch req.Status {
	case "draft", "sent", "paid", "cancelled":
	default:
		return fiber.NewError(fiber.StatusBadRequest, "invalid status")
	}
	ct, err := h.Pool.Exec(c.Context(), `
		UPDATE invoices SET status=$2,
		  sent_at = CASE WHEN $2='sent' AND sent_at IS NULL THEN now() ELSE sent_at END,
		  paid_at = CASE WHEN $2='paid' THEN now() ELSE paid_at END,
		  updated_at = now()
		WHERE id=$1`, c.Params("id"), req.Status)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "invoice not found")
	}
	return c.JSON(fiber.Map{"id": c.Params("id"), "status": req.Status})
}

func (h *Handlers) DeleteInvoice(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM invoices WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// ---- Payments --------------------------------------------------------------

func (h *Handlers) ListInvoicePayments(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, amount, currency, status, provider, COALESCE(provider_payment_id,''), created_at
		 FROM payments WHERE invoice_id=$1 ORDER BY created_at DESC`, c.Params("id"))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, currency, status, provider, ref string
		var amount int64
		var at any
		if err := rows.Scan(&id, &amount, &currency, &status, &provider, &ref, &at); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "amount": amount, "currency": currency, "status": status,
			"provider": provider, "provider_payment_id": ref, "created_at": at})
	}
	return c.JSON(fiber.Map{"payments": out})
}

// RecordPayment logs a (manual) payment against an invoice and marks the
// invoice paid once captured payments cover its total.
func (h *Handlers) RecordPayment(c *fiber.Ctx) error {
	invoiceID := c.Params("id")
	var lead *string
	var total int64
	if err := h.Pool.QueryRow(c.Context(), `SELECT lead_id, total FROM invoices WHERE id=$1`, invoiceID).Scan(&lead, &total); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "invoice not found")
	}
	var req struct {
		Amount    int64  `json:"amount"`
		Provider  string `json:"provider"`
		Reference string `json:"provider_payment_id"`
	}
	if err := c.BodyParser(&req); err != nil || req.Amount <= 0 {
		return fiber.NewError(fiber.StatusBadRequest, "amount (in paise) required")
	}
	if req.Provider != "razorpay" {
		req.Provider = "manual"
	}
	if _, err := h.Pool.Exec(c.Context(),
		`INSERT INTO payments (lead_id, invoice_id, amount, provider, provider_payment_id)
		 VALUES ($1,$2,$3,$4,$5)`,
		lead, invoiceID, req.Amount, req.Provider, nullStr(req.Reference)); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "record failed")
	}
	// Auto-mark paid if covered.
	var paid int64
	_ = h.Pool.QueryRow(c.Context(),
		`SELECT COALESCE(sum(amount),0) FROM payments WHERE invoice_id=$1 AND status='captured'`, invoiceID).Scan(&paid)
	if paid >= total {
		_, _ = h.Pool.Exec(c.Context(), `UPDATE invoices SET status='paid', paid_at=now(), updated_at=now() WHERE id=$1`, invoiceID)
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"recorded": true, "paid_total": paid})
}

// ---- Forms -----------------------------------------------------------------

func (h *Handlers) ListForms(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT f.id, f.slug, f.name, f.enabled, f.fields, f.created_at,
		       (SELECT count(*) FROM form_submissions s WHERE s.form_id=f.id) AS submissions
		FROM forms f ORDER BY f.created_at DESC LIMIT 200`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, slug, name string
		var enabled bool
		var fields []byte
		var created any
		var subs int
		if err := rows.Scan(&id, &slug, &name, &enabled, &fields, &created, &subs); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "slug": slug, "name": name, "enabled": enabled,
			"fields": rawJSON(fields), "submissions": subs, "created_at": created})
	}
	return c.JSON(fiber.Map{"forms": out})
}

func (h *Handlers) CreateForm(c *fiber.Ctx) error {
	var req struct {
		Name   string   `json:"name"`
		Slug   string   `json:"slug"`
		Fields []string `json:"fields"` // simple field labels
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	slug := strings.ToLower(strings.TrimSpace(req.Slug))
	if slug == "" {
		slug = strings.ReplaceAll(strings.ToLower(strings.TrimSpace(req.Name)), " ", "-")
	}
	if len(req.Fields) == 0 {
		req.Fields = []string{"Name", "Email", "Phone"}
	}
	fields, _ := json.Marshal(req.Fields)
	var id string
	err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO forms (slug, name, fields) VALUES ($1,$2,$3) RETURNING id`,
		slug, req.Name, string(fields)).Scan(&id)
	if err != nil {
		if strings.Contains(err.Error(), "forms_slug_key") {
			return fiber.NewError(fiber.StatusConflict, "slug already in use")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "slug": slug})
}

func (h *Handlers) DeleteForm(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM forms WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

func (h *Handlers) ListFormSubmissions(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, data, created_at FROM form_submissions WHERE form_id=$1 ORDER BY created_at DESC LIMIT 500`, c.Params("id"))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id string
		var data []byte
		var at any
		if err := rows.Scan(&id, &data, &at); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "data": rawJSON(data), "created_at": at})
	}
	return c.JSON(fiber.Map{"submissions": out})
}

// SubmitForm is the PUBLIC endpoint a hosted form posts to. It records the
// submission and creates a lead from it (best-effort name/email/phone mapping).
func (h *Handlers) SubmitForm(c *fiber.Ctx) error {
	slug := c.Params("slug")
	var formID string
	var enabled bool
	if err := h.Pool.QueryRow(c.Context(), `SELECT id, enabled FROM forms WHERE slug=$1`, slug).Scan(&formID, &enabled); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "form not found")
	}
	if !enabled {
		return fiber.NewError(fiber.StatusForbidden, "form is closed")
	}
	var data map[string]any
	if err := c.BodyParser(&data); err != nil || len(data) == 0 {
		return fiber.NewError(fiber.StatusBadRequest, "no data")
	}
	raw, _ := json.Marshal(data)
	// Map common fields to a new lead.
	name := firstStr(data, "name", "Name", "full_name", "fullName")
	email := firstStr(data, "email", "Email")
	phone := firstStr(data, "phone", "Phone", "mobile")
	var leadID *string
	if name != "" || email != "" || phone != "" {
		var id string
		if h.Pool.QueryRow(c.Context(),
			`INSERT INTO leads (name, email, phone, source) VALUES ($1,$2,$3,$4) RETURNING id`,
			fallback(name, "Form lead"), email, phone, "form:"+slug).Scan(&id) == nil {
			leadID = &id
		}
	}
	_, _ = h.Pool.Exec(c.Context(),
		`INSERT INTO form_submissions (form_id, lead_id, data) VALUES ($1,$2,$3)`, formID, leadID, string(raw))
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"ok": true})
}

func firstStr(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			if s, ok := v.(string); ok && strings.TrimSpace(s) != "" {
				return strings.TrimSpace(s)
			}
		}
	}
	return ""
}

func fallback(s, def string) string {
	if strings.TrimSpace(s) == "" {
		return def
	}
	return s
}
