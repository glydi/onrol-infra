-- Calendar events get a type so admins can mark WHAT it is (batch start, live
-- class, exam, holiday, deadline, orientation, meeting…) instead of a generic
-- "event". The set of types is defined in the app; the DB just stores the key.
ALTER TABLE calendar_events ADD COLUMN IF NOT EXISTS event_type TEXT NOT NULL DEFAULT 'general';
