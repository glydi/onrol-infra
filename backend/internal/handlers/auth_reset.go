package handlers

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"log"
	"strings"

	"github.com/gofiber/fiber/v2"
	"golang.org/x/crypto/bcrypt"
)

// ForgotPassword issues a 6-digit OTP to the account's email. To avoid leaking
// which emails exist, it always returns 200 — the code is only sent if the email
// matches a real, active account.
func (h *Handlers) ForgotPassword(c *fiber.Ctx) error {
	var req struct {
		Email string `json:"email"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	email := strings.ToLower(strings.TrimSpace(req.Email))
	ok := fiber.Map{"sent": true}
	if email == "" {
		return c.JSON(ok)
	}

	var userID string
	err := h.Pool.QueryRow(c.Context(),
		`SELECT id FROM users WHERE email=$1 AND is_active`, email).Scan(&userID)
	if err != nil {
		return c.JSON(ok) // unknown email — pretend success
	}

	code := sixDigitCode()
	hash, err := bcrypt.GenerateFromPassword([]byte(code), bcrypt.DefaultCost)
	if err != nil {
		return c.JSON(ok)
	}
	// Invalidate any prior unused codes, then store the new one (10-min expiry).
	_, _ = h.Pool.Exec(c.Context(), `UPDATE password_resets SET used=TRUE WHERE user_id=$1 AND used=FALSE`, userID)
	if _, err := h.Pool.Exec(c.Context(),
		`INSERT INTO password_resets (user_id, code_hash, expires_at) VALUES ($1,$2, now() + interval '10 minutes')`,
		userID, string(hash)); err != nil {
		return c.JSON(ok)
	}

	if err := sendEmail(email, "Your ONROL password reset code", otpEmailHTML(code)); err != nil {
		// Email not configured / failed: log so it can be recovered/diagnosed.
		log.Printf("password reset for %s: email send failed: %v (code=%s)", email, err, code)
	}
	return c.JSON(ok)
}

// ResetPassword verifies the OTP and sets a new password.
func (h *Handlers) ResetPassword(c *fiber.Ctx) error {
	var req struct {
		Email    string `json:"email"`
		Code     string `json:"code"`
		Password string `json:"new_password"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	email := strings.ToLower(strings.TrimSpace(req.Email))
	req.Code = strings.TrimSpace(req.Code)
	if email == "" || req.Code == "" {
		return fiber.NewError(fiber.StatusBadRequest, "email and code are required")
	}
	if len(req.Password) < 8 {
		return fiber.NewError(fiber.StatusBadRequest, "new password must be at least 8 characters")
	}

	var userID string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT id FROM users WHERE email=$1 AND is_active`, email).Scan(&userID); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid or expired code")
	}

	// Newest unused, unexpired code for this user.
	var resetID, codeHash string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT id, code_hash FROM password_resets
		 WHERE user_id=$1 AND used=FALSE AND expires_at > now()
		 ORDER BY created_at DESC LIMIT 1`, userID).Scan(&resetID, &codeHash); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid or expired code")
	}
	if bcrypt.CompareHashAndPassword([]byte(codeHash), []byte(req.Code)) != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid or expired code")
	}

	newHash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "hash failed")
	}
	if _, err := h.Pool.Exec(c.Context(),
		`UPDATE users SET password_hash=$2, updated_at=now() WHERE id=$1`, userID, string(newHash)); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	// Burn this code + any other outstanding ones.
	_, _ = h.Pool.Exec(c.Context(), `UPDATE password_resets SET used=TRUE WHERE user_id=$1`, userID)
	return c.JSON(fiber.Map{"reset": true})
}

func sixDigitCode() string {
	var b [4]byte
	_, _ = rand.Read(b[:])
	return fmt.Sprintf("%06d", binary.BigEndian.Uint32(b[:])%1_000_000)
}
