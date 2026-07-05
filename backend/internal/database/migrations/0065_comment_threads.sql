-- Doubts & module comments become a PRIVATE per-student channel to the mentor.
-- Each comment belongs to a "thread" identified by the student it concerns, so a
-- student sees only their own thread, and a mentor's reply lands in the right
-- student's thread — never visible to peers.
ALTER TABLE module_comments
  ADD COLUMN IF NOT EXISTS thread_user_id UUID REFERENCES users(id) ON DELETE CASCADE;

-- Backfill: every existing comment belongs to its author's own thread.
UPDATE module_comments SET thread_user_id = user_id WHERE thread_user_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_module_comments_thread
  ON module_comments (module_id, thread_user_id, created_at);
