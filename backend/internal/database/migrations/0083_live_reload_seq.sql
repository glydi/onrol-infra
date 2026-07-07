-- Host seek for simulated-live: seeking shifts starts_at so the live position
-- jumps for everyone. A live playlist's media-sequence must stay monotonic, so a
-- backward seek would break hls.js mid-stream; instead we bump reload_seq, which
-- the client watches on /state and uses to re-init its player at the new window.
ALTER TABLE class_sessions ADD COLUMN IF NOT EXISTS reload_seq integer NOT NULL DEFAULT 0;
