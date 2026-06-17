-- Records each student account auto-created from a converted lead, including the
-- generated temp password, so an admin can retrieve the login. One row per
-- account; kept until the user is deleted.
CREATE TABLE IF NOT EXISTS provisioning_log (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID REFERENCES users(id) ON DELETE CASCADE,
    full_name     TEXT,
    username      TEXT,
    email         TEXT,
    temp_password TEXT,
    course_label  TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_provlog_user ON provisioning_log(user_id);
