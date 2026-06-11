-- Per-document download permission: the admin decides whether a lesson's file
-- (PDF/Word/etc.) may be downloaded by learners, or is view-only. Defaults to
-- downloadable so existing materials keep working.
ALTER TABLE lessons ADD COLUMN IF NOT EXISTS downloadable BOOLEAN NOT NULL DEFAULT TRUE;
