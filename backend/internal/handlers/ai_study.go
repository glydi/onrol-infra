package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"
)

// groqChatURL is Groq's OpenAI-compatible chat-completions endpoint. We call it
// over plain HTTP (Groq has no Go SDK and is OpenAI-compatible) to draft Study
// Hub material. Manual creation is unaffected — this only adds drafts.
const groqChatURL = "https://api.groq.com/openai/v1/chat/completions"

// studyGenResult mirrors the JSON object we ask Groq to return. Only the
// requested keys are populated.
type studyGenResult struct {
	Guides []struct {
		Title  string   `json:"title"`
		Points []string `json:"points"`
	} `json:"guides"`
	Cheats []struct {
		Title string   `json:"title"`
		Items []string `json:"items"`
	} `json:"cheats"`
	Flashcards []struct {
		Q string `json:"q"`
		A string `json:"a"`
	} `json:"flashcards"`
	Formulas []struct {
		Name    string `json:"name"`
		Formula string `json:"formula"`
		Note    string `json:"note"`
	} `json:"formulas"`
	Mindmap struct {
		Center   string `json:"center"`
		Branches []struct {
			Name   string   `json:"name"`
			Leaves []string `json:"leaves"`
		} `json:"branches"`
	} `json:"mindmap"`
}

// GenerateStudyMaterial drafts Study Hub content with Groq and inserts it for the
// instructor to review/edit. Needs GROQ_API_KEY on the server.
func (h *Handlers) GenerateStudyMaterial(c *fiber.Ctx) error {
	key := strings.TrimSpace(h.Cfg.Integrations.GroqAPIKey)
	if key == "" {
		return fiber.NewError(fiber.StatusServiceUnavailable, "AI generation isn't configured (set GROQ_API_KEY on the server)")
	}
	courseID := c.Params("id")
	if err := h.canManageCourse(c, courseID); err != nil {
		return err
	}
	var req struct {
		Topic      string   `json:"topic"`
		Count      int      `json:"count"`
		Kinds      []string `json:"kinds"`
		Difficulty string   `json:"difficulty"`
	}
	if err := c.BodyParser(&req); err != nil || strings.TrimSpace(req.Topic) == "" {
		return fiber.NewError(fiber.StatusBadRequest, "topic required")
	}
	if req.Count < 1 {
		req.Count = 5
	}
	if req.Count > 12 {
		req.Count = 12
	}
	if strings.TrimSpace(req.Difficulty) == "" {
		req.Difficulty = "intermediate"
	}
	// Which kinds to draft — default to all when none specified.
	want := map[string]bool{}
	for _, k := range req.Kinds {
		if k = strings.TrimSpace(k); studyKinds[k] {
			want[k] = true
		}
	}
	if len(want) == 0 {
		for k := range studyKinds {
			want[k] = true
		}
	}

	// Describe only the requested keys in the prompt.
	var parts []string
	if want["guides"] {
		parts = append(parts, fmt.Sprintf(`"guides": [{"title": "topic name", "points": ["concise bullet", "..."]}]  -> %d guides, 4-6 points each`, req.Count))
	}
	if want["cheats"] {
		parts = append(parts, fmt.Sprintf(`"cheats": [{"title": "heading", "items": ["short chip", "..."]}]  -> %d cheat sheets, 4-6 chips each`, req.Count))
	}
	if want["flashcards"] {
		parts = append(parts, fmt.Sprintf(`"flashcards": [{"q": "question", "a": "answer"}]  -> %d flashcards`, req.Count))
	}
	if want["formulas"] {
		parts = append(parts, fmt.Sprintf(`"formulas": [{"name": "name", "formula": "the formula", "note": "what it means"}]  -> %d formulas`, req.Count))
	}
	if want["mindmap"] {
		parts = append(parts, `"mindmap": {"center": "central concept", "branches": [{"name": "branch", "leaves": ["leaf", "..."]}]}  -> 5-6 branches, 3-4 leaves each`)
	}

	system := "You are an expert instructional designer. Produce accurate, concise study material for the given topic and difficulty. " +
		"Respond with a SINGLE valid JSON object and nothing else (no markdown, no prose). Include ONLY the keys requested. Keep every string short and high-signal."
	user := fmt.Sprintf("Topic: %s\nDifficulty: %s\n\nReturn a JSON object with exactly these keys:\n%s\n\nReturn JSON only.",
		strings.TrimSpace(req.Topic), req.Difficulty, strings.Join(parts, "\n"))

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
		log.Printf("study gen: groq: %v", err)
		return fiber.NewError(fiber.StatusBadGateway, "AI request failed — check GROQ_API_KEY / model")
	}
	var out studyGenResult
	if err := json.Unmarshal(raw, &out); err != nil {
		log.Printf("study gen: parse: %v  body=%.300s", err, string(raw))
		return fiber.NewError(fiber.StatusBadGateway, "AI returned an unexpected format — try again")
	}

	added := map[string]int{}
	insert := func(kind, title, bodyTxt, note string, items any) {
		if strings.TrimSpace(title) == "" {
			return
		}
		itemsJSON := "[]"
		if items != nil {
			if b, e := json.Marshal(items); e == nil {
				itemsJSON = string(b)
			}
		}
		var pos int
		_ = h.Pool.QueryRow(c.Context(),
			`SELECT COALESCE(MAX(position),0)+1 FROM study_materials WHERE course_id=$1 AND kind=$2`, courseID, kind).Scan(&pos)
		if _, e := h.Pool.Exec(c.Context(),
			`INSERT INTO study_materials (course_id, kind, title, body, note, items, position) VALUES ($1,$2,$3,$4,$5,$6::jsonb,$7)`,
			courseID, kind, strings.TrimSpace(title), bodyTxt, note, itemsJSON, pos); e == nil {
			added[kind]++
		}
	}

	if want["guides"] {
		for _, g := range out.Guides {
			insert("guides", g.Title, "", "", g.Points)
		}
	}
	if want["cheats"] {
		for _, ch := range out.Cheats {
			insert("cheats", ch.Title, "", "", ch.Items)
		}
	}
	if want["flashcards"] {
		for _, f := range out.Flashcards {
			insert("flashcards", f.Q, f.A, "", nil)
		}
	}
	if want["formulas"] {
		for _, f := range out.Formulas {
			insert("formulas", f.Name, f.Formula, f.Note, nil)
		}
	}
	if want["mindmap"] && strings.TrimSpace(out.Mindmap.Center) != "" {
		branches := []map[string]any{}
		for _, b := range out.Mindmap.Branches {
			branches = append(branches, map[string]any{"name": b.Name, "leaves": b.Leaves})
		}
		insert("mindmap", out.Mindmap.Center, "", "", branches)
	}

	total := 0
	for _, n := range added {
		total += n
	}
	if total == 0 {
		return fiber.NewError(fiber.StatusBadGateway, "AI returned no usable material — try a more specific topic")
	}
	return c.JSON(fiber.Map{"added": added, "total": total})
}

func (h *Handlers) groqModel() string {
	if m := strings.TrimSpace(h.Cfg.Integrations.GroqModel); m != "" {
		return m
	}
	return "llama-3.3-70b-versatile"
}

// groqChat posts a chat-completion request and returns the assistant message
// content (expected to be a JSON object string).
func groqChat(key string, body map[string]any) ([]byte, error) {
	payload, _ := json.Marshal(body)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, groqChatURL, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Authorization", "Bearer "+key)
	httpReq.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("groq status %d: %.300s", resp.StatusCode, string(respBody))
	}
	var parsed struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return nil, fmt.Errorf("decode: %w", err)
	}
	if len(parsed.Choices) == 0 || strings.TrimSpace(parsed.Choices[0].Message.Content) == "" {
		return nil, fmt.Errorf("empty completion")
	}
	return []byte(parsed.Choices[0].Message.Content), nil
}
