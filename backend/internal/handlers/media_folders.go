package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
)

// ListVideoFolders returns the video-store folders with their video counts.
func (h *Handlers) ListVideoFolders(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT f.id, f.name,
		        (SELECT count(*) FROM media_assets a WHERE a.folder_id=f.id) AS videos
		   FROM video_folders f ORDER BY lower(f.name)`)
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
		out = append(out, fiber.Map{"id": id, "name": name, "videos": count})
	}
	return c.JSON(fiber.Map{"folders": out})
}

// CreateVideoFolder makes a new folder.
func (h *Handlers) CreateVideoFolder(c *fiber.Ctx) error {
	var req struct {
		Name string `json:"name"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO video_folders (name) VALUES ($1) RETURNING id`, strings.TrimSpace(req.Name)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id, "name": strings.TrimSpace(req.Name)})
}

// RenameVideoFolder renames a folder.
func (h *Handlers) RenameVideoFolder(c *fiber.Ctx) error {
	var req struct {
		Name string `json:"name"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "name required")
	}
	ct, err := h.Pool.Exec(c.Context(), `UPDATE video_folders SET name=$2 WHERE id=$1`, c.Params("id"), strings.TrimSpace(req.Name))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "rename failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "not found")
	}
	return c.JSON(fiber.Map{"ok": true})
}

// DeleteVideoFolder removes a folder; its videos become unfiled (folder_id NULL).
func (h *Handlers) DeleteVideoFolder(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM video_folders WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"ok": true})
}

// MoveVideo moves a video into a folder (folder_id empty = unfile it).
func (h *Handlers) MoveVideo(c *fiber.Ctx) error {
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
	ct, err := h.Pool.Exec(c.Context(), `UPDATE media_assets SET folder_id=$2 WHERE id=$1`, c.Params("id"), folder)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "move failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "not found")
	}
	return c.JSON(fiber.Map{"ok": true})
}
