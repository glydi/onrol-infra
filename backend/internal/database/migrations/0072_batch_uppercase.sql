-- Batch codes are uppercase now (e.g. "AIG 01 07 26"). Normalize existing
-- codes so newly-created uppercase codes bucket together with old cohorts
-- instead of fragmenting (e.g. "aig 01 07 26" vs "AIG 01 07 26").
UPDATE users SET batch = upper(batch)
WHERE batch IS NOT NULL AND batch <> upper(batch);
