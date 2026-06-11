package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
	"golang.org/x/crypto/bcrypt"
)

// =====================================================================
// Ambassador portal — admins manage ambassadors + referrals; ambassadors
// see their own code, referrals and rewards.
// =====================================================================

// ---- Admin: manage ambassadors ---------------------------------------------

// ListAmbassadors returns every ambassador with their code and referral stats.
func (h *Handlers) ListAmbassadors(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT u.id, u.full_name, u.email, COALESCE(p.code,''), COALESCE(p.tier,'standard'),
		       (SELECT count(*) FROM referrals r WHERE r.ambassador_id=u.id),
		       (SELECT count(*) FROM referrals r WHERE r.ambassador_id=u.id AND r.status IN ('enrolled','rewarded')),
		       COALESCE((SELECT sum(reward_paise) FROM referrals r WHERE r.ambassador_id=u.id AND r.status='rewarded'),0)
		FROM users u
		LEFT JOIN ambassador_profiles p ON p.user_id=u.id
		WHERE u.role='ambassador'
		ORDER BY u.full_name`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name, email, code, tier string
		var total, converted int
		var earned int64
		if err := rows.Scan(&id, &name, &email, &code, &tier, &total, &converted, &earned); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "full_name": name, "email": email, "code": code,
			"tier": tier, "referrals": total, "converted": converted, "earned": earned})
	}
	return c.JSON(fiber.Map{"ambassadors": out})
}

// CreateAmbassador creates an ambassador account (login) + profile + code.
func (h *Handlers) CreateAmbassador(c *fiber.Ctx) error {
	var req struct {
		FullName string `json:"full_name"`
		Email    string `json:"email"`
		Phone    string `json:"phone"`
		Password string `json:"password"`
		Code     string `json:"code"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))
	if req.Email == "" || strings.TrimSpace(req.FullName) == "" || req.Password == "" {
		return fiber.NewError(fiber.StatusBadRequest, "full_name, email, password required")
	}
	code := strings.ToUpper(strings.TrimSpace(req.Code))
	if code == "" {
		code = strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(req.FullName), " ", "")) // e.g. "JOHNDOE"
	}
	hash, _ := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)

	tx, err := h.Pool.Begin(c.Context())
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "tx failed")
	}
	defer tx.Rollback(c.Context()) //nolint:errcheck

	var id string
	err = tx.QueryRow(c.Context(),
		`INSERT INTO users (email, phone, full_name, password_hash, role, max_devices)
		 VALUES ($1,$2,$3,$4,'ambassador',$5) RETURNING id`,
		req.Email, req.Phone, req.FullName, string(hash), h.Cfg.MaxDevices).Scan(&id)
	if err != nil {
		if strings.Contains(err.Error(), "users_email_key") {
			return fiber.NewError(fiber.StatusConflict, "email already registered")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	if _, err := tx.Exec(c.Context(),
		`INSERT INTO ambassador_profiles (user_id, code) VALUES ($1,$2)`, id, code); err != nil {
		if strings.Contains(err.Error(), "ambassador_profiles_code_key") {
			return fiber.NewError(fiber.StatusConflict, "referral code already in use")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "profile create failed")
	}
	if err := tx.Commit(c.Context()); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "commit failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "code": code})
}

// AdminListReferrals returns every referral (across all ambassadors).
func (h *Handlers) AdminListReferrals(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT r.id, r.name, r.email, r.phone, r.status, r.reward_paise, r.created_at, COALESCE(u.full_name,'')
		FROM referrals r JOIN users u ON u.id=r.ambassador_id
		ORDER BY r.created_at DESC LIMIT 1000`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	return c.JSON(fiber.Map{"referrals": scanReferrals(rows)})
}

// SetReferralStatus updates a referral's status and (optional) reward.
func (h *Handlers) SetReferralStatus(c *fiber.Ctx) error {
	var req struct {
		Status      string `json:"status"`
		RewardPaise *int64 `json:"reward_paise"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	switch req.Status {
	case "new", "contacted", "enrolled", "rewarded", "rejected":
	default:
		return fiber.NewError(fiber.StatusBadRequest, "invalid status")
	}
	ct, err := h.Pool.Exec(c.Context(), `
		UPDATE referrals SET status=$2,
		  reward_paise = COALESCE($3, reward_paise),
		  updated_at = now()
		WHERE id=$1`, c.Params("id"), req.Status, req.RewardPaise)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "referral not found")
	}
	return c.JSON(fiber.Map{"id": c.Params("id"), "status": req.Status})
}

// ---- Ambassador self -------------------------------------------------------

// MyAmbassador returns the caller's ambassador profile + headline stats.
func (h *Handlers) MyAmbassador(c *fiber.Ctx) error {
	uid := callerID(c)
	var code, tier string
	_ = h.Pool.QueryRow(c.Context(),
		`SELECT COALESCE(code,''), COALESCE(tier,'standard') FROM ambassador_profiles WHERE user_id=$1`, uid).Scan(&code, &tier)
	var total, converted int
	var earned, pending int64
	_ = h.Pool.QueryRow(c.Context(), `
		SELECT count(*),
		       count(*) FILTER (WHERE status IN ('enrolled','rewarded')),
		       COALESCE(sum(reward_paise) FILTER (WHERE status='rewarded'),0),
		       COALESCE(sum(reward_paise) FILTER (WHERE status<>'rewarded'),0)
		FROM referrals WHERE ambassador_id=$1`, uid).Scan(&total, &converted, &earned, &pending)
	return c.JSON(fiber.Map{"code": code, "tier": tier, "referrals": total,
		"converted": converted, "earned": earned, "pending_reward": pending})
}

// MyReferrals lists the caller's own referrals.
func (h *Handlers) MyReferrals(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT r.id, r.name, r.email, r.phone, r.status, r.reward_paise, r.created_at, ''
		FROM referrals r WHERE r.ambassador_id=$1 ORDER BY r.created_at DESC LIMIT 500`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	return c.JSON(fiber.Map{"referrals": scanReferrals(rows)})
}

// CreateReferral lets an ambassador submit a new referral.
func (h *Handlers) CreateReferral(c *fiber.Ctx) error {
	var req struct {
		Name  string `json:"name"`
		Email string `json:"email"`
		Phone string `json:"phone"`
		Notes string `json:"notes"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO referrals (ambassador_id, name, email, phone, notes) VALUES ($1,$2,$3,$4,$5) RETURNING id`,
		callerID(c), req.Name, req.Email, req.Phone, req.Notes).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

func scanReferrals(rows interface {
	Next() bool
	Scan(...any) error
}) []fiber.Map {
	out := []fiber.Map{}
	for rows.Next() {
		var id, name, email, phone, status, ambassador string
		var reward int64
		var at any
		if err := rows.Scan(&id, &name, &email, &phone, &status, &reward, &at, &ambassador); err != nil {
			continue
		}
		out = append(out, fiber.Map{"id": id, "name": name, "email": email, "phone": phone,
			"status": status, "reward_paise": reward, "created_at": at, "ambassador": ambassador})
	}
	return out
}
