-- Assignments/quizzes get an optional Markdown description (instructions shown
-- to the student when they open the assignment).
ALTER TABLE assessments ADD COLUMN IF NOT EXISTS description text NOT NULL DEFAULT '';
