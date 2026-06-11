-- Student batches: a simple integer batch number per user. Lets admins/instructors
-- divide students into batches (e.g. 1, 2, 3) for scheduling and reporting.
ALTER TABLE users ADD COLUMN IF NOT EXISTS batch INTEGER;
CREATE INDEX IF NOT EXISTS idx_users_batch ON users(batch) WHERE batch IS NOT NULL;
