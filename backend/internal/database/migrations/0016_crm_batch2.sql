-- CRM batch 2 (ported from onrol-crm): automation, surveys, reviews, calendar,
-- newsfeed, support tickets, webhooks, affiliates + commissions.

-- Automation: when a lead enters trigger_status, after delay_hours run action.
CREATE TABLE IF NOT EXISTS automation_rules (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name          TEXT NOT NULL,
    trigger_status TEXT NOT NULL,
    action        TEXT NOT NULL DEFAULT 'create_task',
    action_value  TEXT NOT NULL DEFAULT '',
    delay_hours   INTEGER NOT NULL DEFAULT 0,
    enabled       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT automation_rules_action_check CHECK (action IN ('create_task','log_note'))
);

-- Surveys + responses (public intake like forms).
CREATE TABLE IF NOT EXISTS surveys (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug        TEXT NOT NULL UNIQUE,
    title       TEXT NOT NULL,
    questions   JSONB NOT NULL DEFAULT '[]'::jsonb,
    enabled     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS survey_responses (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    survey_id   UUID NOT NULL REFERENCES surveys(id) ON DELETE CASCADE,
    answers     JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS survey_responses_survey_idx ON survey_responses (survey_id, created_at DESC);

-- Reviews / testimonials.
CREATE TABLE IF NOT EXISTS reviews (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    author      TEXT NOT NULL DEFAULT '',
    rating      INTEGER NOT NULL DEFAULT 5,
    body        TEXT NOT NULL DEFAULT '',
    status      TEXT NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT reviews_status_check CHECK (status IN ('pending','approved','hidden')),
    CONSTRAINT reviews_rating_check CHECK (rating BETWEEN 1 AND 5)
);

-- Calendar events (CRM-wide).
CREATE TABLE IF NOT EXISTS crm_events (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title       TEXT NOT NULL,
    starts_at   TIMESTAMPTZ NOT NULL,
    kind        TEXT NOT NULL DEFAULT 'event',
    notes       TEXT NOT NULL DEFAULT '',
    created_by  UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS crm_events_starts_idx ON crm_events (starts_at);

-- Internal team newsfeed.
CREATE TABLE IF NOT EXISTS feed_posts (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    author_id   UUID REFERENCES users(id) ON DELETE SET NULL,
    body        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS feed_posts_created_idx ON feed_posts (created_at DESC);

-- Support tickets.
CREATE TABLE IF NOT EXISTS tickets (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subject     TEXT NOT NULL,
    body        TEXT NOT NULL DEFAULT '',
    status      TEXT NOT NULL DEFAULT 'open',
    priority    TEXT NOT NULL DEFAULT 'normal',
    lead_id     UUID REFERENCES leads(id) ON DELETE SET NULL,
    created_by  UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT tickets_status_check CHECK (status IN ('open','pending','closed')),
    CONSTRAINT tickets_priority_check CHECK (priority IN ('low','normal','high'))
);
CREATE INDEX IF NOT EXISTS tickets_status_idx ON tickets (status);

-- Outbound webhooks.
CREATE TABLE IF NOT EXISTS webhooks (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    url         TEXT NOT NULL,
    event       TEXT NOT NULL DEFAULT 'lead.created',
    enabled     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Affiliates + commissions.
CREATE TABLE IF NOT EXISTS affiliates (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    email           TEXT NOT NULL DEFAULT '',
    code            TEXT NOT NULL UNIQUE,
    commission_rate NUMERIC(5,2) NOT NULL DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'active',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT affiliates_status_check CHECK (status IN ('active','inactive'))
);
CREATE TABLE IF NOT EXISTS commissions (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    affiliate_id UUID NOT NULL REFERENCES affiliates(id) ON DELETE CASCADE,
    amount       BIGINT NOT NULL DEFAULT 0,
    status       TEXT NOT NULL DEFAULT 'pending',
    note         TEXT NOT NULL DEFAULT '',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT commissions_status_check CHECK (status IN ('pending','paid'))
);
CREATE INDEX IF NOT EXISTS commissions_affiliate_idx ON commissions (affiliate_id);
