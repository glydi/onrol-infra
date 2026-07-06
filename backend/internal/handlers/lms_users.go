package handlers

import (
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"
)

// ---- Users (manager+) ------------------------------------------------------

// ListUsers returns users. A manager sees only users in their scoped groups;
// a superadmin sees everyone.
func (h *Handlers) ListUsers(c *fiber.Ctx) error {
	// Route is manager+ only; admins/managers manage everyone, so list all.
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, email, full_name, role, is_active, created_at, batch, username, course_label, COALESCE(login_id,'') FROM users ORDER BY created_at DESC LIMIT 1000`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, email, name, role, loginID string
		var active bool
		var created any
		var batch *string
		var username, courseLabel *string
		if err := rows.Scan(&id, &email, &name, &role, &active, &created, &batch, &username, &courseLabel, &loginID); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "email": email, "full_name": name,
			"role": role, "is_active": active, "created_at": created, "batch": batch,
			"username": username, "course_label": courseLabel, "login_id": loginID})
	}
	return c.JSON(fiber.Map{"users": out})
}

// ListInstructors returns all active instructors — feeds the "assign instructor"
// dropdown when an admin creates a course.
func (h *Handlers) ListInstructors(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, full_name, email FROM users WHERE role='instructor' AND is_active ORDER BY full_name`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name, email string
		if err := rows.Scan(&id, &name, &email); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "full_name": name, "email": email})
	}
	return c.JSON(fiber.Map{"instructors": out})
}

// CreateManagedUser creates a user and (optionally) adds them to a group within
// the caller's scope. Managers cannot mint superadmins.
func (h *Handlers) CreateManagedUser(c *fiber.Ctx) error {
	var req struct {
		Email       string  `json:"email"`
		Username    string  `json:"username"`
		FullName    string  `json:"full_name"`
		Phone       string  `json:"phone"`
		Password    string  `json:"password"`
		Role        string  `json:"role"`
		GroupID     string  `json:"group_id"`
		Batch       *string `json:"batch"`
		CourseLabel string  `json:"course_label"`
		Occupation  string  `json:"occupation"`
		Location    string  `json:"location"`
		Linkedin    string  `json:"linkedin"`
		Github      string  `json:"github"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))
	req.Username = strings.ToLower(strings.TrimSpace(req.Username))
	if req.Email == "" || req.FullName == "" {
		return fiber.NewError(fiber.StatusBadRequest, "email and full_name required")
	}
	// New users get a known default password unless one is supplied; the admin
	// can change it later (or the user can in Settings).
	if strings.TrimSpace(req.Password) == "" {
		req.Password = "onrol@ai"
	}
	if req.Role == "" {
		req.Role = "student"
	}
	if req.Role == "superadmin" && callerRole(c) != "superadmin" {
		return fiber.NewError(fiber.StatusForbidden, "only superadmin can create superadmins")
	}
	if callerRole(c) == "manager" && (req.Role == "manager") {
		return fiber.NewError(fiber.StatusForbidden, "managers cannot create managers")
	}
	// If a group is given, the caller must have scope over it.
	if req.GroupID != "" {
		if err := h.requireGroupScope(c, req.GroupID); err != nil {
			return err
		}
	}
	hash, _ := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)

	tx, err := h.Pool.Begin(c.Context())
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "tx failed")
	}
	defer tx.Rollback(c.Context())
	var id string
	var uname any
	if req.Username != "" {
		uname = req.Username
	}
	// Optional detail fields are stored as NULL when blank.
	nilIfBlank := func(s string) any {
		if t := strings.TrimSpace(s); t != "" {
			return t
		}
		return nil
	}
	var batch any
	if req.Batch != nil && strings.TrimSpace(*req.Batch) != "" {
		batch = strings.TrimSpace(*req.Batch)
	}
	err = tx.QueryRow(c.Context(),
		`INSERT INTO users (email, username, phone, full_name, password_hash, role, max_devices,
		                    batch, course_label, occupation, location, linkedin, github)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) RETURNING id`,
		req.Email, uname, req.Phone, req.FullName, string(hash), req.Role, h.Cfg.MaxDevices,
		batch, nilIfBlank(req.CourseLabel), nilIfBlank(req.Occupation),
		nilIfBlank(req.Location), nilIfBlank(req.Linkedin), nilIfBlank(req.Github),
	).Scan(&id)
	if err != nil {
		if strings.Contains(err.Error(), "users_email_key") {
			return fiber.NewError(fiber.StatusConflict, "email already registered")
		}
		if strings.Contains(err.Error(), "idx_users_username") {
			return fiber.NewError(fiber.StatusConflict, "username already taken")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	if req.GroupID != "" {
		if _, err := tx.Exec(c.Context(),
			`INSERT INTO group_members (group_id, user_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`,
			req.GroupID, id); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "group add failed")
		}
	}
	if err := tx.Commit(c.Context()); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "commit failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "email": req.Email, "role": req.Role})
}

// SetUserRole assigns a role (within scope). Managers can set student/instructor.
func (h *Handlers) SetUserRole(c *fiber.Ctx) error {
	target := c.Params("id")
	var req struct {
		Role string `json:"role"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	switch req.Role {
	case "student", "instructor", "manager", "superadmin", "live_host":
	default:
		return fiber.NewError(fiber.StatusBadRequest, "invalid role")
	}
	if callerRole(c) != "superadmin" {
		if req.Role == "manager" || req.Role == "superadmin" {
			return fiber.NewError(fiber.StatusForbidden, "managers can only assign student/instructor")
		}
		if err := h.requireUserInScope(c, target); err != nil {
			return err
		}
	}
	tag, err := h.Pool.Exec(c.Context(), `UPDATE users SET role=$2, updated_at=now() WHERE id=$1`, target, req.Role)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if tag.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "user not found")
	}
	return c.JSON(fiber.Map{"id": target, "role": req.Role})
}

