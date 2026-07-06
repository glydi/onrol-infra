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
	// The identifier may be an email, a username, or a phone number.
	idRaw := strings.TrimSpace(req.Email)
	req.Email = strings.ToLower(idRaw)

	// 1. Verify credentials. Phone matches on digits only (ignore +, spaces, -),
	//    and only when the identifier has at least 6 digits so an email never
	//    collides with a blank phone.
	var user models.User
	err := h.Pool.QueryRow(c.Context(),
		`SELECT id, COALESCE(email,''), full_name, role, password_hash, max_devices, is_active
		 FROM users
		 WHERE email=$1 OR lower(username)=$1 OR lower(login_id)=$1
		    OR (length(regexp_replace($2,'\D','','g')) >= 6
		        AND regexp_replace(COALESCE(phone,''),'\D','','g') = regexp_replace($2,'\D','','g'))`,
		req.Email, idRaw,
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

	// Already bound AND still active? Just refresh it — it's already counted.
	var existingID string
	var existingActive bool
	err = tx.QueryRow(ctx,
		`SELECT id, is_active FROM devices WHERE user_id=$1 AND device_id=$2`,
		user.ID, deviceID,
	).Scan(&existingID, &existingActive)
	switch {
	case err == nil && existingActive:
		_, err = tx.Exec(ctx,
			`UPDATE devices SET last_seen=now(), platform=$3, model=$4,
			       attestation_verified = attestation_verified OR $5
			 WHERE id=$1 AND user_id=$2`,
			existingID, user.ID, platform, model, markVerified)
		if err != nil {
			return err
		}
		return tx.Commit(ctx)
	case err == nil:
		// Existing but REVOKED: reactivating it must pass the cap check below,
		// exactly like a new device — otherwise a previously-removed device could
		// silently re-activate and push the user past the limit.
	case errors.Is(err, pgx.ErrNoRows):
		// New device: cap check below.
	default:
		return err
	}

	// STRICT cap: 2 active devices for everyone, EXCEPT accounts explicitly
	// granted unlimited devices via a high max_devices (>= 99 — e.g. a QA/test
	// account). Real users keep max_devices=2, so they stay strictly capped. The
	// user-row lock above serialises concurrent logins, so this is race-free.
	if user.MaxDevices < 99 {
		const hardCap = 2
		var activeCount int
		if err := tx.QueryRow(ctx,
			`SELECT count(*) FROM devices WHERE user_id=$1 AND is_active`,
			user.ID,
		).Scan(&activeCount); err != nil {
			return err
		}
		if activeCount >= hardCap {
			devices, _ := listActiveDevices(ctx, tx, user.ID)
			return deviceLimitError{devices: devices}
		}
	}

	if existingID != "" {
		// Reactivate the previously-revoked device row (now within the cap).
		_, err = tx.Exec(ctx,
			`UPDATE devices SET is_active=TRUE, last_seen=now(), platform=$3, model=$4,
			       attestation_verified = attestation_verified OR $5
			 WHERE id=$1 AND user_id=$2`,
			existingID, user.ID, platform, model, markVerified)
	} else {
		_, err = tx.Exec(ctx,
			`INSERT INTO devices (user_id, device_id, platform, model, attestation_verified)
			 VALUES ($1, $2, $3, $4, $5)`,
			user.ID, deviceID, platform, model, markVerified)
	}
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
