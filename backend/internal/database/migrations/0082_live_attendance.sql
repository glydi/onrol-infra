-- Durable attendance for simulated-live sessions: who watched and for how long.
-- The live viewer count stays in-memory (hot path), but each viewer's watched
-- time is accumulated in memory and flushed here in batches (~45s), so the host
-- can export attendance after the class without per-heartbeat DB writes.
CREATE TABLE IF NOT EXISTS live_attendance (
	session_id      UUID   NOT NULL REFERENCES class_sessions(id) ON DELETE CASCADE,
	user_id         UUID   NOT NULL REFERENCES users(id)          ON DELETE CASCADE,
	first_seen      timestamptz NOT NULL,
	last_seen       timestamptz NOT NULL,
	watched_seconds bigint NOT NULL DEFAULT 0,
	PRIMARY KEY (session_id, user_id)
);
