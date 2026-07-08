-- Retry the admin access fix, matching the account by ANY identifier it might be
-- stored under (email, username, or the "LMS ADMIN" display name) rather than an
-- exact email — so it is promoted to a full manager with no time-boxed access
-- and is recognized as staff on every live gate. A superadmin is never touched.
UPDATE users
SET role = CASE WHEN role = 'superadmin' THEN role ELSE 'manager' END,
    access_expires_at = NULL
WHERE lower(email)    LIKE 'admin@onrol.%'
   OR lower(username) LIKE 'admin@onrol.%'
   OR lower(username) = 'admin'
   OR lower(full_name) = 'lms admin';
