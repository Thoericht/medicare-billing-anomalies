-- 03_metrics.sql
-- Purpose: compare each provider with its peers and flag unusual billing patterns.
-- Run from the project root: python 02_scripts\run_sql.py 03_sql\03_metrics.sql
-- Input:   provider_service (created by 01_condense.sql, pseudonymized, no NPI)
-- Output:  provider_metrics and state_summary (tables + CSV files in 05_output)
-- Wording: results are "unusual / worth reviewing", never "fraud".
--
-- Method in one sentence: a value is flagged when it is more than 3.5 robust
-- standard deviations above the median of its peer group (modified z-score,
-- based on the median and the MAD instead of mean and standard deviation,
-- because extreme values distort the mean and hide themselves).
--   robust z = 0.6745 * (value - peer median) / MAD
--   MAD      = median of the absolute differences to the peer median
-- If the MAD is 0 (more than half of the values in a group are identical), the usual
-- fallback is used instead: robust z = (value - peer median) / (1.253314 * mean absolute deviation).
-- If that is 0 as well (all values identical), no z-value is computed and nothing is flagged.

-- 0) Parameters in one place (starting values, tune them after looking at the results).
CREATE OR REPLACE TABLE params AS
SELECT
    20   AS min_group_size,            -- minimum providers per peer group (and per state in the map)
    3.5  AS robust_z_threshold,        -- flag when robust z is above this value
    5    AS min_comparable_rows,       -- provider needs this many comparable rows per metric
    0.25 AS min_flagged_share,         -- share of a provider's rows that must be flagged
    30   AS min_visits_for_level_share,-- minimum visit services to compute the visit-level share
    5.0  AS core_z_threshold;          -- stricter threshold that defines the robust core

-- 1) Peer groups: same service code AND same place of service (F = facility, O = office),
--    without drug rows, with at least min_group_size providers.
CREATE OR REPLACE TABLE peer_groups AS
SELECT hcpcs_code, place_of_service, COUNT(DISTINCT pseudonym) AS providers
FROM provider_service
WHERE drug_indicator = 'N'
GROUP BY hcpcs_code, place_of_service
HAVING COUNT(DISTINCT pseudonym) >= (SELECT min_group_size FROM params);

-- 2) Peer statistics per group: median first, then the MAD (median of absolute deviations).
CREATE OR REPLACE TABLE peer_medians AS
SELECT
    s.hcpcs_code,
    s.place_of_service,
    median(s.services_per_beneficiary) AS med_spb,
    median(s.charge_to_paid_ratio)     AS med_ctp
FROM provider_service AS s
JOIN peer_groups AS g
  ON g.hcpcs_code = s.hcpcs_code AND g.place_of_service = s.place_of_service
WHERE s.drug_indicator = 'N'
GROUP BY s.hcpcs_code, s.place_of_service;

CREATE OR REPLACE TABLE peer_stats AS
SELECT
    m.hcpcs_code,
    m.place_of_service,
    m.med_spb,
    m.med_ctp,
    median(abs(s.services_per_beneficiary - m.med_spb)) AS mad_spb,
    median(abs(s.charge_to_paid_ratio - m.med_ctp))     AS mad_ctp,
    avg(abs(s.services_per_beneficiary - m.med_spb))    AS meanad_spb,
    avg(abs(s.charge_to_paid_ratio - m.med_ctp))        AS meanad_ctp
FROM peer_medians AS m
JOIN provider_service AS s
  ON s.hcpcs_code = m.hcpcs_code AND s.place_of_service = m.place_of_service
WHERE s.drug_indicator = 'N'
GROUP BY m.hcpcs_code, m.place_of_service, m.med_spb, m.med_ctp;

