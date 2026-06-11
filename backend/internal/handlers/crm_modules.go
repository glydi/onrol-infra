package handlers

import (
	"encoding/json"
	"strings"

	"github.com/gofiber/fiber/v2"
)

// ---- Accounts (companies) --------------------------------------------------

func (h *Handlers) ListAccounts(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT a.id, a.name, COALESCE(a.domain,''), COALESCE(a.industry,''), COALESCE(a.size_band,''),
		       a.arr_paise, a.notes, a.health, a.updated_at,
		       (SELECT count(*) FROM deals d WHERE d.account_id=a.id) AS deal_count
		FROM accounts a ORDER BY a.updated_at DESC LIMIT 500`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name, domain, industry, size, notes, health string
		var arr int64
		var updated any
		var deals int
		if err := rows.Scan(&id, &name, &domain, &industry, &size, &arr, &notes, &health, &updated, &deals); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "name": name, "domain": domain, "industry": industry,
			"size_band": size, "arr_paise": arr, "notes": notes, "health": health, "updated_at": updated, "deal_count": deals})
	}
	return c.JSON(fiber.Map{"accounts": out})
}

func (h *Handlers) CreateAccount(c *fiber.Ctx) error {
	var req struct {
		Name     string `json:"name"`
		Domain   string `json:"domain"`
		Industry string `json:"industry"`
		SizeBand string `json:"size_band"`
		ArrPaise int64  `json:"arr_paise"`
		Health   string `json:"health"`
		Notes    string `json:"notes"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	if req.Health == "" {
		req.Health = "unknown"
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO accounts (name, domain, industry, size_band, arr_paise, health, notes, owner_user_id)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id`,
		req.Name, nullStr(req.Domain), nullStr(req.Industry), nullStr(req.SizeBand), req.ArrPaise, req.Health, req.Notes, callerID(c)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

func (h *Handlers) UpdateAccount(c *fiber.Ctx) error {
	var req struct {
		Name     *string `json:"name"`
		Domain   *string `json:"domain"`
		Industry *string `json:"industry"`
		SizeBand *string `json:"size_band"`
		ArrPaise *int64  `json:"arr_paise"`
		Health   *string `json:"health"`
		Notes    *string `json:"notes"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	ct, err := h.Pool.Exec(c.Context(), `
		UPDATE accounts SET
		  name=COALESCE($2,name), domain=COALESCE($3,domain), industry=COALESCE($4,industry),
		  size_band=COALESCE($5,size_band), arr_paise=COALESCE($6,arr_paise),
		  health=COALESCE($7,health), notes=COALESCE($8,notes), updated_at=now()
		WHERE id=$1`, c.Params("id"), req.Name, req.Domain, req.Industry, req.SizeBand, req.ArrPaise, req.Health, req.Notes)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "account not found")
	}
	return c.JSON(fiber.Map{"updated": true})
}

func (h *Handlers) DeleteAccount(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM accounts WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// ---- Deals -----------------------------------------------------------------

// ListDeals returns deals (optionally by account), with pipeline stages and a
// per-stage value summary for the board header.
func (h *Handlers) ListDeals(c *fiber.Ctx) error {
	accountID := c.Query("account_id")
	sql := `SELECT d.id, d.title, d.value_paise, d.currency, d.stage, d.probability, d.status,
	               COALESCE(d.expected_close_date::text,''), d.notes, d.account_id, d.lead_id,
	               COALESCE(a.name,''), COALESCE(l.name,'')
	        FROM deals d
	        LEFT JOIN accounts a ON a.id=d.account_id
	        LEFT JOIN leads l ON l.id=d.lead_id
	        WHERE 1=1`
	args := []any{}
	if accountID != "" {
		args = append(args, accountID)
		sql += " AND d.account_id=$1"
	}
	sql += " ORDER BY d.updated_at DESC LIMIT 500"
	rows, err := h.Pool.Query(c.Context(), sql, args...)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, currency, stage, status, close, notes, accID, leadID, accName, leadName string
		var value int64
		var prob int
		if err := rows.Scan(&id, &title, &value, &currency, &stage, &prob, &status, &close, &notes, &accID, &leadID, &accName, &leadName); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "title": title, "value_paise": value, "currency": currency,
			"stage": stage, "probability": prob, "status": status, "expected_close_date": close, "notes": notes,
			"account_id": accID, "lead_id": leadID, "account": accName, "lead": leadName})
	}

	// Default pipeline stages for the board.
	var stagesJSON []byte
	_ = h.Pool.QueryRow(c.Context(), `SELECT statuses FROM pipelines WHERE is_default=true LIMIT 1`).Scan(&stagesJSON)
	return c.JSON(fiber.Map{"deals": out, "stages": rawJSON(stagesJSON)})
}

