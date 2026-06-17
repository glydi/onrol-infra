package handlers

import (
	"github.com/gofiber/fiber/v2"
)

// TwoFAStatus reports whether the caller has TOTP 2FA enabled.
func (h *Handlers) TwoFAStatus(c *fiber.Ctx) error {
	var enabled bool
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT COALESCE(totp_enabled,false) FROM users WHERE id=$1`, callerID(c)).Scan(&enabled); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "user not found")
	}
	return c.JSON(fiber.Map{"enabled": enabled})
}

// TwoFASetup generates a fresh secret (pending verification) and returns the
// secret + otpauth URL for the authenticator app. Does not enable 2FA yet.
func (h *Handlers) TwoFASetup(c *fiber.Ctx) error {
	var email string
	var enabled bool
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT email, COALESCE(totp_enabled,false) FROM users WHERE id=$1`, callerID(c)).Scan(&email, &enabled); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "user not found")
	}
	if enabled {
		return fiber.NewError(fiber.StatusConflict, "two-factor is already enabled")
	}
	secret := generateTOTPSecret()
	if _, err := h.Pool.Exec(c.Context(),
		`UPDATE users SET totp_secret=$2, totp_enabled=FALSE, updated_at=now() WHERE id=$1`,
		callerID(c), secret); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "setup failed")
	}
	return c.JSON(fiber.Map{"secret": secret, "otpauth_url": totpAuthURL(secret, email)})
}

// TwoFAVerify confirms a code against the pending secret and switches 2FA on.
func (h *Handlers) TwoFAVerify(c *fiber.Ctx) error {
	var req struct {
		Code string `json:"code"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	var secret string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT COALESCE(totp_secret,'') FROM users WHERE id=$1`, callerID(c)).Scan(&secret); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "user not found")
	}
	if secret == "" {
		return fiber.NewError(fiber.StatusBadRequest, "start setup first")
	}
	if !totpValidate(secret, req.Code) {
		return fiber.NewError(fiber.StatusUnauthorized, "incorrect code — check your authenticator and try again")
	}
	if _, err := h.Pool.Exec(c.Context(),
		`UPDATE users SET totp_enabled=TRUE, updated_at=now() WHERE id=$1`, callerID(c)); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "enable failed")
	}
	return c.JSON(fiber.Map{"enabled": true})
}

// TwoFADisable turns 2FA off after confirming a current code, and clears the secret.
func (h *Handlers) TwoFADisable(c *fiber.Ctx) error {
	var req struct {
		Code string `json:"code"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	var secret string
	var enabled bool
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT COALESCE(totp_secret,''), COALESCE(totp_enabled,false) FROM users WHERE id=$1`, callerID(c)).Scan(&secret, &enabled); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "user not found")
	}
	if enabled && !totpValidate(secret, req.Code) {
		return fiber.NewError(fiber.StatusUnauthorized, "incorrect code")
	}
	if _, err := h.Pool.Exec(c.Context(),
		`UPDATE users SET totp_enabled=FALSE, totp_secret=NULL, updated_at=now() WHERE id=$1`, callerID(c)); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "disable failed")
	}
	return c.JSON(fiber.Map{"enabled": false})
}
