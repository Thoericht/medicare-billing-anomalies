-- 01_condense.sql
-- Purpose: read the downloaded CMS CSV, keep only the columns needed for the
--          analysis, replace the NPI with a random pseudonym right away, add two
--          simple per-row metrics, and save a compact copy.
-- Run from the project root folder (paths below are relative to it).
-- DuckDB-specific: read_csv(), COPY ... TO ... (FORMAT PARQUET), SELECT * EXCLUDE.
--
-- Source: CMS "Medicare Physician & Other Practitioners - by Provider and Service".
-- One row = one provider (NPI) x one service code (HCPCS) x one place of service.
-- Not individual claims.

-- 1) Load the raw CSV into a table (adjust the file name if your download date differs).
--    Dropped on purpose: city, ZIP code, credentials, country, FIPS code, RUCA
--    description and the Medicare participation indicator (not needed; less
--    identifiable information is safer).
CREATE OR REPLACE TABLE provider_service AS
SELECT
    Rndrng_NPI                    AS npi,              -- provider ID, replaced in step 3
    Rndrng_Prvdr_Ent_Cd           AS entity_type,      -- I = individual, O = organization
    Rndrng_Prvdr_State_Abrvtn     AS state,
    Rndrng_Prvdr_RUCA             AS ruca_code,        -- rural/urban classification
    Rndrng_Prvdr_Type             AS specialty,
    HCPCS_Cd                      AS hcpcs_code,
    HCPCS_Desc                    AS hcpcs_description,
    HCPCS_Drug_Ind                AS drug_indicator,
    Place_Of_Srvc                 AS place_of_service,
    Tot_Benes                     AS total_beneficiaries,
    Tot_Srvcs                     AS total_services,
    Avg_Sbmtd_Chrg                AS avg_submitted_charge,
    Avg_Mdcr_Alowd_Amt            AS avg_allowed_amount,
    Avg_Mdcr_Pymt_Amt             AS avg_paid_amount
FROM read_csv('01_data/medicare_general_surgery_2026-11-07.csv', header = true)
WHERE Rndrng_Prvdr_Type = 'General Surgery';           -- change here for another specialty

-- 2) Pseudonym mapping NPI -> pseudonym (LOCAL ONLY, never upload or publish).
--    The numbers are assigned in random order, NOT derived from the NPI, so they
--    cannot be calculated back. The mapping is created once and kept: re-running
--    this file keeps existing pseudonyms and only adds new ones for new NPIs.
CREATE TABLE IF NOT EXISTS pseudonym_map AS
SELECT
    npi,
    CAST(NULL AS INTEGER) AS pseudonym_no,
    CAST(NULL AS VARCHAR) AS pseudonym
FROM provider_service
WHERE false;

INSERT INTO pseudonym_map
WITH distinct_npis AS (
    SELECT DISTINCT npi
    FROM provider_service
    WHERE npi NOT IN (SELECT npi FROM pseudonym_map)
),
new_npis AS (
    -- DuckDB does not allow random() inside the window ORDER BY,
    -- so the random value is created here as a normal column first.
    SELECT npi, random() AS random_value
    FROM distinct_npis
),
numbered AS (
    SELECT
        npi,
        (SELECT COALESCE(MAX(pseudonym_no), 0) FROM pseudonym_map)
            + row_number() OVER (ORDER BY random_value) AS pseudonym_no
    FROM new_npis
)
SELECT
    npi,
    pseudonym_no,
    'Provider A-' || lpad(CAST(pseudonym_no AS VARCHAR), 6, '0')
FROM numbered;

-- Local backup of the mapping (the file name is covered by .gitignore: pseudonym_mapping*).
COPY pseudonym_map TO '01_data/pseudonym_mapping.csv' (HEADER);

-- 3) Replace the NPI with the pseudonym and add simple per-row metrics
--    (used later in 03_metrics.sql).
--    services_per_beneficiary: how often one patient receives this service.
--    charge_to_paid_ratio:     submitted charge divided by what Medicare paid.
--    Beneficiaries are NOT added up across service codes (the same patient
--    can appear under several codes).
CREATE OR REPLACE TABLE provider_service AS
SELECT
    m.pseudonym,
    p.* EXCLUDE (npi),
    p.total_services * 1.0 / NULLIF(p.total_beneficiaries, 0)  AS services_per_beneficiary,
    p.avg_submitted_charge / NULLIF(p.avg_paid_amount, 0)      AS charge_to_paid_ratio
FROM provider_service AS p
JOIN pseudonym_map AS m ON m.npi = p.npi;

-- 4) Save a compact local copy without NPI (Parquet is much faster to read than the CSV).
--    Keep it local: *.parquet is in .gitignore.
COPY provider_service TO '01_data/provider_service.parquet' (FORMAT PARQUET);

-- 5) Quick sanity checks (look at the results, they also belong in the README).
SELECT
    COUNT(*)                   AS row_count,
    COUNT(DISTINCT pseudonym)  AS provider_count,
    COUNT(DISTINCT hcpcs_code) AS service_code_count,
    COUNT(DISTINCT state)      AS state_count
FROM provider_service;

-- Rows with missing or zero values in the key columns (should be few or none).
SELECT
    COUNT(*) FILTER (WHERE total_beneficiaries IS NULL OR total_beneficiaries = 0) AS no_beneficiaries,
    COUNT(*) FILTER (WHERE avg_paid_amount IS NULL OR avg_paid_amount = 0)         AS no_paid_amount,
    COUNT(*) FILTER (WHERE state IS NULL)                                          AS no_state
FROM provider_service;