// ResetUserPassword sets a new password for a managed user.
func (h *Handlers) ResetUserPassword(c *fiber.Ctx) error {
	target := c.Params("id")
	var req struct {
		Password string `json:"password"`
	}
	if err := c.BodyParser(&req); err != nil || len(req.Password) < 8 {
		return fiber.NewError(fiber.StatusBadRequest, "password (min 8) required")
	}
	if callerRole(c) != "superadmin" {
		if err := h.requireUserInScope(c, target); err != nil {
			return err
		}
	}
	hash, _ := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	tag, err := h.Pool.Exec(c.Context(), `UPDATE users SET password_hash=$2, updated_at=now() WHERE id=$1`, target, string(hash))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if tag.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "user not found")
	}
	return c.JSON(fiber.Map{"id": target, "password_reset": true})
}

// DeactivateUser soft-disables an account (within scope).
func (h *Handlers) DeactivateUser(c *fiber.Ctx) error {
	target := c.Params("id")
	if callerRole(c) != "superadmin" {
		if err := h.requireUserInScope(c, target); err != nil {
			return err
		}
	}
	tag, err := h.Pool.Exec(c.Context(), `UPDATE users SET is_active=FALSE, updated_at=now() WHERE id=$1`, target)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if tag.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "user not found")
	}
	return c.JSON(fiber.Map{"id": target, "deactivated": true})
}

// PurgeUser permanently deletes a user. Dependent rows (enrollments, batch,
// progress, devices, certificates, ...) are removed by the schema's ON DELETE
// CASCADE / SET NULL constraints. Irreversible. Manager/admin only (route-gated).
func (h *Handlers) PurgeUser(c *fiber.Ctx) error {
	target := c.Params("id")
	if callerRole(c) != "superadmin" {
		if err := h.requireUserInScope(c, target); err != nil {
			return err
		}
	}
	// Don't let an admin delete their own account out from under themselves.
	if target == callerID(c) {
		return fiber.NewError(fiber.StatusBadRequest, "you cannot delete your own account")
	}
	tag, err := h.Pool.Exec(c.Context(), `DELETE FROM users WHERE id=$1`, target)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	if tag.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "user not found")
	}
	return c.JSON(fiber.Map{"id": target, "deleted": true})
}

