-- A 16:9 banner image for a live session, shown in the room BEFORE the class
-- starts (under the countdown) and AFTER it ends. Data URI or an image URL;
-- NULL/empty = no banner.
ALTER TABLE class_sessions ADD COLUMN IF NOT EXISTS banner_image TEXT;
