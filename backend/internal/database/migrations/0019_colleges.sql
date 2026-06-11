-- College Partner portal (#6): partner colleges + their cohorts/intakes,
-- MOU tracking and placement numbers. Managed by admins + employees.

CREATE TABLE IF NOT EXISTS colleges (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name           TEXT NOT NULL,
    contact_person TEXT NOT NULL DEFAULT '',
    email          TEXT NOT NULL DEFAULT '',
    phone          TEXT NOT NULL DEFAULT '',
    city           TEXT NOT NULL DEFAULT '',
    mou_status     TEXT NOT NULL DEFAULT 'none',
    notes          TEXT NOT NULL DEFAULT '',
    status         TEXT NOT NULL DEFAULT 'active',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT colleges_mou_check CHECK (mou_status IN ('none','draft','signed','expired')),
    CONSTRAINT colleges_status_check CHECK (status IN ('active','inactive'))
);
CREATE INDEX IF NOT EXISTS colleges_name_idx ON colleges (lower(name));

-- A cohort/intake a college sends — track student + placement counts.
CREATE TABLE IF NOT EXISTS college_cohorts (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    college_id  UUID NOT NULL REFERENCES colleges(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    year        INTEGER,
    students    INTEGER NOT NULL DEFAULT 0,
    placed      INTEGER NOT NULL DEFAULT 0,
    status      TEXT NOT NULL DEFAULT 'active',
    notes       TEXT NOT NULL DEFAULT '',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT cohorts_status_check CHECK (status IN ('planned','active','completed'))
);
CREATE INDEX IF NOT EXISTS college_cohorts_college_idx ON college_cohorts (college_id, created_at DESC);
