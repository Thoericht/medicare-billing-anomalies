-- 05_sensitivity.sql
-- Purpose: show how much the results depend on the flag threshold.
-- Run from the project root: python 02_scripts\run_sql.py 03_sql\05_sensitivity.sql
-- Input:   row_flags, visit_level_flags, provider_metrics, params (from 03_metrics.sql)
-- It does not change any existing table. The new table sensitivity_scores holds
-- pseudonyms and scores for three thresholds: keep it local, do not export it.
-- Only min_comparable_rows and min_flagged_share are taken from params;
-- the threshold itself is varied here (3.0 = looser, 3.5 = base case, 5.0 = stricter).

CREATE OR REPLACE TABLE sensitivity_scores AS
WITH scenarios AS (
    SELECT * FROM (VALUES (3.0), (3.5), (5.0)) AS t(thr)
),
row_agg AS (
    SELECT
        s.thr,
        r.pseudonym,
        COUNT(r.z_services)                                  AS comparable_services,
        COUNT(*) FILTER (WHERE r.z_services > s.thr)         AS flagged_services,
        COUNT(r.z_charge)                                    AS comparable_charge,
        COUNT(*) FILTER (WHERE r.z_charge > s.thr)           AS flagged_charge
    FROM row_flags AS r
    CROSS JOIN scenarios AS s
    GROUP BY s.thr, r.pseudonym
),
provider_flags AS (
    SELECT
        s.thr,
        p.pseudonym,
        CASE WHEN COALESCE(a.comparable_services, 0) >= (SELECT min_comparable_rows FROM params)
              AND a.flagged_services * 1.0 / a.comparable_services >= (SELECT min_flagged_share FROM params)
             THEN 1 ELSE 0 END AS flag_services,
        CASE WHEN COALESCE(a.comparable_charge, 0) >= (SELECT min_comparable_rows FROM params)
              AND a.flagged_charge * 1.0 / a.comparable_charge >= (SELECT min_flagged_share FROM params)
             THEN 1 ELSE 0 END AS flag_charge,
        CASE WHEN v.z_level > s.thr THEN 1 ELSE 0 END AS flag_level
    FROM provider_metrics AS p
    CROSS JOIN scenarios AS s
    LEFT JOIN row_agg AS a ON a.pseudonym = p.pseudonym AND a.thr = s.thr
    LEFT JOIN visit_level_flags AS v ON v.pseudonym = p.pseudonym
)
SELECT
    thr,
    pseudonym,
    flag_services,
    flag_charge,
    flag_level,
    flag_services + flag_charge + flag_level AS score
FROM provider_flags;

-- 1) How many providers are flagged at each threshold (per metric and by score).
SELECT
    thr                                             AS threshold,
    COUNT(*)                                        AS providers,
    SUM(flag_services)                              AS flagged_services,
    SUM(flag_charge)                                AS flagged_charge,
    SUM(flag_level)                                 AS flagged_level,
    COUNT(*) FILTER (WHERE score >= 1)              AS score_1_or_more,
    COUNT(*) FILTER (WHERE score >= 2)              AS score_2_or_more,
    COUNT(*) FILTER (WHERE score = 3)               AS score_3,
    ROUND(100.0 * COUNT(*) FILTER (WHERE score >= 1) / COUNT(*), 2) AS pct_score_1_or_more,
    ROUND(100.0 * COUNT(*) FILTER (WHERE score >= 2) / COUNT(*), 2) AS pct_score_2_or_more
FROM sensitivity_scores
GROUP BY thr
ORDER BY thr;

-- 2) Stability of the core group (score 2 or more): how many of the providers
--    flagged in the base case (3.5) are still flagged with the stricter threshold (5.0),
--    and how many of them were already flagged with the looser one (3.0)?
SELECT
    COUNT(*) FILTER (WHERE base.score >= 2)                        AS core_at_3_5,
    COUNT(*) FILTER (WHERE base.score >= 2 AND strict.score >= 2)  AS of_those_still_core_at_5_0,
    COUNT(*) FILTER (WHERE strict.score >= 2)                      AS core_at_5_0,
    COUNT(*) FILTER (WHERE loose.score >= 2)                       AS core_at_3_0,
    COUNT(*) FILTER (WHERE base.score >= 2 AND loose.score >= 2)   AS of_those_also_core_at_3_0
FROM (SELECT pseudonym, score FROM sensitivity_scores WHERE thr = 3.5) AS base
JOIN (SELECT pseudonym, score FROM sensitivity_scores WHERE thr = 5.0) AS strict
  ON strict.pseudonym = base.pseudonym
JOIN (SELECT pseudonym, score FROM sensitivity_scores WHERE thr = 3.0) AS loose
  ON loose.pseudonym = base.pseudonym;