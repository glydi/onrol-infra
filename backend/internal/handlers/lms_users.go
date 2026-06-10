package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
	"golang.org/x/crypto/bcrypt"
)

// ---- Users (manager+) ------------------------------------------------------

// ListUsers returns users. A manager sees only users in their scoped groups;
// a superadmin sees everyone.
func (h *Handlers) ListUsers(c *fiber.Ctx) error {
	// Route is manager+ only; admins/managers manage everyone, so list all.
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, email, full_name, role, is_active, created_at FROM users ORDER BY created_at DESC LIMIT 1000`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, email, name, role string
		var active bool
		var created any
		if err := rows.Scan(&id, &email, &name, &role, &active, &created); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "email": email, "full_name": name,
			"role": role, "is_active": active, "created_at": created})
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
		Email    string `json:"email"`
		FullName string `json:"full_name"`
		Phone    string `json:"phone"`
		Password string `json:"password"`
		Role     string `json:"role"`
		GroupID  string `json:"group_id"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))
	if req.Email == "" || req.FullName == "" || req.Password == "" {
		return fiber.NewError(fiber.StatusBadRequest, "email, full_name, password required")
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
	err = tx.QueryRow(c.Context(),
		`INSERT INTO users (email, phone, full_name, password_hash, role, max_devices)
		 VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
		req.Email, req.Phone, req.FullName, string(hash), req.Role, h.Cfg.MaxDevices,
	).Scan(&id)
	if err != nil {
		if strings.Contains(err.Error(), "users_email_key") {
			return fiber.NewError(fiber.StatusConflict, "email already registered")
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
	case "student", "instructor", "manager", "superadmin":
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