-- 3) Row level: robust z per provider x service code x place, and a 0/1 flag.
--    Metric 1: services per beneficiary. Metric 2: submitted charge / paid amount.
--    If the MAD of a group is 0, the mean-absolute-deviation fallback is used (see header).
CREATE OR REPLACE TABLE row_flags AS
WITH z AS (
    SELECT
        s.pseudonym,
        s.state,
        s.hcpcs_code,
        s.place_of_service,
        CASE WHEN p.mad_spb > 0 THEN 0.6745 * (s.services_per_beneficiary - p.med_spb) / p.mad_spb
             WHEN p.meanad_spb > 0 THEN (s.services_per_beneficiary - p.med_spb) / (1.253314 * p.meanad_spb)
        END AS z_services,
        CASE WHEN p.mad_ctp > 0 THEN 0.6745 * (s.charge_to_paid_ratio - p.med_ctp) / p.mad_ctp
             WHEN p.meanad_ctp > 0 THEN (s.charge_to_paid_ratio - p.med_ctp) / (1.253314 * p.meanad_ctp)
        END AS z_charge
    FROM provider_service AS s
    JOIN peer_stats AS p
      ON p.hcpcs_code = s.hcpcs_code AND p.place_of_service = s.place_of_service
    WHERE s.drug_indicator = 'N'
)
SELECT
    *,
    CASE WHEN z_services IS NULL THEN NULL
         WHEN z_services > (SELECT robust_z_threshold FROM params) THEN 1 ELSE 0 END AS flag_services,
    CASE WHEN z_charge IS NULL THEN NULL
         WHEN z_charge > (SELECT robust_z_threshold FROM params) THEN 1 ELSE 0 END AS flag_charge,
    -- same flags with the stricter core threshold (used for robust_core)
    CASE WHEN z_services IS NULL THEN NULL
         WHEN z_services > (SELECT core_z_threshold FROM params) THEN 1 ELSE 0 END AS flag_services_core,
    CASE WHEN z_charge IS NULL THEN NULL
         WHEN z_charge > (SELECT core_z_threshold FROM params) THEN 1 ELSE 0 END AS flag_charge_core
FROM z;

-- 4) Metric 3 (provider level): share of the highest level among established-patient
--    office visits (codes 99212 to 99215: share of 99215). Check the code meanings
--    in the hcpcs_description column before you explain this in the README.
--    Peers = all providers in the data with enough visit services.
CREATE OR REPLACE TABLE visit_level_flags AS
WITH visits AS (
    SELECT
        pseudonym,
        COALESCE(SUM(total_services) FILTER (WHERE CAST(hcpcs_code AS VARCHAR) = '99215'), 0) AS level5_services,
        SUM(total_services) AS visit_services
    FROM provider_service
    WHERE CAST(hcpcs_code AS VARCHAR) IN ('99212', '99213', '99214', '99215')
    GROUP BY pseudonym
    HAVING SUM(total_services) >= (SELECT min_visits_for_level_share FROM params)
),
shares AS (
    SELECT pseudonym, visit_services, level5_services * 1.0 / visit_services AS level5_share
    FROM visits
),
med AS (
    SELECT median(level5_share) AS peer_median FROM shares
),
dev AS (
    SELECT
        median(abs(s.level5_share - m.peer_median)) AS peer_mad,
        avg(abs(s.level5_share - m.peer_median))    AS peer_meanad
    FROM shares AS s CROSS JOIN med AS m
)
SELECT
    s.pseudonym,
    s.visit_services,
    s.level5_share,
    m.peer_median,
    d.peer_mad,
    d.peer_meanad,
    CASE WHEN d.peer_mad > 0 THEN 0.6745 * (s.level5_share - m.peer_median) / d.peer_mad
         WHEN d.peer_meanad > 0 THEN (s.level5_share - m.peer_median) / (1.253314 * d.peer_meanad)
    END AS z_level
FROM shares AS s CROSS JOIN med AS m CROSS JOIN dev AS d;

