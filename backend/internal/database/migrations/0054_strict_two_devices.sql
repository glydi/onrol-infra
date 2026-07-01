-- Strictly two devices per account for EVERYONE — no exceptions (removes the
-- old test-account "unlimited devices" carve-out). The cap is now hard-coded to
-- 2 in bindDevice; here we normalise existing data to match.

-- 1. Reset max_devices to 2 for all accounts (was 999 for the test accounts).
UPDATE users SET max_devices = 2 WHERE max_devices <> 2;

-- 2. Enforce the cap on data that predates it: keep only each user's two most
--    recently seen active devices; deactivate any beyond that.
WITH ranked AS (
    SELECT id, row_number() OVER (
        PARTITION BY user_id ORDER BY last_seen DESC NULLS LAST, id
    ) AS rn
    FROM devices
    WHERE is_active
)
UPDATE devices d SET is_active = FALSE
FROM ranked r
WHERE d.id = r.id AND r.rn > 2;
