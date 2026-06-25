-- Daily check-ins drive the learning streak: one row per user per LOCAL day they
-- opened the app. Streak = the run of consecutive days up to today.
CREATE TABLE IF NOT EXISTS user_checkins (
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day        DATE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, day)
);
CREATE INDEX IF NOT EXISTS idx_user_checkins ON user_checkins(user_id, day DESC);

-- Seed historical activity from lesson completions so existing learners keep
-- the streak they already earned (UTC dates — close enough for a one-off seed).
INSERT INTO user_checkins (user_id, day)
SELECT DISTINCT user_id, (completed_at AT TIME ZONE 'UTC')::date
FROM lesson_progress
WHERE completed_at IS NOT NULL
ON CONFLICT DO NOTHING;