// SetUserBatch assigns (or clears) a student's batch number. Pass batch: null
// or 0 to clear. Manager/admin only (route-gated).
func (h *Handlers) SetUserBatch(c *fiber.Ctx) error {
	target := c.Params("id")
	var req struct {
		Batch *string `json:"batch"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if callerRole(c) != "superadmin" {
		if err := h.requireUserInScope(c, target); err != nil {
			return err
		}
	}
	var batch any
	if req.Batch != nil && strings.TrimSpace(*req.Batch) != "" {
		batch = strings.ToUpper(strings.TrimSpace(*req.Batch)) // batch codes are uppercase
	}
	tag, err := h.Pool.Exec(c.Context(), `UPDATE users SET batch=$2, updated_at=now() WHERE id=$1`, target, batch)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if tag.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "user not found")
	}
	return c.JSON(fiber.Map{"id": target, "batch": batch})
}

// AssignBatch sets (or clears) the batch number for many students at once — the
// "create a batch from the course queue" action: pick the queued students and
// stamp them with a batch number. Pass batch: null/0 to clear. Manager/admin only.
func (h *Handlers) AssignBatch(c *fiber.Ctx) error {
	var req struct {
		UserIDs []string `json:"user_ids"`
		Batch   *string  `json:"batch"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	if len(req.UserIDs) == 0 {
		return fiber.NewError(fiber.StatusBadRequest, "user_ids is required")
	}
	if callerRole(c) != "superadmin" {
		for _, id := range req.UserIDs {
			if err := h.requireUserInScope(c, id); err != nil {
				return err
			}
		}
	}
	var batch any
	if req.Batch != nil && strings.TrimSpace(*req.Batch) != "" {
		batch = strings.ToUpper(strings.TrimSpace(*req.Batch)) // batch codes are uppercase
	}
	tag, err := h.Pool.Exec(c.Context(),
		`UPDATE users SET batch=$2, updated_at=now() WHERE id = ANY($1::uuid[])`, req.UserIDs, batch)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	return c.JSON(fiber.Map{"updated": tag.RowsAffected(), "batch": batch})
}

// AutoBatch auto-allocates students into batches: it splits the given students
// into chunks of `size` and stamps each chunk with the next sequential batch
// number (starting one past the highest batch in use). This is the "auto" mode of
// batch allocation; AssignBatch is the "manual" mode (one explicit number).
func (h *Handlers) AutoBatch(c *fiber.Ctx) error {
	return fiber.NewError(fiber.StatusGone, "auto batch numbering has been removed — assign a batch code instead")
}

// ConvertedLeads lists every converted lead from converted_leads_backup with its
// course_id / course_title and whether it already has a student account, so the
// admin can see who converted per course (grouped by course_id on the client) and
// who still needs provisioning. Manager/admin only (route-gated).
func (h *Handlers) ConvertedLeads(c *fiber.Ctx) error {
	// The converted course is recorded a few ways: the top-level course_id column,
	// or inside the record jsonb as custom_fields.converted_course_title, or the
	// older program/campaign tag. We resolve a human title from those, match it to
	// an LMS course by title or label to get the canonical Course ID (label), and
	// group by that.
	rows, err := h.Pool.Query(c.Context(), `
		SELECT b.lead_id::text, COALESCE(b.name,''), COALESCE(b.phone,''), COALESCE(b.email,''),
		       COALESCE(b.status,''), b.score,
		       COALESCE(NULLIF(trim(b.course_id),''), crs.label, '') AS course_id,
		       COALESCE(NULLIF(trim(b.course_title),''), crs.title, ct.raw, '') AS course_title,
		       b.converted_at,
		       EXISTS (SELECT 1 FROM users u WHERE u.role='student' AND (
		            (b.email IS NOT NULL AND b.email <> '' AND lower(u.email)=lower(trim(b.email)))
		         OR (u.username = regexp_replace(COALESCE(b.phone,''), '\D', '', 'g'))
		       )) AS provisioned,
		       COALESCE(pw.temp_password,'') AS temp_password
		FROM converted_leads_backup b
		LEFT JOIN LATERAL (
		  SELECT COALESCE(
		           NULLIF(b.record->'custom_fields'->>'converted_course_title',''),
		           NULLIF(b.record->>'program',''),
		           NULLIF(b.campaign,'')
		         ) AS raw
		) ct ON true
		LEFT JOIN LATERAL (
		  SELECT pl.temp_password FROM provisioning_log pl JOIN users u2 ON u2.id=pl.user_id
		  WHERE (b.email IS NOT NULL AND b.email <> '' AND lower(u2.email)=lower(trim(b.email)))
		     OR (u2.username = regexp_replace(COALESCE(b.phone,''), '\D', '', 'g'))
		  ORDER BY pl.created_at DESC LIMIT 1
		) pw ON true
		LEFT JOIN LATERAL (
		  SELECT c.label, c.title FROM courses c
		  WHERE c.id::text = NULLIF(b.record->'custom_fields'->>'converted_course_id','')
		     OR lower(c.title) = lower(COALESCE(NULLIF(trim(b.course_title),''), ct.raw, b.record->'custom_fields'->>'converted_course_title'))
		     OR lower(c.label) = lower(COALESCE(NULLIF(trim(b.course_id),''), ct.raw))
		  LIMIT 1
		) crs ON true
		ORDER BY lower(COALESCE(NULLIF(trim(b.course_id),''), crs.label, 'zzz')), b.name`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var leadID, name, phone, email, status, courseID, courseTitle, tempPassword string
		var score *int
		var convertedAt *time.Time
		var provisioned bool
		if err := rows.Scan(&leadID, &name, &phone, &email, &status, &score, &courseID, &courseTitle, &convertedAt, &provisioned, &tempPassword); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{
			"lead_id": leadID, "name": name, "phone": phone, "email": email,
			"status": status, "score": score, "course_id": courseID, "course_title": courseTitle,
			"converted_at": convertedAt, "provisioned": provisioned, "temp_password": tempPassword,
		})
	}
	return c.JSON(fiber.Map{"leads": out})
}

