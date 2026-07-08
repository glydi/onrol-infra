-- Access fix: guarantee the platform admin login is a full manager with no
-- time-boxed access, so the API recognizes it as staff on every gate (hosting a
-- live room, managing courses). The middleware loads the role fresh from the DB
-- each request, so correcting the row here takes effect immediately — no
-- re-login needed. A superadmin is left untouched (never downgrade one).
UPDATE users
SET role = 'manager',
    access_expires_at = NULL
WHERE lower(email) = 'admin@onrol.in'
  AND role <> 'superadmin';

-- Staff accounts are never time-boxed (access_expires_at is only for
-- converted-lead students); clear any stray expiry so a host is never blocked.
UPDATE users
SET access_expires_at = NULL
WHERE role IN ('manager', 'superadmin', 'instructor', 'live_host')
  AND access_expires_at IS NOT NULL;
