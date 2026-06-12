package handlers

import (
	"github.com/gofiber/fiber/v2"
	"golang.org/x/crypto/bcrypt"
)

// ChangeMyPassword lets a signed-in user rotate their own password after
// confirming their current one.
func (h *Handlers) ChangeMyPassword(c *fiber.Ctx) error {
	var req struct {
		Current string `json:"current_password"`
		New     string `json:"new_password"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if len(req.New) < 8 {
		return fiber.NewError(fiber.StatusBadRequest, "new password must be at least 8 characters")
	}
	var hash string
	if err := h.Pool.QueryRow(c.Context(), `SELECT password_hash FROM users WHERE id=$1`, callerID(c)).Scan(&hash); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "user not found")
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.Current)) != nil {
		return fiber.NewError(fiber.StatusUnauthorized, "current password is incorrect")
	}
	nh, err := bcrypt.GenerateFromPassword([]byte(req.New), bcrypt.DefaultCost)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "hash failed")
	}
	if _, err := h.Pool.Exec(c.Context(), `UPDATE users SET password_hash=$2, updated_at=now() WHERE id=$1`, callerID(c), string(nh)); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	return c.JSON(fiber.Map{"updated": true})
}

// RevokeAllMyDevices logs the caller out of every device by deactivating all of
// their active device bindings (the "Logout all devices" action).
func (h *Handlers) RevokeAllMyDevices(c *fiber.Ctx) error {
	tag, err := h.Pool.Exec(c.Context(),
		`UPDATE devices SET is_active=FALSE WHERE user_id=$1 AND is_active`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "reset failed")
	}
	return c.JSON(fiber.Map{"devices_reset": tag.RowsAffected()})
}
