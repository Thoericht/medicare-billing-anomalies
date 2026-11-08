-- 06_exports.sql
-- Purpose: export three small, aggregated tables for the Power BI page 2.
-- Run from the project root AFTER 03_metrics.sql and 05_sensitivity.sql:
--     python 02_scripts\run_sql.py 03_sql\06_exports.sql
-- Output (05_output): sensitivity_summary.csv, top_service_codes.csv, z_histogram.csv
-- Privacy: only counts per threshold, per service code (peer groups of at least
-- min_group_size providers) and per bin. No pseudonyms, no NPI, no state.

-- 1) Sensitivity: number of flagged providers per threshold (from 05_sensitivity.sql).
CREATE OR REPLACE TABLE sensitivity_summary AS
SELECT
    CAST(thr AS DOUBLE)                      AS threshold,
    CAST(thr AS VARCHAR)                     AS threshold_label,
    COUNT(*)                                 AS providers,
    COUNT(*) FILTER (WHERE score >= 1)       AS score_1_or_more,
    COUNT(*) FILTER (WHERE score >= 2)       AS score_2_or_more,
    COUNT(*) FILTER (WHERE score = 3)        AS score_3
FROM sensitivity_scores
GROUP BY thr
ORDER BY thr;

-- 2) Service codes with the highest share of flagged lines (metrics 1 and 2 only,
--    because metric 3 is calculated per provider, not per code).
--    One row = one peer group = service code x place of service (F = facility, O = office).
--    Only groups with at least 5 flagged lines are listed, top 25 by share.
--    Note for the README: codes billed per unit (minutes, material) can stand out only
--    because of the billing unit. Check the description before interpreting a code.
CREATE OR REPLACE TABLE top_service_codes AS
WITH code_text AS (
    SELECT CAST(hcpcs_code AS VARCHAR) AS hcpcs_code, MIN(hcpcs_description) AS hcpcs_description
    FROM provider_service
    GROUP BY CAST(hcpcs_code AS VARCHAR)
),
per_group AS (
    SELECT
        CAST(r.hcpcs_code AS VARCHAR)                                      AS hcpcs_code,
        r.place_of_service,
        COUNT(DISTINCT r.pseudonym)                                        AS providers_in_group,
        COUNT(*)                                                           AS service_lines,
        COUNT(*) FILTER (WHERE COALESCE(r.flag_services, 0) = 1)           AS flagged_services,
        COUNT(*) FILTER (WHERE COALESCE(r.flag_charge, 0) = 1)             AS flagged_charge,
        COUNT(*) FILTER (WHERE COALESCE(r.flag_services, 0) = 1
                            OR COALESCE(r.flag_charge, 0) = 1)             AS flagged_either
    FROM row_flags AS r
    GROUP BY CAST(r.hcpcs_code AS VARCHAR), r.place_of_service
)
SELECT
    g.hcpcs_code,
    t.hcpcs_description,
    g.place_of_service,
    g.providers_in_group,
    g.service_lines,
    g.flagged_either,
    ROUND(100.0 * g.flagged_services / g.service_lines, 1) AS pct_flagged_services,
    ROUND(100.0 * g.flagged_charge   / g.service_lines, 1) AS pct_flagged_charge,
    ROUND(100.0 * g.flagged_either   / g.service_lines, 1) AS pct_flagged_either
FROM per_group AS g
JOIN code_text AS t ON t.hcpcs_code = g.hcpcs_code
WHERE g.flagged_either >= 5
ORDER BY pct_flagged_either DESC
LIMIT 25;

-- 3) Histogram of the robust z-values of all service lines (bin width 0.5).
--    The first bin (-5) means "-5 or lower", the last bin (10) means "10 or higher".
--    In Power BI add a constant line at 3.5 (the standard threshold).
CREATE OR REPLACE TABLE z_histogram AS
SELECT
    'Services per beneficiary' AS metric,
    GREATEST(-5.0, LEAST(10.0, floor(z_services * 2) / 2)) AS bin_start,
    COUNT(*) AS row_count
FROM row_flags
WHERE z_services IS NOT NULL
GROUP BY 2
UNION ALL
SELECT
    'Charge to paid ratio',
    GREATEST(-5.0, LEAST(10.0, floor(z_charge * 2) / 2)),
    COUNT(*)
FROM row_flags
WHERE z_charge IS NOT NULL
GROUP BY 2
ORDER BY 1, 2;

-- 4) Export to CSV for Power BI.
COPY sensitivity_summary TO '05_output/sensitivity_summary.csv' (HEADER);
COPY top_service_codes   TO '05_output/top_service_codes.csv'   (HEADER);
COPY z_histogram         TO '05_output/z_histogram.csv'         (HEADER);

-- 5) Quick look before you build the visuals.
SELECT hcpcs_code, hcpcs_description, place_of_service, providers_in_group, pct_flagged_either
FROM top_service_codes
ORDER BY pct_flagged_either DESC
LIMIT 10;