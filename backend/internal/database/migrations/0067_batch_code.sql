-- Batches are now identified by a free-text code (e.g. "AIG 01 07 26") instead
-- of a plain integer, so every batch column becomes TEXT.
ALTER TABLE users           ALTER COLUMN batch        TYPE TEXT USING NULLIF(batch::text,'');
ALTER TABLE announcements   ALTER COLUMN batch_number TYPE TEXT USING NULLIF(batch_number::text,'');
ALTER TABLE calendar_events ALTER COLUMN batch_number TYPE TEXT USING NULLIF(batch_number::text,'');
ALTER TABLE forum_servers   ALTER COLUMN batch_number TYPE TEXT USING NULLIF(batch_number::text,'');
