-- Enforce the 2-device cap for non-staff users: clamp any inflated per-user
-- max_devices values down to 2 (staff — instructor/manager/superadmin — stay
-- exempt and keep whatever they have). New users already default to 2.
UPDATE users
   SET max_devices = 2
 WHERE max_devices > 2
   AND role NOT IN ('manager', 'superadmin', 'instructor');
