-- A live class can target a specific student batch (batch_number = the batch
-- code, e.g. "AIG 01 07 26 AA"). NULL means it is for the whole course (every
-- batch). Students only see/join a session whose batch is NULL or matches their
-- own users.batch; staff see and control all of them.
ALTER TABLE class_sessions ADD COLUMN IF NOT EXISTS batch_number TEXT;
CREATE INDEX IF NOT EXISTS idx_class_sessions_batch ON class_sessions(course_id, batch_number);
