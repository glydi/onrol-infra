-- Admin-managed calendar events. These show up on students' calendars alongside
-- live classes, deadlines and announcements. Audience targets who sees them:
-- everyone, a batch, or a role (mirrors announcements).
CREATE TABLE IF NOT EXISTS calendar_events (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title        TEXT NOT NULL,
    description  TEXT NOT NULL DEFAULT '',
    location     TEXT NOT NULL DEFAULT '',
    starts_at    TIMESTAMPTZ NOT NULL,
    ends_at      TIMESTAMPTZ,
    audience     TEXT NOT NULL DEFAULT 'all' CHECK (audience IN ('all','batch','role')),
    batch_number INT,
    role         TEXT,
    created_by   UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_calendar_events_start ON calendar_events(starts_at);
