-- Course content hierarchy is Module > Day > lesson. A lesson can be placed on a
-- day within its module; NULL day means "unscheduled" (shown in a trailing
-- group). Ordering within a module is by day, then position.
ALTER TABLE lessons ADD COLUMN IF NOT EXISTS day_number INT;
CREATE INDEX IF NOT EXISTS idx_lessons_module_day ON lessons(module_id, day_number, position);
