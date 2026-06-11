-- Profile picture for users. Stored as a short string: either a preset id
-- ("p:3") or a small inline data URI ("data:image/jpeg;base64,…") for a
-- user-uploaded photo. NULL/empty = the default letter avatar.
ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar TEXT;
