package handlers

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"

	"github.com/onrol/lms-backend/internal/middleware"
	"github.com/onrol/lms-backend/internal/models"
)

type registerReq struct {
	Email    string `json:"email"`
	Phone    string `json:"phone"`
	FullName string `json:"full_name"`
	Password string `json:"password"`
}

type loginReq struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	Platform string `json:"platform"` // android | ios | web
	Model    string `json:"model"`
	Portal   string `json:"portal"` // admin | mentor | student — gates by role
}

// portalAllowsRole enforces that a login portal only admits matching roles, so a
// student can't sign in through the admin portal even with valid credentials.
func portalAllowsRole(portal, role string) bool {
	switch portal {
	case "", "any":
		return true
	case "student":
		return role == "student"
	case "mentor":
		return role == "instructor"
	case "admin":
		return role == "manager" || role == "superadmin"
	default:
		return false
	}
}

// Register creates an account. (In production gate this behind admin/enrolment
// flows; open self-registration is fine for early testing.)
func (h *Handlers) Register(c *fiber.Ctx) error {
	var req registerReq
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))
	if req.Email == "" || req.Password == "" || req.FullName == "" {
		return fiber.NewError(fiber.StatusBadRequest, "email, password, full_name are required")
	}
	if len(req.Password) < 8 {
		return fiber.NewError(fiber.StatusBadRequest, "password must be at least 8 characters")
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "hash failed")
	}

	var id string
	err = h.Pool.QueryRow(c.Context(),
		`INSERT INTO users (email, phone, full_name, password_hash, max_devices)
		 VALUES ($1, $2, $3, $4, $5) RETURNING id`,
		req.Email, req.Phone, req.FullName, string(hash), h.Cfg.MaxDevices,
	).Scan(&id)
	if err != nil {
		if strings.Contains(err.Error(), "users_email_key") {
			return fiber.NewError(fiber.StatusConflict, "email already registered")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "email": req.Email})
}

// Login authenticates, enforces the per-account device limit server-side, and
// issues a device-bound JWT. See ARCHITECTURE.md §4.1.
func (h *Handlers) Login(c *fiber.Ctx) error {
	deviceID := strings.TrimSpace(c.Get("X-Device-UUID"))
	if deviceID == "" {
		return fiber.NewError(fiber.StatusBadRequest, "X-Device-UUID header is required")
	}

	var req loginReq
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	// The identifier may be an email or a username (both lower-cased).
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))

	// 1. Verify credentials.
	var user models.User
	err := h.Pool.QueryRow(c.Context(),
		`SELECT id, email, full_name, role, password_hash, max_devices, is_active
		 FROM users WHERE email=$1 OR lower(username)=$1`, req.Email,
	).Scan(&user.ID, &user.Email, &user.FullName, &user.Role, &user.PasswordHash, &user.MaxDevices, &user.IsActive)
	if errors.Is(err, pgx.ErrNoRows) {
		return fiber.NewError(fiber.StatusUnauthorized, "invalid credentials")
	}
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "lookup failed")
	}
	if !user.IsActive {
		return fiber.NewError(fiber.StatusForbidden, "account disabled")
	}
	if bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Password)) != nil {
		return fiber.NewError(fiber.StatusUnauthorized, "invalid credentials")
	}

	// Portal gate: a role-specific login page only admits its own role.
	if !portalAllowsRole(req.Portal, user.Role) {
		return fiber.NewError(fiber.StatusForbidden,
			"this is the "+req.Portal+" portal; your account isn't a "+req.Portal+" account")
	}

	// 2. Attestation: the only thing that makes device-binding more than a
	//    spoofable header. Token comes from the mobile platform attestation API.
	attToken := c.Get("X-Attestation-Token")
	res := h.Attestor.Verify(c.Context(), req.Platform, deviceID, attToken)
	allow, markVerified := middleware.AttestationDecision(h.Cfg.AttestationMode, res)
	if !allow {
		return fiber.NewError(fiber.StatusForbidden, "device attestation failed: "+res.Reason)
	}

	// 3. Bind the device within the per-account limit (server-enforced).
	if err := h.bindDevice(c.Context(), user, deviceID, req.Platform, req.Model, markVerified); err != nil {
		var le deviceLimitError
		if errors.As(err, &le) {
			return c.Status(fiber.StatusConflict).JSON(fiber.Map{
				"error":       "device limit reached",
				"max_devices": user.MaxDevices,
				"devices":     le.devices,
				"hint":        "remove a device via DELETE /api/v1/devices/:id then retry",
			})
		}
		return fiber.NewError(fiber.StatusInternalServerError, "device binding failed")
	}

	// 4. Issue the token.
	tok, err := h.JWT.Issue(user.ID, deviceID, time.Now())
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "token issue failed")
	}
	return c.JSON(fiber.Map{
		"access_token": tok,
		"user":         user,
	})
}

