-- Assignment submissions: a free-text response + an attachment link, stored on
-- the existing submissions row (quizzes leave these empty and use `answers`).
ALTER TABLE submissions ADD COLUMN IF NOT EXISTS body TEXT NOT NULL DEFAULT '';
ALTER TABLE submissions ADD COLUMN IF NOT EXISTS link TEXT NOT NULL DEFAULT '';
