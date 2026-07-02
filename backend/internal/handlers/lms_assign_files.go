package handlers

import (
	"io"
	"strings"

	"github.com/gofiber/fiber/v2"
)

// Assignment file uploads: students attach files to an assignment; the teacher
// downloads them to verify and grade. Stored in Postgres (see migration 0060).

const maxSubmissionFile = 25 << 20 // 25 MB per file

// sanitizeFilename strips characters that would break a Content-Disposition header.
func sanitizeFilename(s string) string {
	s = strings.NewReplacer("\"", "", "\r", "", "\n", "", "\\", "").Replace(s)
	s = strings.TrimSpace(s)
	if s == "" {
		return "file"
	}
	return s
}

// UploadSubmissionFile stores a file a student attaches to an assignment and
// ensures a submission row exists (auto-graded to full marks when auto_award).
func (h *Handlers) UploadSubmissionFile(c *fiber.Ctx) error {
	assessID := c.Params("id")
	var courseID, atype string
	var published, autoAward bool
	var maxScore float64
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT course_id, type, is_published, auto_award, max_score FROM assessments WHERE id=$1`, assessID).
		Scan(&courseID, &atype, &published, &autoAward, &maxScore); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "assessment not found")
	}
	if !published || !h.isEnrolled(c, courseID) {
		return fiber.NewError(fiber.StatusForbidden, "not available")
	}
	if atype != "assignment" {
		return fiber.NewError(fiber.StatusBadRequest, "not an assignment")
	}
	fh, err := c.FormFile("file")
	if err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "no file")
	}
	if fh.Size > maxSubmissionFile {
		return fiber.NewError(fiber.StatusRequestEntityTooLarge, "file too large (max 25 MB)")
	}
	f, err := fh.Open()
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "read failed")
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxSubmissionFile+1))
	if err != nil || len(data) == 0 {
		return fiber.NewError(fiber.StatusBadRequest, "empty file")
	}
	filename := sanitizeFilename(fh.Filename)
	mime := fh.Header.Get("Content-Type")
	var fileID string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO submission_files (assessment_id, user_id, filename, mime, size, data)
		 VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
		assessID, callerID(c), filename, mime, len(data), data).Scan(&fileID); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "store failed")
	}
	// A file counts as a submission.
	status := "submitted"
	var score any
	if autoAward {
		status = "graded"
		score = maxScore
	}
	if _, err := h.Pool.Exec(c.Context(), `
		INSERT INTO submissions (assessment_id, user_id, status, score)
		VALUES ($1,$2,$3,$4)
		ON CONFLICT (assessment_id, user_id)
		DO UPDATE SET submitted_at=now(), status=$3,
		   score = CASE WHEN $3='graded' THEN $4 ELSE submissions.score END`,
		assessID, callerID(c), status, score); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "submit failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": fileID, "filename": filename, "size": len(data)})
}

// ListMySubmissionFiles returns the caller's files for an assignment.
func (h *Handlers) ListMySubmissionFiles(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, filename, size FROM submission_files WHERE assessment_id=$1 AND user_id=$2 ORDER BY created_at`,
		c.Params("id"), callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "load failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, filename string
		var size int
		if err := rows.Scan(&id, &filename, &size); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "filename": filename, "size": size})
	}
	return c.JSON(fiber.Map{"files": out})
}

// DeleteSubmissionFile removes one of the caller's own uploaded files.
func (h *Handlers) DeleteSubmissionFile(c *fiber.Ctx) error {
	ct, err := h.Pool.Exec(c.Context(),
		`DELETE FROM submission_files WHERE id=$1 AND user_id=$2`, c.Params("id"), callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "file not found")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// DownloadSubmissionFile streams a file to its owner (the student) or a manager
// of the course (the grading teacher).
func (h *Handlers) DownloadSubmissionFile(c *fiber.Ctx) error {
	var ownerID, courseID, filename, mime string
	var data []byte
	if err := h.Pool.QueryRow(c.Context(), `
		SELECT sf.user_id::text, a.course_id::text, sf.filename, sf.mime, sf.data
		FROM submission_files sf JOIN assessments a ON a.id=sf.assessment_id WHERE sf.id=$1`, c.Params("id")).
		Scan(&ownerID, &courseID, &filename, &mime, &data); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "file not found")
	}
	if callerID(c) != ownerID {
		if err := h.canManageCourse(c, courseID); err != nil {
			return fiber.NewError(fiber.StatusForbidden, "not allowed")
		}
	}
	if mime == "" {
		mime = "application/octet-stream"
	}
	c.Set("Content-Type", mime)
	c.Set("Content-Disposition", `attachment; filename="`+sanitizeFilename(filename)+`"`)
	return c.Send(data)
}
