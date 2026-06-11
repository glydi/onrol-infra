-- CRM modules (ported from onrol-crm): accounts (companies), deals pipeline,
-- and broadcasts (email/WhatsApp campaigns).

-- Accounts = company records.
CREATE TABLE IF NOT EXISTS accounts (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name          TEXT NOT NULL,
    domain        TEXT,
    industry      TEXT,
    size_band     TEXT,                                  -- 1-10 | 11-50 | 51-200 | 201-1000 | 1000+
    arr_paise     BIGINT NOT NULL DEFAULT 0,
    notes         TEXT NOT NULL DEFAULT '',
    health        TEXT NOT NULL DEFAULT 'unknown',       -- healthy | at_risk | churn_risk | unknown
    owner_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS accounts_name_idx ON accounts (lower(name));

-- Pipelines = named deal flows with an ordered list of stages.
CREATE TABLE IF NOT EXISTS pipelines (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL,
    is_default  BOOLEAN NOT NULL DEFAULT FALSE,
    statuses    JSONB NOT NULL DEFAULT '[]'::jsonb,
    position    INTEGER NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS pipelines_default_idx ON pipelines (is_default) WHERE is_default = TRUE;

-- Seed a default pipeline with sensible stages.
INSERT INTO pipelines (name, is_default, statuses, position)
SELECT 'Sales Pipeline', TRUE,
       '["Qualification","Proposal","Negotiation","Closing"]'::jsonb, 0
WHERE NOT EXISTS (SELECT 1 FROM pipelines WHERE is_default = TRUE);

-- Deals = revenue opportunities, optionally linked to a lead and/or account.
CREATE TABLE IF NOT EXISTS deals (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lead_id             UUID REFERENCES leads(id) ON DELETE SET NULL,
    account_id          UUID REFERENCES accounts(id) ON DELETE SET NULL,
    pipeline_id         UUID REFERENCES pipelines(id) ON DELETE SET NULL,
    title               TEXT NOT NULL,
    value_paise         BIGINT NOT NULL DEFAULT 0,
    currency            TEXT NOT NULL DEFAULT 'INR',
    stage               TEXT NOT NULL DEFAULT 'Qualification',
    probability         INTEGER NOT NULL DEFAULT 50,
    expected_close_date DATE,
    owner_user_id       UUID REFERENCES users(id) ON DELETE SET NULL,
    status              TEXT NOT NULL DEFAULT 'open',
    notes               TEXT NOT NULL DEFAULT '',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT deals_status_check CHECK (status IN ('open','won','lost'))
);
CREATE INDEX IF NOT EXISTS deals_stage_idx ON deals (stage);
CREATE INDEX IF NOT EXISTS deals_status_idx ON deals (status);
CREATE INDEX IF NOT EXISTS deals_account_idx ON deals (account_id);

-- Broadcasts = email/WhatsApp campaigns to a segment.
CREATE TABLE IF NOT EXISTS broadcasts (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name          TEXT NOT NULL,
    channel       TEXT NOT NULL,
    subject       TEXT NOT NULL DEFAULT '',
    body          TEXT NOT NULL DEFAULT '',
    segment       JSONB NOT NULL DEFAULT '{}'::jsonb,
    status        TEXT NOT NULL DEFAULT 'draft',
    scheduled_at  TIMESTAMPTZ,
    sent_at       TIMESTAMPTZ,
    total_targets INTEGER NOT NULL DEFAULT 0,
    total_sent    INTEGER NOT NULL DEFAULT 0,
    created_by    UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT broadcasts_channel_check CHECK (channel IN ('email','whatsapp')),
    CONSTRAINT broadcasts_status_check CHECK (status IN ('draft','scheduled','sending','sent','cancelled'))
);
CREATE INDEX IF NOT EXISTS broadcasts_status_idx ON broadcasts (status);