-- 5) Provider level: how many of the three metrics stand out? (score 0 to 3)
--    Metric 1 and 2 stand out when at least min_flagged_share of the provider's
--    comparable rows are flagged (and there are at least min_comparable_rows of them).
CREATE OR REPLACE TABLE provider_metrics AS
WITH base AS (
    SELECT pseudonym, MAX(state) AS state, COUNT(*) AS rows_total
    FROM provider_service
    GROUP BY pseudonym
),
row_agg AS (
    SELECT
        pseudonym,
        COUNT(flag_services) AS comparable_services,
        SUM(flag_services)   AS flagged_services,
        COUNT(flag_charge)   AS comparable_charge,
        SUM(flag_charge)     AS flagged_charge,
        SUM(flag_services_core) AS flagged_services_core,
        SUM(flag_charge_core)   AS flagged_charge_core
    FROM row_flags
    GROUP BY pseudonym
),
joined AS (
    SELECT
        b.pseudonym,
        b.state,
        b.rows_total,
        COALESCE(r.comparable_services, 0) AS comparable_services,
        COALESCE(r.flagged_services, 0)    AS flagged_services,
        COALESCE(r.comparable_charge, 0)   AS comparable_charge,
        COALESCE(r.flagged_charge, 0)      AS flagged_charge,
        COALESCE(r.flagged_services_core, 0) AS flagged_services_core,
        COALESCE(r.flagged_charge_core, 0)   AS flagged_charge_core,
        v.level5_share,
        v.z_level
    FROM base AS b
    LEFT JOIN row_agg AS r ON r.pseudonym = b.pseudonym
    LEFT JOIN visit_level_flags AS v ON v.pseudonym = b.pseudonym
),
flags AS (
    SELECT
        *,
        CASE WHEN comparable_services >= (SELECT min_comparable_rows FROM params)
              AND flagged_services * 1.0 / comparable_services >= (SELECT min_flagged_share FROM params)
             THEN 1 ELSE 0 END AS flag_services,
        CASE WHEN comparable_charge >= (SELECT min_comparable_rows FROM params)
              AND flagged_charge * 1.0 / comparable_charge >= (SELECT min_flagged_share FROM params)
             THEN 1 ELSE 0 END AS flag_charge,
        CASE WHEN z_level > (SELECT robust_z_threshold FROM params) THEN 1 ELSE 0 END AS flag_level,
        -- the same three flags with the stricter core threshold
        CASE WHEN comparable_services >= (SELECT min_comparable_rows FROM params)
              AND flagged_services_core * 1.0 / comparable_services >= (SELECT min_flagged_share FROM params)
             THEN 1 ELSE 0 END AS flag_services_core,
        CASE WHEN comparable_charge >= (SELECT min_comparable_rows FROM params)
              AND flagged_charge_core * 1.0 / comparable_charge >= (SELECT min_flagged_share FROM params)
             THEN 1 ELSE 0 END AS flag_charge_core,
        CASE WHEN z_level > (SELECT core_z_threshold FROM params) THEN 1 ELSE 0 END AS flag_level_core
    FROM joined
)
SELECT
    pseudonym,
    state,
    rows_total,
    comparable_services,
    flagged_services,
    comparable_charge,
    flagged_charge,
    ROUND(level5_share, 3) AS level5_share,
    ROUND(z_level, 2)      AS z_level,
    flag_services,
    flag_charge,
    flag_level,
    flag_services + flag_charge + flag_level AS score,
    -- robust core: at least 2 of the 3 metrics stand out even with the stricter threshold
    CASE WHEN flag_services_core + flag_charge_core + flag_level_core >= 2 THEN 1 ELSE 0 END AS robust_core,
    -- sensitivity test: the same score and core without the visit-level metric
    flag_services + flag_charge AS score_metrics_1_2,
    CASE WHEN flag_services_core + flag_charge_core = 2 THEN 1 ELSE 0 END AS core_metrics_1_2
FROM flags;

-- 6) State summary for the map. Only states with at least min_group_size providers get
--    a value (small groups could identify single providers). Territories and military
--    codes are left out (AA, AE, AP, MP, VI, GU, PR).
CREATE OR REPLACE TABLE state_summary AS
SELECT
    state,
    COUNT(*) AS providers,
    CASE WHEN COUNT(*) >= (SELECT min_group_size FROM params)
         THEN ROUND(100.0 * COUNT(*) FILTER (WHERE score >= 1) / COUNT(*), 1) END AS pct_score_1_or_more,
    CASE WHEN COUNT(*) >= (SELECT min_group_size FROM params)
         THEN ROUND(100.0 * COUNT(*) FILTER (WHERE score >= 2) / COUNT(*), 1) END AS pct_score_2_or_more
