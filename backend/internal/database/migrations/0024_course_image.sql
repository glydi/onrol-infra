-- Courses can have a cover image set by an admin: either an uploaded picture
-- (stored as a data URI, like avatars) or a pasted image URL. One TEXT column
-- holds either form so an <img src> works directly.
ALTER TABLE courses ADD COLUMN IF NOT EXISTS image_url TEXT;
