package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
	"github.com/jackc/pgx/v5"
)

// ---- Module store: reusable modules addable to any course/batch by code ----

// CreateStoreModule creates a store module under an admin-typed unique code.
func (h *Handlers) CreateStoreModule(c *fiber.Ctx) error {
	var req struct {
		Code  string `json:"code"`
		Title string `json:"title"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "bad request")
	}
	code := strings.ToUpper(strings.TrimSpace(req.Code))
	title := strings.TrimSpace(req.Title)
	if code == "" || title == "" {
		return fiber.NewError(fiber.StatusBadRequest, "code and title required")
	}
	var id string
	err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO module_store (code, title, created_by) VALUES ($1,$2,$3) RETURNING id`,
		code, title, callerID(c)).Scan(&id)
	if err != nil {
		if strings.Contains(err.Error(), "duplicate") || strings.Contains(err.Error(), "unique") {
			return fiber.NewError(fiber.StatusConflict, "that module code already exists")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "code": code, "title": title})
}

// ListStoreModules lists every store module with its lesson count.
func (h *Handlers) ListStoreModules(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT ms.id, ms.code, ms.title,
		        (SELECT count(*) FROM module_store_lessons l WHERE l.store_module_id=ms.id) AS lessons
		   FROM module_store ms ORDER BY ms.code`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, code, title string
		var lessons int
		if err := rows.Scan(&id, &code, &title, &lessons); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "code": code, "title": title, "lessons": lessons})
	}
	return c.JSON(fiber.Map{"modules": out})
}

// GetStoreModule returns a store module with its lessons (for editing/preview).
func (h *Handlers) GetStoreModule(c *fiber.Ctx) error {
	id := c.Params("id")
	var code, title string
	if err := h.Pool.QueryRow(c.Context(), `SELECT code, title FROM module_store WHERE id=$1`, id).Scan(&code, &title); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "module not found")
	}
	rows, err := h.Pool.Query(c.Context(),
		`SELECT l.id, l.title, l.type, COALESCE(l.body,''), COALESCE(l.video_id::text,''), l.day_number, l.downloadable, l.position
		   FROM module_store_lessons l WHERE l.store_module_id=$1 ORDER BY l.day_number NULLS LAST, l.position`, id)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "load failed")
	}
	defer rows.Close()
	lessons := []fiber.Map{}
	for rows.Next() {
		var lid, ltitle, ltype, body, vid string
		var day, pos *int
		var downloadable bool
		if err := rows.Scan(&lid, &ltitle, &ltype, &body, &vid, &day, &downloadable, &pos); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		lessons = append(lessons, fiber.Map{"id": lid, "title": ltitle, "type": ltype, "body": body,
			"video_id": vid, "day_number": day, "downloadable": downloadable})
	}
	return c.JSON(fiber.Map{"id": id, "code": code, "title": title, "lessons": lessons})
}

// AddStoreLesson adds a lesson to a store module.
func (h *Handlers) AddStoreLesson(c *fiber.Ctx) error {
	moduleID := c.Params("id")
	var exists bool
	if err := h.Pool.QueryRow(c.Context(), `SELECT true FROM module_store WHERE id=$1`, moduleID).Scan(&exists); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "module not found")
	}
	var req struct {
		Title        string `json:"title"`
		Type         string `json:"type"`
		VideoID      string `json:"video_id"`
		Body         string `json:"body"`
		DayNumber    *int   `json:"day_number"`
		Downloadable *bool  `json:"downloadable"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Title) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "title required")
	}
	if req.Type == "" {
		req.Type = "text"
	}
	var vid any
	if req.VideoID != "" {
		vid = req.VideoID
	}
	downloadable := req.Downloadable == nil || *req.Downloadable
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO module_store_lessons (store_module_id, title, type, video_id, body, day_number, downloadable,
		   position)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,
		   COALESCE((SELECT max(position)+1 FROM module_store_lessons WHERE store_module_id=$1),0))
		 RETURNING id`,
		moduleID, strings.TrimSpace(req.Title), req.Type, vid, req.Body, req.DayNumber, downloadable).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

// DeleteStoreModule removes a store module (and its lessons). Copies already
// added to courses are untouched.
func (h *Handlers) DeleteStoreModule(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM module_store WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"ok": true})
}

// DeleteStoreLesson removes a lesson from a store module.
func (h *Handlers) DeleteStoreLesson(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM module_store_lessons WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"ok": true})
}

// SaveModuleToStore copies an existing COURSE module (and its lessons) INTO the
// module store under a new code, so it can be reused across courses/batches.
func (h *Handlers) SaveModuleToStore(c *fiber.Ctx) error {
	moduleID := c.Params("id")
	var courseID, title string
	if err := h.Pool.QueryRow(c.Context(), `SELECT course_id::text, title FROM modules WHERE id=$1`, moduleID).Scan(&courseID, &title); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "module not found")
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Code string `json:"code"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "bad request")
	}
	code := strings.ToUpper(strings.TrimSpace(req.Code))
	if code == "" {
		return fiber.NewError(fiber.StatusBadRequest, "code required")
	}
	tx, err := h.Pool.Begin(c.Context())
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "tx failed")
	}
	defer tx.Rollback(c.Context())
	var storeID string
	if err := tx.QueryRow(c.Context(),
		`INSERT INTO module_store (code, title, created_by) VALUES ($1,$2,$3) RETURNING id`,
		code, title, callerID(c)).Scan(&storeID); err != nil {
		if strings.Contains(err.Error(), "duplicate") || strings.Contains(err.Error(), "unique") {
			return fiber.NewError(fiber.StatusConflict, "that module code already exists")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	if _, err := tx.Exec(c.Context(),
		`INSERT INTO module_store_lessons (store_module_id, title, type, body, video_id, day_number, downloadable, position)
		 SELECT $1, title, type, COALESCE(body,''), video_id, day_number, COALESCE(downloadable,true), position
		   FROM lessons WHERE module_id=$2`,
		storeID, moduleID); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "lesson copy failed")
	}
	if err := tx.Commit(c.Context()); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "commit failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": storeID, "code": code, "title": title})
}

