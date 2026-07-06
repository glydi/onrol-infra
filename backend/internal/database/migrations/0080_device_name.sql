-- User-given label for a bound device (e.g. "Ravi's phone"), asked once on
-- new-device login. Shown in the admin device list and the student's profile.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS name TEXT;
