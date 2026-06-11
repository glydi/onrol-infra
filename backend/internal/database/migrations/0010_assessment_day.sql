-- Daily plan: tie each quiz/assignment to a course "day" (Day 1, 2, 3 …) so
-- self-paced batches get a day-by-day schedule independent of calendar dates.
ALTER TABLE assessments ADD COLUMN IF NOT EXISTS day_number INTEGER;
CREATE INDEX IF NOT EXISTS idx_assess_course_day ON assessments(course_id, day_number);
