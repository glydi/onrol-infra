-- Course-scoped Study Hub material that instructors edit and students read.
-- One flexible row per card across all editable resource kinds:
--   guides      : title = topic,    items = [bullet points]
--   cheats      : title = heading,  items = [quick-reference chips]
--   mindmap     : title = centre,   items = [{"name": branch, "leaves": [..]}]
--   flashcards  : title = question, body  = answer
--   formulas    : title = name,     body  = formula,  note = explanation
CREATE TABLE IF NOT EXISTS study_materials (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id  UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL
               CHECK (kind IN ('guides','cheats','mindmap','flashcards','formulas')),
    title      TEXT NOT NULL DEFAULT '',
    body       TEXT NOT NULL DEFAULT '',
    note       TEXT NOT NULL DEFAULT '',
    items      JSONB NOT NULL DEFAULT '[]',
    position   INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_study_materials_course ON study_materials(course_id, kind, position);
