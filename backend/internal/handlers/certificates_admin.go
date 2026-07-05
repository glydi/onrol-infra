package handlers

import (
	"crypto/rand"
	"encoding/hex"
	"strings"

	"github.com/gofiber/fiber/v2"
	"github.com/jackc/pgx/v5"
)

func newCertSerial() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return "ONROL-" + strings.ToUpper(hex.EncodeToString(b))
}

func collectIDs(rows pgx.Rows) []string {
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	return ids
}

// IssueCertificates issues certificates to learners enrolled in a course:
// individually (user_ids), batch-wise (batch), or to everyone enrolled (all).
// Already-certified learners are skipped. Course staff only.
func (h *Handlers) IssueCertificates(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		UserIDs []string `json:"user_ids"`
		Batch   *string  `json:"batch"`
		All     bool     `json:"all"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}

	var targets []string
	switch {
	case len(req.UserIDs) > 0:
		rows, err := h.Pool.Query(c.Context(),
			`SELECT user_id FROM course_enrollments WHERE course_id=$1 AND user_id = ANY($2)`,
			courseID, req.UserIDs)
		if err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "query failed")
		}
		targets = collectIDs(rows)
	case req.Batch != nil:
		rows, err := h.Pool.Query(c.Context(),
			`SELECT ce.user_id FROM course_enrollments ce JOIN users u ON u.id=ce.user_id
			 WHERE ce.course_id=$1 AND u.batch=$2`, courseID, *req.Batch)
		if err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "query failed")
		}
		targets = collectIDs(rows)
	case req.All:
		rows, err := h.Pool.Query(c.Context(),
			`SELECT user_id FROM course_enrollments WHERE course_id=$1`, courseID)
		if err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "query failed")
		}
		targets = collectIDs(rows)
	default:
		return fiber.NewError(fiber.StatusBadRequest, "specify user_ids, batch, or all")
	}

	issued := 0
	for _, uid := range targets {
		tag, err := h.Pool.Exec(c.Context(),
			`INSERT INTO certificates (user_id, course_id, serial) VALUES ($1,$2,$3)
			 ON CONFLICT (user_id, course_id) DO NOTHING`, uid, courseID, newCertSerial())
		if err == nil && tag.RowsAffected() > 0 {
			issued++
		}
	}
	return c.JSON(fiber.Map{"issued": issued, "targets": len(targets)})
}

// ListCourseCertificates returns who already holds a certificate for the course,
// so the console can show issued status. Course staff only.
func (h *Handlers) ListCourseCertificates(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	rows, err := h.Pool.Query(c.Context(),
		`SELECT user_id, serial, issued_at FROM certificates WHERE course_id=$1`, courseID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var uid, serial string
		var at any
		if err := rows.Scan(&uid, &serial, &at); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"user_id": uid, "serial": serial, "issued_at": at})
	}
	return c.JSON(fiber.Map{"certificates": out})
}

// RevokeCertificate removes a learner's certificate for a course. Staff only.
func (h *Handlers) RevokeCertificate(c *fiber.Ctx) error {
	courseID := c.Params("id")
	userID := c.Params("userId")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	if _, err := h.Pool.Exec(c.Context(),
		`DELETE FROM certificates WHERE course_id=$1 AND user_id=$2`, courseID, userID); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "revoke failed")
	}
	return c.JSON(fiber.Map{"revoked": true})
}
