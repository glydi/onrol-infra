-- Which Zoho account hosts each webinar, so student join registers against the
-- same account that created it. Empty/'default' = the primary account.
ALTER TABLE webinars ADD COLUMN IF NOT EXISTS zoho_account TEXT NOT NULL DEFAULT 'default';
