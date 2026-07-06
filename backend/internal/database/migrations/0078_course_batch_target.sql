-- Auto-push target: when set, new students in this course (arriving unbatched
-- from provisioning or manual entry) are automatically pushed into this batch
-- code. Empty/NULL = keep new students in the queue (no auto-push).
ALTER TABLE courses ADD COLUMN IF NOT EXISTS batch_target TEXT;