func (h *Handlers) CreateDeal(c *fiber.Ctx) error {
	var req struct {
		Title      string `json:"title"`
		ValuePaise int64  `json:"value_paise"`
		Stage      string `json:"stage"`
		AccountID  string `json:"account_id"`
		LeadID     string `json:"lead_id"`
		Notes      string `json:"notes"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Title) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title required")
	}
	if req.Stage == "" {
		req.Stage = "Qualification"
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO deals (title, value_paise, stage, account_id, lead_id, notes, owner_user_id)
		 VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
		req.Title, req.ValuePaise, req.Stage, nullUUID(req.AccountID), nullUUID(req.LeadID), req.Notes, callerID(c)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

func (h *Handlers) UpdateDeal(c *fiber.Ctx) error {
	var req struct {
		Title      *string `json:"title"`
		ValuePaise *int64  `json:"value_paise"`
		Stage      *string `json:"stage"`
		Status     *string `json:"status"`
		Notes      *string `json:"notes"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if req.Status != nil && *req.Status != "open" && *req.Status != "won" && *req.Status != "lost" {
		return fiber.NewError(fiber.StatusBadRequest, "status must be open, won, or lost")
	}
	ct, err := h.Pool.Exec(c.Context(), `
		UPDATE deals SET
		  title=COALESCE($2,title), value_paise=COALESCE($3,value_paise),
		  stage=COALESCE($4,stage), status=COALESCE($5,status), notes=COALESCE($6,notes), updated_at=now()
		WHERE id=$1`, c.Params("id"), req.Title, req.ValuePaise, req.Stage, req.Status, req.Notes)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "deal not found")
	}
	return c.JSON(fiber.Map{"updated": true})
}

func (h *Handlers) DeleteDeal(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM deals WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// ---- Broadcasts (campaigns) ------------------------------------------------

func (h *Handlers) ListBroadcasts(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT id, name, channel, subject, body, status, COALESCE(scheduled_at::text,''),
		       total_targets, total_sent, created_at
		FROM broadcasts ORDER BY created_at DESC LIMIT 200`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name, channel, subject, body, status, sched string
		var targets, sent int
		var created any
		if err := rows.Scan(&id, &name, &channel, &subject, &body, &status, &sched, &targets, &sent, &created); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "name": name, "channel": channel, "subject": subject,
			"body": body, "status": status, "scheduled_at": sched, "total_targets": targets,
			"total_sent": sent, "created_at": created})
	}
	return c.JSON(fiber.Map{"broadcasts": out})
}

func (h *Handlers) CreateBroadcast(c *fiber.Ctx) error {
	var req struct {
		Name    string `json:"name"`
		Channel string `json:"channel"`
		Subject string `json:"subject"`
		Body    string `json:"body"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	if req.Channel != "email" && req.Channel != "whatsapp" {
		return fiber.NewError(fiber.StatusBadRequest, "channel must be email or whatsapp")
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO broadcasts (name, channel, subject, body, created_by)
		 VALUES ($1,$2,$3,$4,$5) RETURNING id`,
		req.Name, req.Channel, req.Subject, req.Body, callerID(c)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

// SendBroadcast marks a draft as sent and stamps the audience size. Actual
// channel delivery (email/WhatsApp provider) is wired in the messaging module.
func (h *Handlers) SendBroadcast(c *fiber.Ctx) error {
	id := c.Params("id")
	var channel string
	if err := h.Pool.QueryRow(c.Context(), `SELECT channel FROM broadcasts WHERE id=$1`, id).Scan(&channel); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "broadcast not found")
	}
	// Audience = leads who are contactable (and, for email, have an address).
	var targets int
	if channel == "email" {
		_ = h.Pool.QueryRow(c.Context(),
			`SELECT count(*) FROM leads WHERE NOT do_not_contact AND email <> ''`).Scan(&targets)
	} else {
		_ = h.Pool.QueryRow(c.Context(),
			`SELECT count(*) FROM leads WHERE NOT do_not_contact AND phone <> ''`).Scan(&targets)
	}
	if _, err := h.Pool.Exec(c.Context(),
		`UPDATE broadcasts SET status='sent', sent_at=now(), total_targets=$2, total_sent=$2, updated_at=now() WHERE id=$1`,
		id, targets); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "send failed")
	}
	return c.JSON(fiber.Map{"id": id, "status": "sent", "total_targets": targets})
}

func (h *Handlers) DeleteBroadcast(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM broadcasts WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// ---- helpers ---------------------------------------------------------------

func nullStr(s string) any {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return s
}

func nullUUID(s string) any {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return s
}

func rawJSON(b []byte) any {
	if len(b) == 0 {
		return []string{}
	}
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		return []string{}
	}
	return v
}
