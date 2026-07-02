package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"strings"

	"github.com/gofiber/fiber/v2"
)

// genQuestion mirrors one question object we ask the model to return.
type genQuestion struct {
	Prompt  string   `json:"prompt"`
	Type    string   `json:"type"`
	Options []string `json:"options"`
	Correct string   `json:"correct"`
	Points  float64  `json:"points"`
}

// GenerateQuizQuestions uses Claude to draft questions for an assessment and
// inserts them so they appear in the builder for the instructor to review/edit.
// Needs AI_API_KEY set on the server; otherwise it reports unavailable.
func (h *Handlers) GenerateQuizQuestions(c *fiber.Ctx) error {
	key := strings.TrimSpace(h.Cfg.Integrations.GroqAPIKey)
	if key == "" {
		return fiber.NewError(fiber.StatusServiceUnavailable, "AI question generation isn't configured (set GROQ_API_KEY on the server)")
	}
	assessID := c.Params("id")
	courseID, err := h.assessmentCourse(c, assessID)
	if err != nil {
		return err
	}
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Topic      string `json:"topic"`
		Count      int    `json:"count"`
		Difficulty string `json:"difficulty"`
		Types      string `json:"types"` // optional hint: "mcq" | "mixed" | ...
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Topic) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "topic required")
	}
	if req.Count < 1 {
		req.Count = 5
	}
	if req.Count > 20 {
		req.Count = 20
	}
	if strings.TrimSpace(req.Difficulty) == "" {
		req.Difficulty = "intermediate"
	}
	if strings.TrimSpace(req.Types) == "" {
		req.Types = "a sensible mix of mcq, truefalse, short, and essay"
	}

	// Groq (OpenAI-compatible) in JSON mode → a single JSON object we parse.
	system := "You are an expert instructional designer and assessment author. " +
		"Write clear, unambiguous, well-calibrated questions aligned to the topic and difficulty. " +
		"For mcq give 3-4 plausible options and set correct to the EXACT text of the right option. " +
		"For truefalse use options ['true','false'] and correct 'true' or 'false'. " +
		"For short give a concise expected answer in correct. " +
		"For essay use an empty options array and an empty correct (it's graded manually). " +
		"Respond with a SINGLE valid JSON object and nothing else (no markdown, no prose)."
	user := fmt.Sprintf(
		"Generate %d assessment questions.\nTopic / source material: %s\nDifficulty: %s\nPreferred question types: %s\n\n"+
			"Return a JSON object of exactly this shape:\n"+
			`{"questions":[{"prompt":"...","type":"mcq|truefalse|short|essay","options":["..."],"correct":"...","points":1}]}`+
			"\nReturn JSON only.",
		req.Count, req.Topic, req.Difficulty, req.Types)

	body := map[string]any{
		"model":           h.groqModel(),
		"temperature":     0.4,
		"response_format": map[string]string{"type": "json_object"},
		"messages": []map[string]string{
			{"role": "system", "content": system},
			{"role": "user", "content": user},
		},
	}
	raw, err := groqChat(key, body)
	if err != nil {
		log.Printf("ai quiz: groq: %v", err)
		return fiber.NewError(fiber.StatusBadGateway, "AI request failed — check GROQ_API_KEY / model")
	}
	var out struct {
		Questions []genQuestion `json:"questions"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		log.Printf("ai quiz: parse: %v  body=%.300s", err, string(raw))
		return fiber.NewError(fiber.StatusBadGateway, "AI returned an unexpected format — try again")
	}
	if len(out.Questions) == 0 {
		return fiber.NewError(fiber.StatusBadGateway, "AI returned no questions — try again")
	}

	// Append after any existing questions so they slot in at the end.
	var maxPos int
	_ = h.Pool.QueryRow(c.Context(),
		`SELECT COALESCE(MAX(position),0) FROM questions WHERE assessment_id=$1`, assessID).Scan(&maxPos)

	added := 0
	for i, q := range out.Questions {
		prompt := strings.TrimSpace(q.Prompt)
		if prompt == "" {
			continue
		}
		typ := q.Type
		if typ == "" {
			typ = "mcq"
		}
		pts := q.Points
		if pts == 0 {
			pts = 1
		}
		opts, _ := json.Marshal(q.Options)
		if _, err := h.Pool.Exec(c.Context(),
			`INSERT INTO questions (assessment_id, prompt, type, options, correct, points, position)
			 VALUES ($1,$2,$3,$4,$5,$6,$7)`,
			assessID, prompt, typ, string(opts), q.Correct, pts, maxPos+1+i); err != nil {
			continue
		}
		added++
	}
	return c.JSON(fiber.Map{"added": added})
}
