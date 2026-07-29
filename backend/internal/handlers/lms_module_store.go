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

// ListStoreModules lists every store module with its lesson count + folder.
func (h *Handlers) ListStoreModules(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT ms.id, ms.code, ms.title, COALESCE(ms.folder_id::text,''),
		        (SELECT count(*) FROM module_store_lessons l WHERE l.store_module_id=ms.id) AS lessons
		   FROM module_store ms ORDER BY ms.code`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, code, title, folderID string
		var lessons int
		if err := rows.Scan(&id, &code, &title, &folderID, &lessons); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "code": code, "title": title, "folder_id": folderID, "lessons": lessons})
	}
	return c.JSON(fiber.Map{"modules": out})
}

// ---- Module-store folders --------------------------------------------------

func (h *Handlers) ListModuleFolders(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT f.id, f.name, (SELECT count(*) FROM module_store m WHERE m.folder_id=f.id) AS modules
		   FROM module_folders f ORDER BY lower(f.name)`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name string
		var count int
		if err := rows.Scan(&id, &name, &count); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "name": name, "modules": count})
	}
	return c.JSON(fiber.Map{"folders": out})
}

func (h *Handlers) CreateModuleFolder(c *fiber.Ctx) error {
	var req struct {
		Name string `json:"name"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(), `INSERT INTO module_folders (name) VALUES ($1) RETURNING id`, strings.TrimSpace(req.Name)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "name": strings.TrimSpace(req.Name)})
}

func (h *Handlers) RenameModuleFolder(c *fiber.Ctx) error {
	var req struct {
		Name string `json:"name"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	ct, err := h.Pool.Exec(c.Context(), `UPDATE module_folders SET name=$2 WHERE id=$1`, c.Params("id"), strings.TrimSpace(req.Name))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "rename failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "not found")
	}
	return c.JSON(fiber.Map{"ok": true})
}

func (h *Handlers) DeleteModuleFolder(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM module_folders WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"ok": true})
}

// MoveStoreModule moves a store module into a folder ("" = unfile it).
func (h *Handlers) MoveStoreModule(c *fiber.Ctx) error {
	var req struct {
		FolderID string `json:"folder_id"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "bad request")
	}
	var folder any
	if f := strings.TrimSpace(req.FolderID); f != "" {
		folder = f
	}
	ct, err := h.Pool.Exec(c.Context(), `UPDATE module_store SET folder_id=$2 WHERE id=$1`, c.Params("id"), folder)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "move failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "not found")
	}
	return c.JSON(fiber.Map{"ok": true})
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

// MoveStoreLesson swaps a store lesson's position with its neighbour (manual
// ordering — up/down), so the store module keeps the order the admin sets.
func (h *Handlers) MoveStoreLesson(c *fiber.Ctx) error {
	id := c.Params("id")
	var req struct {
		Dir string `json:"dir"` // "up" | "down"
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "bad request")
	}
	var storeID string
	var pos int
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT store_module_id::text, position FROM module_store_lessons WHERE id=$1`, id).Scan(&storeID, &pos); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "lesson not found")
	}
	op, order := "<", "DESC"
	if req.Dir == "down" {
		op, order = ">", "ASC"
	}
	var nid string
	var npos int
	err := h.Pool.QueryRow(c.Context(),
		`SELECT id::text, position FROM module_store_lessons
		 WHERE store_module_id=$1 AND position `+op+` $2 ORDER BY position `+order+` LIMIT 1`,
		storeID, pos).Scan(&nid, &npos)
	if err != nil {
		return c.JSON(fiber.Map{"ok": true}) // already at the edge — no-op
	}
	tx, terr := h.Pool.Begin(c.Context())
	if terr != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "tx failed")
	}
	defer tx.Rollback(c.Context())
	_, _ = tx.Exec(c.Context(), `UPDATE module_store_lessons SET position=$2 WHERE id=$1`, id, npos)
	_, _ = tx.Exec(c.Context(), `UPDATE module_store_lessons SET position=$2 WHERE id=$1`, nid, pos)
	if err := tx.Commit(c.Context()); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "commit failed")
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
