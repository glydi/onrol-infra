-- Per-user video playback position so "Resume Learning" can pick up exactly
-- where the learner stopped. One row per (user, lesson); updated as they watch.
CREATE TABLE IF NOT EXISTS lesson_playback (
    user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    lesson_id        UUID NOT NULL REFERENCES lessons(id) ON DELETE CASCADE,
    position_seconds INT NOT NULL DEFAULT 0,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, lesson_id)
);
