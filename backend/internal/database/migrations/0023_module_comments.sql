-- Per-module comments / doubts: students and course staff discuss inside each
-- module. (Course-level discussion already exists; this is module-scoped.)
CREATE TABLE IF NOT EXISTS module_comments (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    module_id  UUID NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
    user_id    UUID REFERENCES users(id) ON DELETE SET NULL,
    body       TEXT NOT NULL,
    is_doubt   BOOLEAN NOT NULL DEFAULT FALSE,   -- flag a comment as a "doubt"/question
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_module_comments ON module_comments(module_id, created_at);
