-- Host live-controls for simulated-live sessions. The host (course staff) can
-- pause/resume, black-out, mute-all, push a banner, toggle reactions, and start
-- or end the class on demand. Viewers read these off the /state poll they
-- already make, so the controls broadcast to the whole room for free.
--
-- Pause is time-locked-safe: paused_at freezes the effective elapsed; on resume
-- the handler shifts starts_at forward by the paused duration, so the wall-clock
-- position is preserved and reloads still land correctly.
ALTER TABLE class_sessions
	ADD COLUMN IF NOT EXISTS paused_at         timestamptz,
	ADD COLUMN IF NOT EXISTS blank             boolean     NOT NULL DEFAULT false,
	ADD COLUMN IF NOT EXISTS muted             boolean     NOT NULL DEFAULT false,
	ADD COLUMN IF NOT EXISTS banner            text        NOT NULL DEFAULT '',
	ADD COLUMN IF NOT EXISTS reactions_enabled boolean     NOT NULL DEFAULT true,
	ADD COLUMN IF NOT EXISTS manual_ended_at   timestamptz;
