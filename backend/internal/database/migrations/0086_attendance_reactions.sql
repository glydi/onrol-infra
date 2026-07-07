-- Richer attendance: track how many reactions each viewer sent (engagement),
-- flushed alongside watch-time. Questions asked are counted live from
-- live_questions, and % of class watched is derived from watched_seconds.
ALTER TABLE live_attendance ADD COLUMN IF NOT EXISTS reactions_sent bigint NOT NULL DEFAULT 0;
