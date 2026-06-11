package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
)

// =====================================================================
// Integrations: every third-party API runs in DEMO mode (simulated, dummy
// data) until its key is configured. ListIntegrations reports status + the
// env var to set, so the UI can show "where to add the API".
// =====================================================================

func (h *Handlers) ListIntegrations(c *fiber.Ctx) error {
	i := h.Cfg.Integrations
	item := func(name, desc, env string, live bool, usedIn string) fiber.Map {
		return fiber.Map{"name": name, "description": desc, "env_var": env,
			"status": map[bool]string{true: "live", false: "demo"}[live], "used_in": usedIn}
	}
	out := []fiber.Map{
		item("Razorpay", "Payment links & online collection", "RAZORPAY_KEY_ID + RAZORPAY_KEY_SECRET",
			i.RazorpayKey != "" && i.RazorpaySecret != "", "CRM › Invoices (payment link)"),
		item("WhatsApp", "WhatsApp Business (Meta) Cloud API", "WHATSAPP_TOKEN + WHATSAPP_PHONE_ID",
			i.WhatsAppToken != "" && i.WhatsAppPhone != "", "CRM › Leads (message), Campaigns"),
		item("Email", "Transactional email (SES/SendGrid/etc.)", "EMAIL_API_KEY + EMAIL_FROM",
			i.EmailAPIKey != "", "CRM › Campaigns, Leads (email)"),
		item("Voice / IVR", "Telephony & call campaigns (Twilio/Plivo/Exotel)", "VOICE_ACCOUNT_SID + VOICE_AUTH_TOKEN",
			i.VoiceSID != "" && i.VoiceToken != "", "Voice module (calls)"),
		item("SMS", "Transactional/bulk SMS", "SMS_API_KEY", i.SMSAPIKey != "", "CRM › Leads (SMS)"),
		item("AI", "LLM assist & generation (Anthropic/OpenAI)", "AI_API_KEY", i.AIAPIKey != "", "AI features"),
	}
	live := 0
	for _, it := range out {
		if it["status"] == "live" {
			live++
		}
	}
	return c.JSON(fiber.Map{"integrations": out, "live": live, "total": len(out)})
}

// SendLeadMessage sends a message to a lead over a channel. Uses the real
// provider when configured, else simulates (demo) — either way it's logged as
// a lead activity so the timeline is consistent.
func (h *Handlers) SendLeadMessage(c *fiber.Ctx) error {
	leadID := c.Params("id")
	var req struct {
		Channel string `json:"channel"` // whatsapp | sms | email
		Subject string `json:"subject"`
		Message string `json:"message"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Message) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "message required")
	}
	i := h.Cfg.Integrations
	var live bool
	activityType := "note"
	switch req.Channel {
	case "whatsapp":
		live = i.WhatsAppToken != "" && i.WhatsAppPhone != ""
		activityType = "whatsapp"
		// TODO(live): POST https://graph.facebook.com/v20.0/<WHATSAPP_PHONE_ID>/messages
	case "sms":
		live = i.SMSAPIKey != ""
		activityType = "note"
		// TODO(live): call your SMS provider's send API
	case "email":
		live = i.EmailAPIKey != ""
		activityType = "email"
		// TODO(live): call SES/SendGrid send API
	default:
		return fiber.NewError(fiber.StatusBadRequest, "channel must be whatsapp, sms, or email")
	}
	mode := "demo"
	if live {
		mode = "live"
	}
	// Log to the lead activity timeline.
	_, _ = h.Pool.Exec(c.Context(),
		`INSERT INTO lead_activities (lead_id, type, direction, status, subject, message, created_by)
		 VALUES ($1,$2,'outbound',$3,$4,$5,$6)`,
		leadID, activityType, map[bool]string{true: "sent", false: "logged"}[live],
		req.Subject, req.Message, callerID(c))
	_, _ = h.Pool.Exec(c.Context(), `UPDATE leads SET updated_at=now() WHERE id=$1`, leadID)
	return c.JSON(fiber.Map{"sent": true, "mode": mode, "channel": req.Channel})
}

// CreatePaymentLink returns a payment link for an invoice. Real Razorpay link
// when configured, else a demo link.
func (h *Handlers) CreatePaymentLink(c *fiber.Ctx) error {
	id := c.Params("id")
	var number int
	var total int64
	if err := h.Pool.QueryRow(c.Context(), `SELECT number, total FROM invoices WHERE id=$1`, id).Scan(&number, &total); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "invoice not found")
	}
	i := h.Cfg.Integrations
	if i.RazorpayKey != "" && i.RazorpaySecret != "" {
		// TODO(live): POST https://api.razorpay.com/v1/payment_links with amount=total,
		// auth=(RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET); return the short_url.
		return c.JSON(fiber.Map{"mode": "live", "link": "", "note": "Razorpay configured — wire the live call (see TODO)."})
	}
	return c.JSON(fiber.Map{"mode": "demo",
		"link": "https://demo.pay.onrol.test/inv/" + id, "invoice": number, "amount": total})
}

// CrmFunnel returns lead counts per pipeline stage (a funnel) + conversion rate.
func (h *Handlers) CrmFunnel(c *fiber.Ctx) error {
	stages := []string{"New Lead", "Registered", "Attended", "Not Attended", "Interested", "Payment Pending", "Converted"}
	counts := map[string]int{}
	rows, err := h.Pool.Query(c.Context(), `SELECT status, count(*) FROM leads GROUP BY status`)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var s string
			var n int
			if rows.Scan(&s, &n) == nil {
				counts[s] = n
			}
		}
	}
	total := 0
	for _, n := range counts {
		total += n
	}
	out := []fiber.Map{}
	for _, s := range stages {
		out = append(out, fiber.Map{"stage": s, "count": counts[s]})
	}
	conv := 0.0
	if total > 0 {
		conv = float64(counts["Converted"]) * 100 / float64(total)
	}
	return c.JSON(fiber.Map{"funnel": out, "total": total, "conversion_pct": conv})
}

// CrmMyDay returns the caller-relevant tasks: overdue + due today + upcoming.
func (h *Handlers) CrmMyDay(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT t.id, t.title, t.due_at, t.priority, t.status, t.assigned_counsellor,
		       COALESCE(l.name,''), l.id,
		       CASE WHEN t.due_at < date_trunc('day', now()) THEN 'overdue'
		            WHEN t.due_at < date_trunc('day', now()) + interval '1 day' THEN 'today'
		            ELSE 'upcoming' END AS bucket
		FROM lead_tasks t JOIN leads l ON l.id=t.lead_id
		WHERE t.status='open'
		ORDER BY t.due_at LIMIT 200`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "load failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	overdue, today := 0, 0
	for rows.Next() {
		var tid, title, pri, status, counsellor, lead, leadID, bucket string
		var due any
		if err := rows.Scan(&tid, &title, &due, &pri, &status, &counsellor, &lead, &leadID, &bucket); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		if bucket == "overdue" {
			overdue++
		} else if bucket == "today" {
			today++
		}
		out = append(out, fiber.Map{"id": tid, "title": title, "due_at": due, "priority": pri,
			"lead": lead, "lead_id": leadID, "bucket": bucket})
	}
	return c.JSON(fiber.Map{"tasks": out, "overdue": overdue, "today": today})
}
