-- CRM Finance (invoices + payments) and Forms modules (ported from onrol-crm).
-- Amounts are stored as integer paise (1/100 of the currency unit).

CREATE SEQUENCE IF NOT EXISTS invoice_number_seq START 1001;

CREATE TABLE IF NOT EXISTS invoices (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    number      INTEGER NOT NULL UNIQUE DEFAULT nextval('invoice_number_seq'),
    lead_id     UUID REFERENCES leads(id) ON DELETE SET NULL,
    account_id  UUID REFERENCES accounts(id) ON DELETE SET NULL,
    currency    TEXT NOT NULL DEFAULT 'INR',
    status      TEXT NOT NULL DEFAULT 'draft',
    notes       TEXT NOT NULL DEFAULT '',
    line_items  JSONB NOT NULL DEFAULT '[]'::jsonb,
    subtotal    BIGINT NOT NULL DEFAULT 0,
    tax_rate    NUMERIC(5,2) NOT NULL DEFAULT 0,
    tax_amount  BIGINT NOT NULL DEFAULT 0,
    total       BIGINT NOT NULL DEFAULT 0,
    due_date    DATE,
    sent_at     TIMESTAMPTZ,
    paid_at     TIMESTAMPTZ,
    created_by  UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT invoices_status_check CHECK (status IN ('draft','sent','paid','cancelled'))
);
CREATE INDEX IF NOT EXISTS invoices_status_idx ON invoices (status);
CREATE INDEX IF NOT EXISTS invoices_lead_idx ON invoices (lead_id);

CREATE TABLE IF NOT EXISTS payments (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lead_id             UUID REFERENCES leads(id) ON DELETE SET NULL,
    invoice_id          UUID REFERENCES invoices(id) ON DELETE SET NULL,
    amount              BIGINT NOT NULL,
    currency            TEXT NOT NULL DEFAULT 'INR',
    status              TEXT NOT NULL DEFAULT 'captured',
    provider            TEXT NOT NULL DEFAULT 'manual',
    provider_payment_id TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT payments_status_check CHECK (status IN ('captured','failed','refunded')),
    CONSTRAINT payments_provider_check CHECK (provider IN ('razorpay','manual'))
);
CREATE INDEX IF NOT EXISTS payments_invoice_idx ON payments (invoice_id);

-- Forms: collect leads/data via a hosted form (fields = JSON schema).
CREATE TABLE IF NOT EXISTS forms (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug            TEXT NOT NULL UNIQUE,
    name            TEXT NOT NULL,
    fields          JSONB NOT NULL DEFAULT '[]'::jsonb,
    redirect_url    TEXT NOT NULL DEFAULT '',
    success_message TEXT NOT NULL DEFAULT 'Thanks! We will be in touch shortly.',
    enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS form_submissions (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    form_id     UUID NOT NULL REFERENCES forms(id) ON DELETE CASCADE,
    lead_id     UUID REFERENCES leads(id) ON DELETE SET NULL,
    data        JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS form_submissions_form_idx ON form_submissions (form_id, created_at DESC);
