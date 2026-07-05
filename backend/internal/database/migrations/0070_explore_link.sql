-- A "Know more" link for the Explore tile (course landing page / brochure).
ALTER TABLE courses ADD COLUMN IF NOT EXISTS explore_link TEXT NOT NULL DEFAULT '';