// DeleteConvertedLead removes a converted-lead record from converted_leads_backup
// (e.g. test/junk leads, or ones that converted with no course and were never
// enrolled). The auto-provisioning loop reads this table, so deleting the row
// also stops it from being re-provisioned. Any student account already created
// from this lead is left intact — accounts are managed separately under Users.
func (h *Handlers) DeleteConvertedLead(c *fiber.Ctx) error {
	leadID := strings.TrimSpace(c.Params("leadId"))
	if leadID == "" {
		return fiber.NewError(fiber.StatusBadRequest, "lead id required")
	}
	ct, err := h.Pool.Exec(c.Context(), `DELETE FROM converted_leads_backup WHERE lead_id::text = $1`, leadID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "lead not found")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// ConvertedLeadDetail returns the full converted-lead record (every column plus
// the raw `record` jsonb of custom fields) for the detail view, keyed by lead_id.
func (h *Handlers) ConvertedLeadDetail(c *fiber.Ctx) error {
	leadID := strings.TrimSpace(c.Params("leadId"))
	if leadID == "" {
		return fiber.NewError(fiber.StatusBadRequest, "lead id required")
	}
	var (
		name, phone, email, source, campaign, status, owner, courseID, courseTitle, tempPassword string
		score                                                                                    *int
		createdAt, convertedAt                                                                   *time.Time
		provisioned                                                                              bool
		recordRaw                                                                                []byte
	)
	err := h.Pool.QueryRow(c.Context(), `
		SELECT COALESCE(b.name,''), COALESCE(b.phone,''), COALESCE(b.email,''),
		       COALESCE(b.source,''), COALESCE(b.campaign,''), COALESCE(b.status,''),
		       COALESCE(b.owner,''),
		       COALESCE(NULLIF(trim(b.course_id),''),''), COALESCE(NULLIF(trim(b.course_title),''),''),
		       b.score, b.created_at, b.converted_at, b.record,
		       EXISTS (SELECT 1 FROM users u WHERE u.role='student' AND (
		            (b.email IS NOT NULL AND b.email <> '' AND lower(u.email)=lower(trim(b.email)))
		         OR (u.username = regexp_replace(COALESCE(b.phone,''), '\D', '', 'g'))
		       )),
		       COALESCE((SELECT pl.temp_password FROM provisioning_log pl JOIN users u2 ON u2.id=pl.user_id
		         WHERE (b.email IS NOT NULL AND b.email <> '' AND lower(u2.email)=lower(trim(b.email)))
		            OR (u2.username = regexp_replace(COALESCE(b.phone,''), '\D', '', 'g'))
		         ORDER BY pl.created_at DESC LIMIT 1),'')
		  FROM converted_leads_backup b
		 WHERE b.lead_id::text = $1
		 LIMIT 1`, leadID).
		Scan(&name, &phone, &email, &source, &campaign, &status, &owner, &courseID, &courseTitle,
			&score, &createdAt, &convertedAt, &recordRaw, &provisioned, &tempPassword)
	if errors.Is(err, pgx.ErrNoRows) {
		return fiber.NewError(fiber.StatusNotFound, "lead not found")
	}
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "lookup failed")
	}
	var record any
	if len(recordRaw) > 0 {
		_ = json.Unmarshal(recordRaw, &record)
	}
	return c.JSON(fiber.Map{
		"lead_id": leadID, "name": name, "phone": phone, "email": email,
		"source": source, "campaign": campaign, "status": status, "owner": owner,
		"course_id": courseID, "course_title": courseTitle, "score": score,
		"created_at": createdAt, "converted_at": convertedAt,
		"provisioned": provisioned, "temp_password": tempPassword, "record": record,
	})
}

