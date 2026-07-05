-- Admin-curated "Explore" flag: a course can be shown in the student Explore
-- catalog independently of its publish status (so drafts can be listed too).
ALTER TABLE courses ADD COLUMN IF NOT EXISTS in_explore BOOLEAN NOT NULL DEFAULT false;
