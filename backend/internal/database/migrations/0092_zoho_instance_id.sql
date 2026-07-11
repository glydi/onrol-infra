-- Zoho Webinar REST API v2 (real live path). The bulk-registration endpoint
--   POST /api/v2/{zsoid}/register/{meetingKey}.json?instanceId=<sysId>
-- needs the webinar's instance id (its "sysId") in addition to the meetingKey.
-- The meetingKey is the same value we already store as embed_session_id
-- (Zoho's regEmbedURL sessionId == meetingKey), so we only add the instance id.
ALTER TABLE webinars ADD COLUMN IF NOT EXISTS zoho_instance_id TEXT;