type deviceLimitError struct{ devices []models.Device }

func (deviceLimitError) Error() string { return "device limit reached" }

// bindDevice runs the bind decision in a single transaction so concurrent
// logins can't race past the limit.
func (h *Handlers) bindDevice(ctx context.Context, user models.User, deviceID, platform, model string, markVerified bool) error {
	tx, err := h.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op after commit

	// Serialize concurrent logins for THIS user by locking the user row, so two
	// simultaneous new-device logins can't both pass the capacity check.
	if _, err := tx.Exec(ctx, `SELECT 1 FROM users WHERE id=$1 FOR UPDATE`, user.ID); err != nil {
		return err
	}

	// Already bound? Just refresh it.
	var existingID string
	err = tx.QueryRow(ctx,
		`SELECT id FROM devices WHERE user_id=$1 AND device_id=$2`,
		user.ID, deviceID,
	).Scan(&existingID)
	switch {
	case err == nil:
		_, err = tx.Exec(ctx,
			`UPDATE devices SET last_seen=now(), is_active=TRUE, platform=$3, model=$4,
			       attestation_verified = attestation_verified OR $5
			 WHERE id=$1 AND user_id=$2`,
			existingID, user.ID, platform, model, markVerified)
		if err != nil {
			return err
		}
		return tx.Commit(ctx)
	case errors.Is(err, pgx.ErrNoRows):
		// fall through to capacity check
	default:
		return err
	}

	// New device: enforce the limit — except for admins (manager/superadmin),
	// who are exempt and may sign in from any number of devices. The user-row
	// lock above already serializes concurrent logins, so a plain count is
	// race-free here.
	adminExempt := user.Role == "manager" || user.Role == "superadmin"
	if !adminExempt {
		var activeCount int
		if err := tx.QueryRow(ctx,
			`SELECT count(*) FROM devices WHERE user_id=$1 AND is_active`,
			user.ID,
		).Scan(&activeCount); err != nil {
			return err
		}
		if activeCount >= user.MaxDevices {
			devices, _ := listActiveDevices(ctx, tx, user.ID)
			return deviceLimitError{devices: devices}
		}
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO devices (user_id, device_id, platform, model, attestation_verified)
		 VALUES ($1, $2, $3, $4, $5)`,
		user.ID, deviceID, platform, model, markVerified)
	if err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func listActiveDevices(ctx context.Context, q querier, userID string) ([]models.Device, error) {
	rows, err := q.Query(ctx,
		`SELECT id, device_id, platform, model, attestation_verified, first_seen, last_seen
		 FROM devices WHERE user_id=$1 AND is_active ORDER BY first_seen`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []models.Device
	for rows.Next() {
		var d models.Device
		d.UserID = userID
		d.IsActive = true
		if err := rows.Scan(&d.ID, &d.DeviceID, &d.Platform, &d.Model,
			&d.AttestationVerified, &d.FirstSeen, &d.LastSeen); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}
