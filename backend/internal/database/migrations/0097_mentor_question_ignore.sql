-- Let a mentor dismiss ("ignore") a student's Ask-Mentor thread from the queue
-- without replying. Flag sits on the student's latest message; a NEW student
-- message (not ignored) re-surfaces the thread in the queue.
ALTER TABLE module_comments ADD COLUMN IF NOT EXISTS ignored BOOLEAN NOT NULL DEFAULT FALSE;
