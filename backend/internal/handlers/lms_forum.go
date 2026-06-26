package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
)

func isStaffRole(role string) bool {
	return role == "instructor" || role == "manager" || role == "superadmin"
}

// ---- Read / participate (any authed user) ---------------------------------

// MyForumServers returns the community servers the caller can see, each with its
// channels. Global = everyone; course = enrolled; batch = enrolled + same batch.
// Staff see every server.
func (h *Handlers) MyForumServers(c *fiber.Ctx) error {
	uid := callerID(c)
	staff := isStaffRole(callerRole(c))
	rows, err := h.Pool.Query(c.Context(), `
		SELECT s.id, s.name, s.scope, COALESCE(s.course_id::text,''), s.batch_number,
		       COALESCE(s.icon,''), COALESCE(c.title,'')
		FROM forum_servers s
		LEFT JOIN courses c ON c.id = s.course_id
		WHERE $2 = true
		   OR s.scope='global'
		   OR (s.scope='course' AND EXISTS (SELECT 1 FROM course_enrollments ce WHERE ce.course_id=s.course_id AND ce.user_id=$1))
		   OR (s.scope='batch'  AND EXISTS (SELECT 1 FROM course_enrollments ce WHERE ce.course_id=s.course_id AND ce.user_id=$1)
		        AND EXISTS (SELECT 1 FROM users u WHERE u.id=$1 AND u.batch = s.batch_number))
		ORDER BY (s.scope<>'global'), s.position, s.created_at`, uid, staff)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "load failed")
	}
	defer rows.Close()
	servers := []fiber.Map{}
	ids := []string{}
	byID := map[string]fiber.Map{}
	for rows.Next() {
		var id, name, scope, courseID, icon, course string
		var batch *int
		if err := rows.Scan(&id, &name, &scope, &courseID, &batch, &icon, &course); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		s := fiber.Map{"id": id, "name": name, "scope": scope, "course_id": courseID,
			"batch_number": batch, "icon": icon, "course": course, "channels": []fiber.Map{}}
		servers = append(servers, s)
		byID[id] = s
		ids = append(ids, id)
	}
	if len(ids) > 0 {
		crows, err := h.Pool.Query(c.Context(),
			`SELECT id, server_id, name FROM forum_channels WHERE server_id = ANY($1) ORDER BY position, created_at`, ids)
		if err == nil {
			defer crows.Close()
			for crows.Next() {
				var cid, sid, cname string
				if err := crows.Scan(&cid, &sid, &cname); err != nil {
					continue
				}
				if s, ok := byID[sid]; ok {
					s["channels"] = append(s["channels"].([]fiber.Map), fiber.Map{"id": cid, "name": cname})
				}
			}
		}
	}
	return c.JSON(fiber.Map{"servers": servers})
}

// canSeeForumChannel reports whether the caller may read/post in a channel.
func (h *Handlers) canSeeForumChannel(c *fiber.Ctx, channelID string) (bool, error) {
	uid := callerID(c)
	staff := isStaffRole(callerRole(c))
	var ok bool
	err := h.Pool.QueryRow(c.Context(), `
		SELECT $3 = true
		    OR s.scope='global'
		    OR (s.scope='course' AND EXISTS (SELECT 1 FROM course_enrollments ce WHERE ce.course_id=s.course_id AND ce.user_id=$2))
		    OR (s.scope='batch'  AND EXISTS (SELECT 1 FROM course_enrollments ce WHERE ce.course_id=s.course_id AND ce.user_id=$2)
		         AND EXISTS (SELECT 1 FROM users u WHERE u.id=$2 AND u.batch = s.batch_number))
		FROM forum_channels ch JOIN forum_servers s ON s.id = ch.server_id
		WHERE ch.id=$1`, channelID, uid, staff).Scan(&ok)
	if err != nil {
		return false, fiber.NewError(fiber.StatusNotFound, "channel not found")
	}
	return ok, nil
}

// ForumMessages returns the most recent messages in a channel (oldest first).
func (h *Handlers) ForumMessages(c *fiber.Ctx) error {
	channelID := c.Params("id")
	ok, err := h.canSeeForumChannel(c, channelID)
	if err != nil {
		return err
	}
	if !ok {
		return fiber.NewError(fiber.StatusForbidden, "not a member")
	}
	rows, err := h.Pool.Query(c.Context(), `
		SELECT t.id, t.body, t.created_at, COALESCE(t.user_id::text,''), COALESCE(t.full_name,''), COALESCE(t.avatar,'')
		FROM (
		  SELECT m.id, m.body, m.created_at, m.user_id, u.full_name, u.avatar
		  FROM forum_messages m LEFT JOIN users u ON u.id = m.user_id
		  WHERE m.channel_id=$1 ORDER BY m.created_at DESC LIMIT 200
		) t ORDER BY t.created_at ASC`, channelID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "load failed")
	}
	defer rows.Close()
	me := callerID(c)
	out := []fiber.Map{}
	for rows.Next() {
		var id, body, uid, name, avatar string
		var at any
		if err := rows.Scan(&id, &body, &at, &uid, &name, &avatar); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "body": body, "at": at, "user_id": uid,
			"name": name, "avatar": avatar, "mine": uid == me})
	}
	return c.JSON(fiber.Map{"messages": out})
}

