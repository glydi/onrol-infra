package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

// genQuestion mirrors one row of the strict tool schema Claude fills in.
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
	key := strings.TrimSpace(h.Cfg.Integrations.AIAPIKey)
	if key == "" {
		return fiber.NewError(fiber.StatusServiceUnavailable, "AI question generation isn't configured (set AI_API_KEY on the server)")
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

	// Strict tool schema → structured questions, no fragile text parsing.
	tool := anthropic.ToolParam{
		Name:        "emit_questions",
		Description: anthropic.String("Return the generated quiz/assignment questions."),
		Strict:      anthropic.Bool(true),
		InputSchema: anthropic.ToolInputSchemaParam{
			Properties: map[string]any{
				"questions": map[string]any{
					"type":        "array",
					"description": "The generated questions, in order.",
					"items": map[string]any{
						"type":                 "object",
						"additionalProperties": false,
						"required":             []string{"prompt", "type", "options", "correct", "points"},
						"properties": map[string]any{
							"prompt":  map[string]any{"type": "string", "description": "The question text."},
							"type":    map[string]any{"type": "string", "enum": []string{"mcq", "truefalse", "short", "essay"}},
							"options": map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "MCQ choices (3-4). Empty array for truefalse/short/essay."},
							"correct": map[string]any{"type": "string", "description": "mcq: exact text of the right option. truefalse: 'true' or 'false'. short: the expected answer. essay: empty string (graded manually)."},
							"points":  map[string]any{"type": "number", "description": "Points for the question (default 1)."},
						},
					},
				},
			},
			Required:    []string{"questions"},
			ExtraFields: map[string]any{"additionalProperties": false},
		},
	}

	system := "You are an expert instructional designer and assessment author. " +
		"Write clear, unambiguous, well-calibrated questions aligned to the topic and difficulty. " +
		"For mcq give 3-4 plausible options and set correct to the EXACT text of the right option. " +
		"For truefalse use options ['true','false'] and correct 'true' or 'false'. " +
		"For short give a concise expected answer in correct. " +
		"For essay use an empty options array and an empty correct (it's graded manually). " +
		"Always respond by calling the emit_questions tool."
	user := fmt.Sprintf("Generate %d questions for an assessment titled by the instructor.\nTopic / source material: %s\nDifficulty: %s\nPreferred question types: %s",
		req.Count, req.Topic, req.Difficulty, req.Types)

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	client := anthropic.NewClient(option.WithAPIKey(key))
	msg, err := client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:      anthropic.ModelClaudeOpus4_8,
		MaxTokens:  4096,
		System:     []anthropic.TextBlockParam{{Text: system}},
		Tools:      []anthropic.ToolUnionParam{{OfTool: &tool}},
		ToolChoice: anthropic.ToolChoiceParamOfTool("emit_questions"),
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(user)),
		},
	})
	if err != nil {
		log.Printf("ai quiz: messages.new: %v", err)
		return fiber.NewError(fiber.StatusBadGateway, "AI request failed")
	}

	var out struct {
		Questions []genQuestion `json:"questions"`
	}
	for _, block := range msg.Content {
		if tu, ok := block.AsAny().(anthropic.ToolUseBlock); ok {
			if err := json.Unmarshal(tu.Input, &out); err != nil {
				log.Printf("ai quiz: parse tool input: %v", err)
			}
			break
		}
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
