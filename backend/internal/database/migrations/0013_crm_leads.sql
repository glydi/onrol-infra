-- CRM core (ported from onrol-crm): leads pipeline + activities + tasks.
-- First vertical slice of the CRM rewrite into the Go/Flutter stack.

CREATE TABLE IF NOT EXISTS leads (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                TEXT NOT NULL,
    phone               TEXT NOT NULL DEFAULT '',
    email               TEXT NOT NULL DEFAULT '',
    source              TEXT NOT NULL DEFAULT '',
    campaign            TEXT NOT NULL DEFAULT '',
    status              TEXT NOT NULL DEFAULT 'New Lead',
    assigned_counsellor TEXT NOT NULL DEFAULT '',
    score               INTEGER NOT NULL DEFAULT 0,
    notes               TEXT NOT NULL DEFAULT '',
    do_not_contact      BOOLEAN NOT NULL DEFAULT FALSE,
    opt_in_at           TIMESTAMPTZ,
    history             JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT leads_status_check CHECK (status IN (
        'New Lead','Registered','Attended','Not Attended','Interested','Payment Pending','Converted'
    ))
);
CREATE INDEX IF NOT EXISTS leads_status_idx ON leads (status);
CREATE INDEX IF NOT EXISTS leads_assigned_counsellor_idx ON leads (assigned_counsellor);
CREATE INDEX IF NOT EXISTS leads_score_idx ON leads (score DESC);
CREATE INDEX IF NOT EXISTS leads_updated_at_idx ON leads (updated_at DESC);
CREATE INDEX IF NOT EXISTS leads_created_at_idx ON leads (created_at DESC);

CREATE TABLE IF NOT EXISTS lead_activities (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lead_id             UUID NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
    type                TEXT NOT NULL,
    template            TEXT,
    direction           TEXT NOT NULL DEFAULT 'outbound',
    status              TEXT NOT NULL DEFAULT 'logged',
    subject             TEXT NOT NULL DEFAULT '',
    message             TEXT NOT NULL DEFAULT '',
    provider_message_id TEXT,
    created_by          UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT lead_activities_type_check CHECK (type IN ('email','whatsapp','call','note')),
    CONSTRAINT lead_activities_direction_check CHECK (direction IN ('outbound','inbound','internal')),
    CONSTRAINT lead_activities_status_check CHECK (status IN ('sent','logged','failed'))
);
CREATE INDEX IF NOT EXISTS lead_activities_lead_id_idx ON lead_activities (lead_id);
CREATE INDEX IF NOT EXISTS lead_activities_created_at_idx ON lead_activities (created_at DESC);

CREATE TABLE IF NOT EXISTS lead_tasks (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lead_id             UUID NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
    assigned_counsellor TEXT NOT NULL DEFAULT '',
    title               TEXT NOT NULL,
    due_at              TIMESTAMPTZ NOT NULL,
    status              TEXT NOT NULL DEFAULT 'open',
    priority            TEXT NOT NULL DEFAULT 'normal',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT lead_tasks_status_check CHECK (status IN ('open','completed')),
    CONSTRAINT lead_tasks_priority_check CHECK (priority IN ('normal','high'))
);
CREATE INDEX IF NOT EXISTS lead_tasks_due_idx ON lead_tasks (status, due_at);
CREATE INDEX IF NOT EXISTS lead_tasks_lead_id_idx ON lead_tasks (lead_id);
