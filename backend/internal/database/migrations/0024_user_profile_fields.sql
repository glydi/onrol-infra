-- Optional public-profile fields a learner can fill in.
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS username   TEXT,
  ADD COLUMN IF NOT EXISTS occupation TEXT,
  ADD COLUMN IF NOT EXISTS location   TEXT,
  ADD COLUMN IF NOT EXISTS linkedin   TEXT,
  ADD COLUMN IF NOT EXISTS github     TEXT;
