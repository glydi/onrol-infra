-- Per-webinar Zoho config. The original spec assumed a clean backend->join-link
-- API; the real Zoho artifacts are an embeddable registration widget + a
-- web-to-registration form. We store both per webinar (see ARCHITECTURE.md §4.3).
CREATE TABLE IF NOT EXISTS webinars (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title            TEXT NOT NULL,
    provider         TEXT NOT NULL DEFAULT 'zoho',

    -- Reliable path: embeddable registration widget.
    --   https://webinar.zoho.in/meeting/register/embed?sessionId=<embed_session_id>
    embed_session_id TEXT,

    -- Best-effort path: server-side web-form registration POST.
    webform_url      TEXT,   -- https://webinar.zoho.in/meeting/WebForm
    webform_sys_id   TEXT,   -- hidden "sysId"
    webform_digest   TEXT,   -- hidden "xnQsjsdp"
    webform_enc      TEXT,   -- hidden "xmIwtLD"
    return_url       TEXT,   -- hidden "returnURL"

    starts_at        TIMESTAMPTZ,
    is_active        BOOLEAN NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- webinar_registrations.webinar_key now stores webinars.id (text form). Add a
-- soft FK-style index; we keep the text column to avoid churn on existing rows.
CREATE INDEX IF NOT EXISTS idx_webinar_regs_user ON webinar_registrations(user_id);
