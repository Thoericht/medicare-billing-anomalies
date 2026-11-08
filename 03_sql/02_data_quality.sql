-- 02_data_quality.sql
-- Purpose: check the condensed table before building any metrics.
-- Run from the project root: python 02_scripts\run_sql.py 03_sql\02_data_quality.sql
-- Read every result and write the findings (and what you did about them) into the README.
-- Note: the runner prints only the first 20 rows of each result.

-- 1) Duplicates: one row should be unique per provider x service code x place of service.
--    Expected: 0
SELECT COUNT(*) AS duplicate_keys
FROM (
    SELECT pseudonym, hcpcs_code, place_of_service
    FROM provider_service
    GROUP BY ALL
    HAVING COUNT(*) > 1
);

-- 2) Smallest values in the count columns.
--    CMS may suppress small counts (check the methodology document): if the minimum
--    of total_beneficiaries is e.g. 11, small cells are probably not in the data.
SELECT
    MIN(total_beneficiaries) AS min_beneficiaries,
    MIN(total_services)      AS min_services,
    MIN(avg_paid_amount)     AS min_paid,
    MIN(avg_submitted_charge) AS min_submitted
FROM provider_service;

-- 3) Logical checks (each should be 0 or very small).
--    services below beneficiaries: one patient with less than one service is odd.
--    paid above allowed: Medicare normally pays at most the allowed amount.
SELECT
    COUNT(*) FILTER (WHERE total_services < total_beneficiaries) AS services_below_beneficiaries,
    COUNT(*) FILTER (WHERE avg_paid_amount > avg_allowed_amount) AS paid_above_allowed,
    COUNT(*) FILTER (WHERE avg_submitted_charge < avg_allowed_amount) AS submitted_below_allowed
FROM provider_service;

-- 4) Distribution of the two metrics (shows how skewed they are).
--    Strong skew is the reason for using median/MAD/percentiles instead of mean/std.
SELECT
    'services_per_beneficiary' AS metric,
    MIN(services_per_beneficiary)                    AS min_value,
    quantile_cont(services_per_beneficiary, 0.50)    AS median,
    quantile_cont(services_per_beneficiary, 0.99)    AS p99,
    MAX(services_per_beneficiary)                    AS max_value
FROM provider_service
UNION ALL
SELECT
    'charge_to_paid_ratio',
    MIN(charge_to_paid_ratio),
    quantile_cont(charge_to_paid_ratio, 0.50),
    quantile_cont(charge_to_paid_ratio, 0.99),
    MAX(charge_to_paid_ratio)
FROM provider_service;

-- 5) State values: smallest states first. 58 values means more than the 50 states
--    (territories, DC, or special codes) - decide what to keep.
SELECT
    state,
    COUNT(DISTINCT pseudonym) AS provider_count,
    COUNT(*)                  AS row_count
FROM provider_service
GROUP BY state
ORDER BY provider_count ASC;

-- 6) Group sizes per service code: how many codes have too few providers
--    for a fair peer comparison? (20 is a starting value, adjust it.)
SELECT
    COUNT(*)                                    AS service_codes,
    COUNT(*) FILTER (WHERE providers < 20)      AS codes_under_20_providers,
    SUM(row_count) FILTER (WHERE providers < 20) AS rows_in_those_codes,
    SUM(row_count)                              AS rows_total
FROM (
    SELECT
        hcpcs_code,
        COUNT(DISTINCT pseudonym) AS providers,
        COUNT(*)                  AS row_count
    FROM provider_service
    GROUP BY hcpcs_code
);

-- 7) Category columns: which values exist and how often?
SELECT 'entity_type' AS column_name, entity_type AS value, COUNT(*) AS row_count
FROM provider_service GROUP BY entity_type
UNION ALL
SELECT 'drug_indicator', drug_indicator, COUNT(*)
FROM provider_service GROUP BY drug_indicator
UNION ALL
SELECT 'place_of_service', place_of_service, COUNT(*)
FROM provider_service GROUP BY place_of_service
ORDER BY column_name, row_count DESC;