package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
	"golang.org/x/crypto/bcrypt"
)

// =====================================================================
// Franchise Partner portal — admins manage partners + see performance;
// partners run their branch: enrol students, track revenue + their share.
// =====================================================================

// ---- Admin: manage franchises ----------------------------------------------

func (h *Handlers) ListFranchises(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT u.id, u.full_name, u.email, COALESCE(p.territory,''), COALESCE(p.code,''),
		       COALESCE(p.revenue_share,0), COALESCE(p.status,'active'),
		       (SELECT count(*) FROM franchise_enrollments e WHERE e.franchise_id=u.id),
		       COALESCE((SELECT sum(fee_paise) FROM franchise_enrollments e WHERE e.franchise_id=u.id AND e.status='paid'),0)
		FROM users u LEFT JOIN franchise_profiles p ON p.user_id=u.id
		WHERE u.role='franchise_partner' ORDER BY u.full_name`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name, email, territory, code, status string
		var share float64
		var students int
		var revenue int64
		if err := rows.Scan(&id, &name, &email, &territory, &code, &share, &status, &students, &revenue); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "full_name": name, "email": email, "territory": territory,
			"code": code, "revenue_share": share, "status": status, "students": students, "revenue": revenue})
	}
	return c.JSON(fiber.Map{"franchises": out})
}

func (h *Handlers) CreateFranchise(c *fiber.Ctx) error {
	var req struct {
		FullName     string  `json:"full_name"`
		Email        string  `json:"email"`
		Phone        string  `json:"phone"`
		Password     string  `json:"password"`
		Territory    string  `json:"territory"`
		Code         string  `json:"code"`
		RevenueShare float64 `json:"revenue_share"`
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
		code = strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(req.FullName), " ", ""))
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
		 VALUES ($1,$2,$3,$4,'franchise_partner',$5) RETURNING id`,
		req.Email, req.Phone, req.FullName, string(hash), h.Cfg.MaxDevices).Scan(&id)
	if err != nil {
		if strings.Contains(err.Error(), "users_email_key") {
			return fiber.NewError(fiber.StatusConflict, "email already registered")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	if _, err := tx.Exec(c.Context(),
		`INSERT INTO franchise_profiles (user_id, territory, code, revenue_share) VALUES ($1,$2,$3,$4)`,
		id, req.Territory, code, req.RevenueShare); err != nil {
		if strings.Contains(err.Error(), "franchise_profiles_code_key") {
			return fiber.NewError(fiber.StatusConflict, "code already in use")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "profile create failed")
	}
	if err := tx.Commit(c.Context()); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "commit failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "code": code})
}

func (h *Handlers) AdminListEnrollments(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT e.id, e.student_name, e.phone, e.course, e.fee_paise, e.status, e.created_at, COALESCE(u.full_name,'')
		FROM franchise_enrollments e JOIN users u ON u.id=e.franchise_id
		ORDER BY e.created_at DESC LIMIT 1000`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	return c.JSON(fiber.Map{"enrollments": scanEnrollments(rows)})
}

func (h *Handlers) SetEnrollmentStatus(c *fiber.Ctx) error {
	var req struct {
		Status string `json:"status"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	switch req.Status {
	case "enrolled", "paid", "dropped":
	default:
		return fiber.NewError(fiber.StatusBadRequest, "invalid status")
	}
	ct, err := h.Pool.Exec(c.Context(),
		`UPDATE franchise_enrollments SET status=$2, updated_at=now() WHERE id=$1`, c.Params("id"), req.Status)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "enrollment not found")
	}
	return c.JSON(fiber.Map{"id": c.Params("id"), "status": req.Status})
}

// ---- Franchise self --------------------------------------------------------

func (h *Handlers) MyFranchise(c *fiber.Ctx) error {
	uid := callerID(c)
	var territory, code string
	var share float64
	_ = h.Pool.QueryRow(c.Context(),
		`SELECT COALESCE(territory,''), COALESCE(code,''), COALESCE(revenue_share,0)
		 FROM franchise_profiles WHERE user_id=$1`, uid).Scan(&territory, &code, &share)
	var students, paid int
	var revenue int64
	_ = h.Pool.QueryRow(c.Context(), `
		SELECT count(*), count(*) FILTER (WHERE status='paid'),
		       COALESCE(sum(fee_paise) FILTER (WHERE status='paid'),0)
		FROM franchise_enrollments WHERE franchise_id=$1`, uid).Scan(&students, &paid, &revenue)
	myShare := int64(float64(revenue) * share / 100)
	return c.JSON(fiber.Map{"territory": territory, "code": code, "revenue_share": share,
		"students": students, "paid": paid, "revenue": revenue, "my_share": myShare})
}

func (h *Handlers) MyEnrollments(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT e.id, e.student_name, e.phone, e.course, e.fee_paise, e.status, e.created_at, ''
		FROM franchise_enrollments e WHERE e.franchise_id=$1 ORDER BY e.created_at DESC LIMIT 500`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	return c.JSON(fiber.Map{"enrollments": scanEnrollments(rows)})
}

func (h *Handlers) CreateEnrollment(c *fiber.Ctx) error {
	var req struct {
		StudentName string `json:"student_name"`
		Phone       string `json:"phone"`
		Course      string `json:"course"`
		FeePaise    int64  `json:"fee_paise"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.StudentName) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "student_name required")
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO franchise_enrollments (franchise_id, student_name, phone, course, fee_paise)
		 VALUES ($1,$2,$3,$4,$5) RETURNING id`,
		callerID(c), req.StudentName, req.Phone, req.Course, req.FeePaise).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

func scanEnrollments(rows interface {
	Next() bool
	Scan(...any) error
}) []fiber.Map {
	out := []fiber.Map{}
	for rows.Next() {
		var id, student, phone, course, status, franchise string
		var fee int64
		var at any
		if err := rows.Scan(&id, &student, &phone, &course, &fee, &status, &at, &franchise); err != nil {
			continue
		}
		out = append(out, fiber.Map{"id": id, "student_name": student, "phone": phone, "course": course,
			"fee_paise": fee, "status": status, "created_at": at, "franchise": franchise})
	}
	return out
}
