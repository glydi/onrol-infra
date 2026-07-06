-- Quizzes: every question is worth exactly 1 point, auto-graded, and the result
-- is a PERCENTAGE (0-100) — "use % not points". Assessments are scored out of
-- 100 so a stored score IS the percentage.
--
-- Existing scores must be re-expressed as a percentage BEFORE we flatten the
-- weights, or history would be read against the wrong denominator:
--   * quiz submissions were raw points = sum of the correct questions' points,
--     so divide by the assessment's OLD total question points.
--   * assignment submissions were on the assessment's OWN old max_score scale.

-- 1) Quiz submissions -> percentage (uses OLD per-question points).
UPDATE submissions s
SET score = LEAST(100, GREATEST(0, ROUND(s.score / NULLIF(tp.total, 0) * 100)))
FROM (SELECT assessment_id, SUM(points) AS total FROM questions GROUP BY assessment_id) tp
WHERE s.assessment_id = tp.assessment_id
  AND s.score IS NOT NULL
  AND EXISTS (SELECT 1 FROM assessments a WHERE a.id = s.assessment_id AND a.type = 'quiz');

-- 2) Assignment submissions -> percentage (uses OLD max_score).
UPDATE submissions s
SET score = LEAST(100, GREATEST(0, ROUND(s.score / NULLIF(a.max_score, 0) * 100)))
FROM assessments a
WHERE s.assessment_id = a.id AND a.type = 'assignment' AND s.score IS NOT NULL;

-- 3) Every question is now worth exactly 1 point.
UPDATE questions SET points = 1 WHERE points <> 1;

-- 4) Every assessment is scored out of 100 (i.e. the score is a percentage).
UPDATE assessments SET max_score = 100 WHERE max_score <> 100;
