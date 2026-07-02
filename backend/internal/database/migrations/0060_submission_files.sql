-- Assignment file uploads: students attach files to an assignment; stored for
-- the teacher to review. Kept in the DB (included in the offsite backups); capped
-- client+server side. Linked by (assessment_id, user_id) like the submission row.
CREATE TABLE IF NOT EXISTS submission_files (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assessment_id UUID NOT NULL REFERENCES assessments(id) ON DELETE CASCADE,
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    filename      TEXT NOT NULL,
    mime          TEXT NOT NULL DEFAULT '',
    size          INT  NOT NULL DEFAULT 0,
    data          BYTEA NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_submission_files ON submission_files(assessment_id, user_id);

-- Auto-award: an assignment grants full marks automatically on submission (no
-- manual grading). FALSE = teacher verifies and assigns marks.
ALTER TABLE assessments ADD COLUMN IF NOT EXISTS auto_award BOOLEAN NOT NULL DEFAULT FALSE;