FROM provider_metrics
WHERE state NOT IN ('AA', 'AE', 'AP', 'MP', 'VI', 'GU', 'PR')
GROUP BY state;

-- 7) Export for Power BI (pseudonymized, no NPI). The CSV pattern in .gitignore also
--    blocks these files, add an exception for 05_output if you want to publish them.
COPY provider_metrics TO '05_output/provider_metrics.csv' (HEADER);
COPY state_summary    TO '05_output/state_summary.csv'    (HEADER);

-- 8) Checks: read these before trusting the flags.
-- 8a) Peer groups, and how many have MAD = 0 (no z-value possible there).
SELECT
    COUNT(*)                              AS peer_groups,
    COUNT(*) FILTER (WHERE mad_spb = 0)   AS groups_mad_zero_services,
    COUNT(*) FILTER (WHERE mad_ctp = 0)   AS groups_mad_zero_charge,
    COUNT(*) FILTER (WHERE mad_spb = 0 AND meanad_spb = 0) AS groups_no_spread_services,
    COUNT(*) FILTER (WHERE mad_ctp = 0 AND meanad_ctp = 0) AS groups_no_spread_charge
FROM peer_stats;

-- 8b) Share of rows that are flagged per metric (a few percent is plausible, much more is not).
SELECT
    COUNT(flag_services)                              AS rows_with_z_services,
    ROUND(100.0 * SUM(flag_services) / COUNT(flag_services), 2) AS pct_flagged_services,
    COUNT(flag_charge)                                AS rows_with_z_charge,
    ROUND(100.0 * SUM(flag_charge) / COUNT(flag_charge), 2)     AS pct_flagged_charge
FROM row_flags;

-- 8c) Metric 3: how many providers, and median / MAD of the level-5 share.
SELECT
    COUNT(*)          AS providers_with_visits,
    MAX(peer_median)  AS peer_median_share,
    MAX(peer_mad)     AS peer_mad_share,
    MAX(peer_meanad)  AS peer_meanad_share,
    COUNT(*) FILTER (WHERE z_level > (SELECT robust_z_threshold FROM params)) AS flagged_level
FROM visit_level_flags;

-- 8d) Score distribution across providers.
SELECT score, COUNT(*) AS providers, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM provider_metrics
GROUP BY score
ORDER BY score;

-- 8e) Robust core: how many providers, and are they all within score 2 or more?
--     (Expected from 05_sensitivity.sql: 40 providers, all with score 2 or more.)
SELECT
    COUNT(*) FILTER (WHERE robust_core = 1)                    AS robust_core_providers,
    COUNT(*) FILTER (WHERE robust_core = 1 AND score >= 2)     AS of_those_with_score_2_plus
FROM provider_metrics;

-- 8g) Sensitivity: how much do score and robust core depend on the visit-level metric?
SELECT
    -- providers flagged at least once
    COUNT(*) FILTER (WHERE score >= 1)                                   AS flagged_all_metrics,
    COUNT(*) FILTER (WHERE score_metrics_1_2 >= 1)                       AS flagged_metrics_1_2,
    COUNT(*) FILTER (WHERE score >= 1 AND score_metrics_1_2 = 0)         AS flagged_only_by_visit_level,
    -- providers standing out on at least two metrics (with all three), or on both line-level metrics
    COUNT(*) FILTER (WHERE score >= 2)                                   AS score_2plus_all_metrics,
    COUNT(*) FILTER (WHERE score_metrics_1_2 = 2)                        AS score_2_metrics_1_2,
    -- robust core
    COUNT(*) FILTER (WHERE robust_core = 1)                              AS core_all_metrics,
    COUNT(*) FILTER (WHERE core_metrics_1_2 = 1)                         AS core_metrics_1_2,
    COUNT(*) FILTER (WHERE robust_core = 1 AND core_metrics_1_2 = 1)     AS core_in_both
FROM provider_metrics;