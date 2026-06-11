-- Franchise Partner portal (#3): partners run a branch/territory, enrol
-- students and earn a revenue share. Admins manage partners + see performance.

CREATE TABLE IF NOT EXISTS franchise_profiles (
    user_id       UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    territory     TEXT NOT NULL DEFAULT '',
    code          TEXT NOT NULL UNIQUE,
    revenue_share NUMERIC(5,2) NOT NULL DEFAULT 0,   -- percent of fee the partner keeps
    status        TEXT NOT NULL DEFAULT 'active',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT franchise_status_check CHECK (status IN ('active','inactive'))
);

-- Students enrolled through a franchise branch (drives revenue + share).
CREATE TABLE IF NOT EXISTS franchise_enrollments (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    franchise_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    student_name  TEXT NOT NULL,
    phone         TEXT NOT NULL DEFAULT '',
    course        TEXT NOT NULL DEFAULT '',
    fee_paise     BIGINT NOT NULL DEFAULT 0,
    status        TEXT NOT NULL DEFAULT 'enrolled',
    notes         TEXT NOT NULL DEFAULT '',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT franchise_enroll_status_check CHECK (status IN ('enrolled','paid','dropped'))
);
CREATE INDEX IF NOT EXISTS franchise_enroll_idx ON franchise_enrollments (franchise_id, created_at DESC);
