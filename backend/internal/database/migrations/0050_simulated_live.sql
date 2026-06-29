-- Simulated-live sessions: serve a recorded video from the store as if it were a
-- live class. A session with media_asset_id set is "simulated live" — the API
-- streams a sliding-window HLS playlist computed from (now - starts_at), so it
-- can't be skipped/paused-ahead and resumes at the right wall-clock spot on
-- reload. A NULL media_asset_id keeps the existing external (Zoho/Meet) behavior.
ALTER TABLE class_sessions ADD COLUMN IF NOT EXISTS media_asset_id UUID REFERENCES media_assets(id) ON DELETE SET NULL;
ALTER TABLE class_sessions ADD COLUMN IF NOT EXISTS chat_enabled BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE class_sessions ADD COLUMN IF NOT EXISTS qa_enabled   BOOLEAN NOT NULL DEFAULT TRUE;
-- Seeded baseline headcount: the displayed viewer count never drops below this
-- (a gentle simulated floor so a recorded session feels live and busy).
ALTER TABLE class_sessions ADD COLUMN IF NOT EXISTS viewer_base  INT NOT NULL DEFAULT 0;

-- Total runtime of the asset (seconds), so we know when a simulated session ends
-- and how long the lobby countdown / live window is. Set at transcode time and
-- lazily backfilled the first time a live playlist is parsed.
ALTER TABLE media_assets ADD COLUMN IF NOT EXISTS duration_seconds INT NOT NULL DEFAULT 0;

-- Real-time live chat (polled by the client; no WebSocket infra).
CREATE TABLE IF NOT EXISTS live_chat_messages (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id   UUID NOT NULL REFERENCES class_sessions(id) ON DELETE CASCADE,
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    display_name TEXT NOT NULL DEFAULT '',
    body         TEXT NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_live_chat_session ON live_chat_messages(session_id, created_at);

-- Q&A / raise-hand: viewers submit questions during the session.
CREATE TABLE IF NOT EXISTS live_questions (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id   UUID NOT NULL REFERENCES class_sessions(id) ON DELETE CASCADE,
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    display_name TEXT NOT NULL DEFAULT '',
    body         TEXT NOT NULL,
    answered     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_live_questions_session ON live_questions(session_id, created_at);

-- Presence heartbeats → real concurrent-viewer count.
CREATE TABLE IF NOT EXISTS live_presence (
    session_id UUID NOT NULL REFERENCES class_sessions(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    last_seen  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (session_id, user_id)
);