// PostForumMessage adds a message to a channel the caller can see.
func (h *Handlers) PostForumMessage(c *fiber.Ctx) error {
	channelID := c.Params("id")
	ok, err := h.canSeeForumChannel(c, channelID)
	if err != nil {
		return err
	}
	if !ok {
		return fiber.NewError(fiber.StatusForbidden, "not a member")
	}
	var req struct {
		Body string `json:"body"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Body) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "message required")
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO forum_messages (channel_id, user_id, body) VALUES ($1,$2,$3) RETURNING id`,
		channelID, callerID(c), strings.TrimSpace(req.Body)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "send failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

// DeleteForumMessage lets a member delete their own message; staff can delete
// any message (moderation).
func (h *Handlers) DeleteForumMessage(c *fiber.Ctx) error {
	id := c.Params("id")
	q := `DELETE FROM forum_messages WHERE id=$1 AND user_id=$2`
	args := []any{id, callerID(c)}
	if isStaffRole(callerRole(c)) { // staff may remove anyone's message
		q = `DELETE FROM forum_messages WHERE id=$1`
		args = []any{id}
	}
	ct, err := h.Pool.Exec(c.Context(), q, args...)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusForbidden, "not allowed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// ---- Admin: manage servers + channels (staff) ------------------------------

// ListForumServers returns every server with its channels for management.
func (h *Handlers) ListForumServers(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT s.id, s.name, s.scope, COALESCE(s.course_id::text,''), s.batch_number,
		       COALESCE(s.icon,''), COALESCE(c.title,'')
		FROM forum_servers s LEFT JOIN courses c ON c.id=s.course_id
		ORDER BY (s.scope<>'global'), s.position, s.created_at`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "load failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	ids := []string{}
	byID := map[string]fiber.Map{}
	for rows.Next() {
		var id, name, scope, courseID, icon, course string
		var batch *int
		if err := rows.Scan(&id, &name, &scope, &courseID, &batch, &icon, &course); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		s := fiber.Map{"id": id, "name": name, "scope": scope, "course_id": courseID,
			"batch_number": batch, "icon": icon, "course": course, "channels": []fiber.Map{}}
		out = append(out, s)
		byID[id] = s
		ids = append(ids, id)
	}
	if len(ids) > 0 {
		crows, err := h.Pool.Query(c.Context(),
			`SELECT id, server_id, name FROM forum_channels WHERE server_id = ANY($1) ORDER BY position, created_at`, ids)
		if err == nil {
			defer crows.Close()
			for crows.Next() {
				var cid, sid, cname string
				if err := crows.Scan(&cid, &sid, &cname); err != nil {
					continue
				}
				if s, ok := byID[sid]; ok {
					s["channels"] = append(s["channels"].([]fiber.Map), fiber.Map{"id": cid, "name": cname})
				}
			}
		}
	}
	return c.JSON(fiber.Map{"servers": out})
}

// CreateForumServer creates a global/course/batch server + a default #general.
func (h *Handlers) CreateForumServer(c *fiber.Ctx) error {
	var req struct {
		Name        string `json:"name"`
		Scope       string `json:"scope"`
		CourseID    string `json:"course_id"`
		BatchNumber *int   `json:"batch_number"`
		Icon        string `json:"icon"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	req.Scope = strings.TrimSpace(req.Scope)
	switch req.Scope {
	case "global":
		req.CourseID = ""
		req.BatchNumber = nil
	case "course":
		if req.CourseID == "" {
			return fiber.NewError(fiber.StatusBadRequest, "course_id required for a course server")
		}
		req.BatchNumber = nil
	case "batch":
		if req.CourseID == "" || req.BatchNumber == nil {
			return fiber.NewError(fiber.StatusBadRequest, "course_id and batch_number required for a batch server")
		}
	default:
		return fiber.NewError(fiber.StatusBadRequest, "scope must be global, course or batch")
	}
	var courseID any
	if req.CourseID != "" {
		courseID = req.CourseID
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO forum_servers (name, scope, course_id, batch_number, icon)
		 VALUES ($1,$2,$3,$4,$5) RETURNING id`,
		strings.TrimSpace(req.Name), req.Scope, courseID, req.BatchNumber, strings.TrimSpace(req.Icon)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	// Seed a default channel.
	_, _ = h.Pool.Exec(c.Context(),
		`INSERT INTO forum_channels (server_id, name, position) VALUES ($1,'general',0)`, id)
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

// AddForumChannel adds a channel to a server.
func (h *Handlers) AddForumChannel(c *fiber.Ctx) error {
	serverID := c.Params("id")
	var req struct {
		Name string `json:"name"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	// Normalise to a channel-y slug-ish name (lowercase, dashes).
	name := strings.ToLower(strings.TrimSpace(req.Name))
	name = strings.ReplaceAll(name, " ", "-")
	var pos int
	_ = h.Pool.QueryRow(c.Context(), `SELECT COALESCE(MAX(position),0)+1 FROM forum_channels WHERE server_id=$1`, serverID).Scan(&pos)
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO forum_channels (server_id, name, position) VALUES ($1,$2,$3) RETURNING id`,
		serverID, name, pos).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "name": name})
}

// DeleteForumServer removes a server and everything under it.
func (h *Handlers) DeleteForumServer(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM forum_servers WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// DeleteForumChannel removes one channel and its messages.
func (h *Handlers) DeleteForumChannel(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM forum_channels WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}
