-- The only videos in the system were tests (a couple of raw uploads + one
-- transcoded movie). Remove them from the courses and the video store. This is
-- a one-time cleanup (migrations apply once), so real videos added later are
-- unaffected. Orphaned R2 objects remain in the bucket — clear those from the
-- Cloudflare R2 console if you want the storage back.
DELETE FROM lessons WHERE type = 'video';
DELETE FROM media_assets;
DELETE FROM videos;
