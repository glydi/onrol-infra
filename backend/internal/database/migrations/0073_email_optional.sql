-- A student is identified by email OR phone number, so email is no longer
-- mandatory: phone-only accounts log in with their number or their login_id.
-- The UNIQUE constraint stays (it permits multiple NULLs), so emails remain
-- unique when present.
ALTER TABLE users ALTER COLUMN email DROP NOT NULL;
