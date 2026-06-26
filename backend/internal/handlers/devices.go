package handlers

import (
	"github.com/gofiber/fiber/v2"

	"github.com/onrol/lms-backend/internal/middleware"
)

// ListDevices returns the caller's active devices plus which one is THIS device
// and the effective slot limit, so the UI can show "Using 2 of 2 devices",
// badge the current device, and warn before signing it out.
func (h *Handlers) ListDevices(c *fiber.Ctx) error {
	userID := c.Locals(middleware.LocalUserID).(string)
	devices, err := listActiveDevices(c.Context(), h.Pool, userID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	currentDevice, _ := c.Locals(middleware.LocalDeviceID).(string)
	role, _ := c.Locals(middleware.LocalRole).(string)
	// Staff (instructor/manager/superadmin) are exempt → 0 means "unlimited";
	// everyone else is hard-capped at 2 (matches bindDevice).
	limit := 2
	if role == "instructor" || role == "manager" || role == "superadmin" {
		limit = 0
	}
	return c.JSON(fiber.Map{
		"devices":           devices,
		"current_device_id": currentDevice,
		"max_devices":       limit,
	})
}

// RevokeDevice deactivates one of the caller's devices, freeing a slot. We
// soft-deactivate (is_active=FALSE) rather than delete so the audit trail and
// first_seen history survive.
func (h *Handlers) RevokeDevice(c *fiber.Ctx) error {
	userID := c.Locals(middleware.LocalUserID).(string)
	deviceRowID := c.Params("id")

	tag, err := h.Pool.Exec(c.Context(),
		`UPDATE devices SET is_active=FALSE WHERE id=$1 AND user_id=$2 AND is_active`,
		deviceRowID, userID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "revoke failed")
	}
	if tag.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "device not found")
	}
	return c.JSON(fiber.Map{"revoked": deviceRowID})
}

// ---- Admin device control (manager+) ---------------------------------------

// AdminListUserDevices returns a managed user's active devices, so an admin can
// see who is bound and free up a slot.
func (h *Handlers) AdminListUserDevices(c *fiber.Ctx) error {
	target := c.Params("id")
	if err := h.requireUserInScope(c, target); err != nil {
		return err
	}
	devices, err := listActiveDevices(c.Context(), h.Pool, target)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	return c.JSON(fiber.Map{"user_id": target, "devices": devices})
}

// AdminRevokeUserDevice deactivates one device of a managed user, freeing a slot.
func (h *Handlers) AdminRevokeUserDevice(c *fiber.Ctx) error {
	target := c.Params("id")
	deviceRowID := c.Params("deviceId")
	if err := h.requireUserInScope(c, target); err != nil {
		return err
	}
	tag, err := h.Pool.Exec(c.Context(),
		`UPDATE devices SET is_active=FALSE WHERE id=$1 AND user_id=$2 AND is_active`,
		deviceRowID, target)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "revoke failed")
	}
	if tag.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "device not found")
	}
	return c.JSON(fiber.Map{"user_id": target, "revoked": deviceRowID})
}

// AdminResetUserDevices deactivates ALL of a user's devices at once — the common
// "student got a new phone and is at the device limit" fix.
func (h *Handlers) AdminResetUserDevices(c *fiber.Ctx) error {
	target := c.Params("id")
	if err := h.requireUserInScope(c, target); err != nil {
		return err
	}
	tag, err := h.Pool.Exec(c.Context(),
		`UPDATE devices SET is_active=FALSE WHERE user_id=$1 AND is_active`, target)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "reset failed")
	}
	return c.JSON(fiber.Map{"user_id": target, "devices_reset": tag.RowsAffected()})
}