// AddModuleFromStore copies a store module (by code) into a course as a NEW
// module, optionally scoped to one batch. The copy is independent — later edits
// to the store module don't affect it.
func (h *Handlers) AddModuleFromStore(c *fiber.Ctx) error {
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Code        string `json:"code"`
		BatchNumber string `json:"batch_number"` // "" = all batches
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "bad request")
	}
	code := strings.ToUpper(strings.TrimSpace(req.Code))
	if code == "" {
		return fiber.NewError(fiber.StatusBadRequest, "module code required")
	}
	var storeID, title string
	if err := h.Pool.QueryRow(c.Context(), `SELECT id, title FROM module_store WHERE code=$1`, code).Scan(&storeID, &title); err != nil {
		if err == pgx.ErrNoRows {
			return fiber.NewError(fiber.StatusNotFound, "no module with code "+code)
		}
		return fiber.NewError(fiber.StatusInternalServerError, "lookup failed")
	}
	var batch any
	if b := strings.TrimSpace(req.BatchNumber); b != "" {
		batch = b
	}

	tx, err := h.Pool.Begin(c.Context())
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "tx failed")
	}
	defer tx.Rollback(c.Context())

	var newModID string
	if err := tx.QueryRow(c.Context(),
		`INSERT INTO modules (course_id, title, position, batch_number, store_code)
		 VALUES ($1,$2,COALESCE((SELECT max(position)+1 FROM modules WHERE course_id=$1),0),$3,$4)
		 RETURNING id`,
		courseID, title, batch, code).Scan(&newModID); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "module create failed")
	}
	// Copy every store lesson into the new module.
	if _, err := tx.Exec(c.Context(),
		`INSERT INTO lessons (module_id, title, type, video_id, body, position, downloadable, day_number)
		 SELECT $1, title, type, video_id, body, position, downloadable, day_number
		   FROM module_store_lessons WHERE store_module_id=$2`,
		newModID, storeID); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "lesson copy failed")
	}
	if err := tx.Commit(c.Context()); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "commit failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": newModID, "title": title, "code": code})
}
