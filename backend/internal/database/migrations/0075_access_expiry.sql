-- Time-boxed access: a converted-lead student's account is valid only for the
-- number of days recorded on the lead (converted_leads_backup.numberofdays),
-- counted from the conversion date. NULL = no limit (staff, manual accounts, and
-- leads with no day count). Enforced at login and on every request; the
-- auto-provision loop keeps it in sync going forward.
ALTER TABLE users ADD COLUMN IF NOT EXISTS access_expires_at TIMESTAMPTZ;

-- Backfill any already-provisioned students that carry a day count.
UPDATE users u
SET access_expires_at = COALESCE(b.converted_at, u.created_at) + (b.numberofdays || ' days')::interval
FROM converted_leads_backup b
WHERE u.role = 'student'
  AND b.numberofdays IS NOT NULL AND b.numberofdays > 0
  AND ( (u.email <> '' AND lower(u.email) = lower(trim(b.email)))
     OR (u.username = regexp_replace(COALESCE(b.phone,''), '\D', '', 'g')) );
