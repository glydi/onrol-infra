-- Per-course discussion / doubts board. Students post doubts/comments;
-- instructors (and peers) reply. parent_id threads a reply under a post.
CREATE TABLE IF NOT EXISTS course_discussion (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id  UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    user_id    UUID REFERENCES users(id) ON DELETE SET NULL,
    parent_id  UUID REFERENCES course_discussion(id) ON DELETE CASCADE,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_discussion_course ON course_discussion(course_id, created_at);
CREATE INDEX IF NOT EXISTS idx_discussion_parent ON course_discussion(parent_id);
