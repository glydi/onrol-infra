package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
)

// =====================================================================
// College Partner portal — admins + employees manage partner colleges,
// their cohorts/intakes, MOU status and placements.
// =====================================================================

// CollegeSummary returns headline numbers for the dashboard.
func (h *Handlers) CollegeSummary(c *fiber.Ctx) error {
	out := fiber.Map{}
	one := func(q string) int64 {
		var n int64
		_ = h.Pool.QueryRow(c.Context(), q).Scan(&n)
		return n
	}
	out["colleges"] = one(`SELECT count(*) FROM colleges`)
	out["signed"] = one(`SELECT count(*) FROM colleges WHERE mou_status='signed'`)
	out["students"] = one(`SELECT COALESCE(sum(students),0) FROM college_cohorts`)
	out["placed"] = one(`SELECT COALESCE(sum(placed),0) FROM college_cohorts`)
	return c.JSON(out)
}

// ---- Colleges --------------------------------------------------------------

func (h *Handlers) ListColleges(c *fiber.Ctx) error {
	q := strings.TrimSpace(c.Query("q"))
	sql := `SELECT c.id, c.name, c.contact_person, c.email, c.phone, c.city, c.mou_status, c.status, c.notes,
	               COALESCE((SELECT sum(students) FROM college_cohorts ch WHERE ch.college_id=c.id),0),
	               COALESCE((SELECT sum(placed) FROM college_cohorts ch WHERE ch.college_id=c.id),0)
	        FROM colleges c WHERE 1=1`
	args := []any{}
	if q != "" {
		args = append(args, "%"+strings.ToLower(q)+"%")
		sql += " AND (lower(c.name) LIKE $1 OR lower(c.city) LIKE $1)"
	}
	sql += " ORDER BY c.name LIMIT 500"
	rows, err := h.Pool.Query(c.Context(), sql, args...)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name, person, email, phone, city, mou, status, notes string
		var students, placed int64
		if err := rows.Scan(&id, &name, &person, &email, &phone, &city, &mou, &status, &notes, &students, &placed); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "name": name, "contact_person": person, "email": email,
			"phone": phone, "city": city, "mou_status": mou, "status": status, "notes": notes,
			"students": students, "placed": placed})
	}
	return c.JSON(fiber.Map{"colleges": out})
}

func (h *Handlers) CreateCollege(c *fiber.Ctx) error {
	var req struct {
		Name          string `json:"name"`
		ContactPerson string `json:"contact_person"`
		Email         string `json:"email"`
		Phone         string `json:"phone"`
		City          string `json:"city"`
		MouStatus     string `json:"mou_status"`
		Notes         string `json:"notes"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	if !validMou(req.MouStatus) {
		req.MouStatus = "none"
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO colleges (name, contact_person, email, phone, city, mou_status, notes)
		 VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
		req.Name, req.ContactPerson, req.Email, req.Phone, req.City, req.MouStatus, req.Notes).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

func (h *Handlers) UpdateCollege(c *fiber.Ctx) error {
	var req struct {
		Name          *string `json:"name"`
		ContactPerson *string `json:"contact_person"`
		Email         *string `json:"email"`
		Phone         *string `json:"phone"`
		City          *string `json:"city"`
		MouStatus     *string `json:"mou_status"`
		Status        *string `json:"status"`
		Notes         *string `json:"notes"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if req.MouStatus != nil && !validMou(*req.MouStatus) {
		return fiber.NewError(fiber.StatusBadRequest, "invalid mou_status")
	}
	ct, err := h.Pool.Exec(c.Context(), `
		UPDATE colleges SET
		  name=COALESCE($2,name), contact_person=COALESCE($3,contact_person), email=COALESCE($4,email),
		  phone=COALESCE($5,phone), city=COALESCE($6,city), mou_status=COALESCE($7,mou_status),
		  status=COALESCE($8,status), notes=COALESCE($9,notes), updated_at=now()
		WHERE id=$1`, c.Params("id"), req.Name, req.ContactPerson, req.Email, req.Phone, req.City,
		req.MouStatus, req.Status, req.Notes)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "college not found")
	}
	return c.JSON(fiber.Map{"updated": true})
}

func (h *Handlers) DeleteCollege(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM colleges WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// ---- Cohorts ---------------------------------------------------------------

func (h *Handlers) ListCohorts(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, name, year, students, placed, status, notes FROM college_cohorts
		 WHERE college_id=$1 ORDER BY created_at DESC`, c.Params("id"))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name, status, notes string
		var year *int
		var students, placed int
		if err := rows.Scan(&id, &name, &year, &students, &placed, &status, &notes); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "name": name, "year": year, "students": students,
			"placed": placed, "status": status, "notes": notes})
	}
	return c.JSON(fiber.Map{"cohorts": out})
}

func (h *Handlers) AddCohort(c *fiber.Ctx) error {
	collegeID := c.Params("id")
	var req struct {
		Name     string `json:"name"`
		Year     *int   `json:"year"`
		Students int    `json:"students"`
		Placed   int    `json:"placed"`
		Status   string `json:"status"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	if req.Status != "planned" && req.Status != "completed" {
		req.Status = "active"
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO college_cohorts (college_id, name, year, students, placed, status)
		 VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
		collegeID, req.Name, req.Year, req.Students, req.Placed, req.Status).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

func (h *Handlers) UpdateCohort(c *fiber.Ctx) error {
	var req struct {
		Students *int    `json:"students"`
		Placed   *int    `json:"placed"`
		Status   *string `json:"status"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	ct, err := h.Pool.Exec(c.Context(),
		`UPDATE college_cohorts SET students=COALESCE($2,students), placed=COALESCE($3,placed),
		   status=COALESCE($4,status) WHERE id=$1`,
		c.Params("id"), req.Students, req.Placed, req.Status)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "cohort not found")
	}
	return c.JSON(fiber.Map{"updated": true})
}

func (h *Handlers) DeleteCohort(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM college_cohorts WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

func validMou(s string) bool {
	switch s {
	case "none", "draft", "signed", "expired":
		return true
	}
	return false
}
