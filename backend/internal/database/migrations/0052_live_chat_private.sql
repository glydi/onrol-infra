-- Live chat goes private-to-host: a student's messages are seen only by course
-- staff (the host/admin), not by other students. Staff messages broadcast to
-- everyone. from_staff marks who sent it so the read query can filter.
ALTER TABLE live_chat_messages ADD COLUMN IF NOT EXISTS from_staff BOOLEAN NOT NULL DEFAULT FALSE;
