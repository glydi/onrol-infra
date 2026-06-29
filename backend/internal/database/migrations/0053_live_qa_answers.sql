-- Live Q&A becomes the single channel: a student asks a question (private to the
-- host), and the host answers it directly. The answer is stored on the question
-- so the asker sees the reply and the host gets a queue of what's unanswered.
ALTER TABLE live_questions ADD COLUMN IF NOT EXISTS answer      TEXT NOT NULL DEFAULT '';
ALTER TABLE live_questions ADD COLUMN IF NOT EXISTS answered_at TIMESTAMPTZ;
ALTER TABLE live_questions ADD COLUMN IF NOT EXISTS answered_by UUID REFERENCES users(id) ON DELETE SET NULL;
