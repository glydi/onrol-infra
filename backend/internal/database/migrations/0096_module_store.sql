-- Reusable "module store": build a module (with lessons) once under an
-- admin-typed code, then copy it into any course/batch by that code. Copies are
-- independent — editing a store module doesn't change batches that already added
-- it (that copy lives in the normal modules/lessons tables).
CREATE TABLE IF NOT EXISTS module_store (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code       TEXT NOT NULL UNIQUE,           -- admin-typed, e.g. 'AI-01'
    title      TEXT NOT NULL,
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Lessons of a store module (mirrors the shape of the real lessons table so a
-- copy-into-course is a straight field map).
CREATE TABLE IF NOT EXISTS module_store_lessons (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_module_id UUID NOT NULL REFERENCES module_store(id) ON DELETE CASCADE,
    title           TEXT NOT NULL,
    type            TEXT NOT NULL DEFAULT 'text'
                    CHECK (type IN ('video','text','scorm','xapi','link','file')),
    body            TEXT NOT NULL DEFAULT '',   -- text / URL / package ref
    video_id        UUID REFERENCES videos(id) ON DELETE SET NULL,
    day_number      INT,
    downloadable    BOOLEAN NOT NULL DEFAULT TRUE,
    position        INT NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_module_store_lessons_mod ON module_store_lessons(store_module_id);

-- A course module can now target one batch (NULL = shown to every batch, the
-- existing behaviour). Batch-specific modules are how each batch gets its own view.
ALTER TABLE modules ADD COLUMN IF NOT EXISTS batch_number TEXT;
ALTER TABLE modules ADD COLUMN IF NOT EXISTS store_code   TEXT; -- provenance (which store code it was copied from)
CREATE INDEX IF NOT EXISTS idx_modules_course_batch ON modules(course_id, batch_number);