// UserConvertedLead returns the original converted-lead record for a student, so
// an admin can see where the student came from (source, campaign, program, score,
// UTM, etc.). The student is matched back to converted_leads_backup by email or
// by phone digits (the student's username). Returns found:false if no match.
func (h *Handlers) UserConvertedLead(c *fiber.Ctx) error {
	target := c.Params("id")
	if callerRole(c) != "superadmin" {
		if err := h.requireUserInScope(c, target); err != nil {
			return err
		}
	}
	var email string
	var username *string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT email, username FROM users WHERE id=$1`, target,
	).Scan(&email, &username); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fiber.NewError(fiber.StatusNotFound, "user not found")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "lookup failed")
	}
	uname := ""
	if username != nil {
		uname = *username
	}
	var (
		leadID, name, phone, lemail, source, campaign, status, owner string
		score                                                        *int
		createdAt, convertedAt                                       *time.Time
		recordRaw                                                    []byte
	)
	err := h.Pool.QueryRow(c.Context(), `
		SELECT lead_id::text, COALESCE(name,''), COALESCE(phone,''), COALESCE(email,''),
		       COALESCE(source,''), COALESCE(campaign,''), COALESCE(status,''),
		       score, COALESCE(owner,''), created_at, converted_at, record
		  FROM converted_leads_backup
		 WHERE ($1 <> '' AND lower(email)=lower($1))
		    OR ($2 <> '' AND regexp_replace(COALESCE(phone,''),'\D','','g')=$2)
		 ORDER BY converted_at DESC NULLS LAST
		 LIMIT 1`, strings.ToLower(strings.TrimSpace(email)), uname,
	).Scan(&leadID, &name, &phone, &lemail, &source, &campaign, &status,
		&score, &owner, &createdAt, &convertedAt, &recordRaw)
	if errors.Is(err, pgx.ErrNoRows) {
		return c.JSON(fiber.Map{"found": false})
	}
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "lead lookup failed")
	}
	var record any
	if len(recordRaw) > 0 {
		_ = json.Unmarshal(recordRaw, &record)
	}
	return c.JSON(fiber.Map{"found": true, "lead": fiber.Map{
		"lead_id": leadID, "name": name, "phone": phone, "email": lemail,
		"source": source, "campaign": campaign, "status": status, "score": score,
		"owner": owner, "created_at": createdAt, "converted_at": convertedAt,
		"record": record,
	}})
}

// requireUserInScope: superadmin and manager (the LMS admin) manage any user.
// (Kept the scoped-group check available for finer-grained setups.)
func (h *Handlers) requireUserInScope(c *fiber.Ctx, targetUserID string) error {
	if callerRole(c) == "superadmin" || callerRole(c) == "manager" {
		return nil
	}
	if callerRole(c) != "manager" {
		return fiber.NewError(fiber.StatusForbidden, "requires manager role")
	}
	var ok bool
	err := h.Pool.QueryRow(c.Context(), `
		WITH RECURSIVE scope AS (
			SELECT group_id FROM manager_scopes WHERE user_id=$1
			UNION SELECT g.id FROM groups g JOIN scope s ON g.parent_id=s.group_id
		)
		SELECT EXISTS(
			SELECT 1 FROM group_members gm
			WHERE gm.user_id=$2 AND gm.group_id IN (SELECT group_id FROM scope))`,
		callerID(c), targetUserID,
	).Scan(&ok)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "scope check failed")
	}
	if !ok {
		return fiber.NewError(fiber.StatusForbidden, "user is outside your managed scope")
	}
	return nil
}

// ---- Groups (manager+) -----------------------------------------------------

func (h *Handlers) CreateGroup(c *fiber.Ctx) error {
	var req struct {
		Name     string `json:"name"`
		Type     string `json:"type"`
		ParentID string `json:"parent_id"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	if req.Type == "" {
		req.Type = "department"
	}
	// Sub-group: the caller must already have scope over the parent. Top-level:
	// allowed for any manager+ (this route is manager-gated) and auto-scoped below.
	if req.ParentID != "" {
		if err := h.requireGroupScope(c, req.ParentID); err != nil {
			return err
		}
	}
	var parent any
	if req.ParentID != "" {
		parent = req.ParentID
	}
	var id string
	err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO groups (name, type, parent_id) VALUES ($1,$2,$3) RETURNING id`,
		req.Name, req.Type, parent,
	).Scan(&id)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	// Auto-scope the creating manager to the new group.
	if callerRole(c) == "manager" {
		_, _ = h.Pool.Exec(c.Context(),
			`INSERT INTO manager_scopes (user_id, group_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`,
			callerID(c), id)
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "name": req.Name})
}

func (h *Handlers) AddGroupMember(c *fiber.Ctx) error {
	groupID := c.Params("id")
	if err := h.requireGroupScope(c, groupID); err != nil {
		return err
	}
	var req struct {
		UserID string `json:"user_id"`
		Leader bool   `json:"leader"`
	}
	if err := c.BodyParser(&req); err != nil || req.UserID == "" {
		return fiber.NewError(fiber.StatusBadRequest, "user_id required")
	}
	role := "member"
	if req.Leader {
		role = "leader"
	}
	_, err := h.Pool.Exec(c.Context(),
		`INSERT INTO group_members (group_id, user_id, role_in_group) VALUES ($1,$2,$3)
		 ON CONFLICT (group_id, user_id) DO UPDATE SET role_in_group=EXCLUDED.role_in_group`,
		groupID, req.UserID, role)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "add failed")
	}
	return c.JSON(fiber.Map{"group_id": groupID, "user_id": req.UserID, "role_in_group": role})
}

// BatchEnrollGroup enrolls every member of a group into a course (e.g. enroll a
// whole department/cohort at once).
func (h *Handlers) BatchEnrollGroup(c *fiber.Ctx) error {
	groupID := c.Params("id")
	if err := h.requireGroupScope(c, groupID); err != nil {
		return err
	}
	var req struct {
		CourseID string `json:"course_id"`
	}
	if err := c.BodyParser(&req); err != nil || req.CourseID == "" {
		return fiber.NewError(fiber.StatusBadRequest, "course_id required")
	}
	if err := h.canManageCourse(c, req.CourseID); err != nil {
		return err
	}
	tag, err := h.Pool.Exec(c.Context(), `
		INSERT INTO course_enrollments (course_id, user_id, enrolled_by)
		SELECT $1, gm.user_id, $3 FROM group_members gm WHERE gm.group_id=$2
		ON CONFLICT (course_id, user_id) DO NOTHING`,
		req.CourseID, groupID, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "batch enroll failed")
	}
	// Grant video entitlements for the course's video lessons.
	_, _ = h.Pool.Exec(c.Context(), `
		INSERT INTO enrollments (user_id, video_id)
		SELECT gm.user_id, l.video_id
		FROM group_members gm
		JOIN modules m ON m.course_id=$1
		JOIN lessons l ON l.module_id=m.id AND l.video_id IS NOT NULL
		WHERE gm.group_id=$2
		ON CONFLICT DO NOTHING`, req.CourseID, groupID)
	return c.JSON(fiber.Map{"course_id": req.CourseID, "newly_enrolled": tag.RowsAffected()})
}
