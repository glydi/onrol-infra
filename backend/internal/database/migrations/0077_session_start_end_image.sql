-- Two 16:9 images for a live session, shown IN PLACE OF the video (the 16:9
-- stage): start_image before the class (with the countdown overlaid) and
-- end_image after it ends. Supersedes the single banner_image (0076).
ALTER TABLE class_sessions ADD COLUMN IF NOT EXISTS start_image TEXT;
ALTER TABLE class_sessions ADD COLUMN IF NOT EXISTS end_image TEXT;
UPDATE class_sessions SET start_image = banner_image
 WHERE banner_image IS NOT NULL AND start_image IS NULL;
ALTER TABLE class_sessions DROP COLUMN IF EXISTS banner_image;
