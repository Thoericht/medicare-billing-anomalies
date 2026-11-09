# Unusual Billing Patterns in Medicare General Surgery

A portfolio project that looks for statistical outliers in public Medicare billing data. Each provider is compared with its peers, and unusual patterns are flagged in a Power BI dashboard.

**"Flagged" means statistically unusual, not fraud.** Patient mix, specialisation and coding habits can explain differences. The project makes no claims about any provider.

## Question

Which providers bill noticeably differently from peers with the same specialty, and how can this be flagged in a way that is easy to explain?

The project shows SQL, metric design, data quality checks, peer-group comparison with robust statistics, and reporting. It does not show knowledge of Swiss health insurance (KVG/VVG) and does not check single invoices.

## Data

- **Source:** CMS, [Medicare Physician & Other Practitioners - by Provider and Service](https://data.cms.gov) (data.cms.gov)
- **Data year:** 2024
- **Retrieved:** 2026-11-07
- **Specialty:** General Surgery
- **License:** US government work (public domain)
- **Granularity:** one row is one provider (NPI), one service code (HCPCS) and one place of service. These are aggregates, not individual claims.
- **Size:** 122,908 rows, 19,111 providers, 1,376 service codes (after filtering to General Surgery)

The raw data is not part of this repository. Download instructions are below.

## Method

1. **Download and condense.** Only the columns needed are kept. Names and street addresses are dropped when the data is downloaded. City, ZIP code and credentials are dropped when it is loaded.
2. **Pseudonymisation.** The NPI is replaced by a random pseudonym ("Provider A-000123") right after loading. The mapping is created once and stays on the local computer.
3. **Peer groups.** Service lines are compared with providers billing the same code in the same place of service (facility or office), with at least 20 providers per group. Drug codes are excluded. This gives 290 peer groups with 117,627 service lines.
4. **Flag rule.** A value is flagged when it lies more than 3.5 robust standard deviations above the peer median:

   `robust z = 0.6745 × (value − median) ÷ MAD`

   Median and MAD (median absolute deviation) are used instead of mean and standard deviation, because extreme values distort the mean and hide themselves. If the MAD of a group is 0 (more than half of the values are identical), a fallback is used:

   `robust z = (value − median) ÷ (1.253314 × mean absolute deviation)`

   If that is 0 as well, no z-value is computed and nothing is flagged. The fallback is less robust than the MAD, see "Fallback rule" below.
5. **Three metrics.**
   - Services per beneficiary (per service line)
   - Submitted charge divided by paid amount (per service line)
   - Share of the highest level (code 99215) among established-patient office visits (codes 99212 to 99215), per provider, for providers with at least 30 visit services
6. **Provider level.** For the first two metrics, a provider stands out when at least 25 % of its comparable service lines (and at least 5) are flagged. The third metric is compared across all providers.
7. **Score and strict core.** The score is the number of metrics (0 to 3) on which a provider stands out at the standard threshold of 3.5. The **strict core** consists of providers that still stand out on at least two of the three metrics at a stricter threshold of 5.0. In the SQL code this column is called `robust_core`.

## Results

Numbers for General Surgery, data year 2024:

| Group | Providers | Share |
|---|---|---|
| All providers | 19,111 | 100 % |
| Flagged (score 1 or more) | 1,902 | 9.95 % |
| Score 2 or more | 103 | 0.54 % |
| Score 3 | 4 | |
| Strict core | 40 | 0.21 % |

Sensitivity to the threshold:

| Threshold | Score 1 or more | Score 2 or more | Score 3 |
|---|---|---|---|
| 3.0 | 2,328 | 181 | 6 |
| 3.5 (default) | 1,902 | 103 | 4 |
| 5.0 | 1,126 | 40 | 0 |

The size of the flagged group therefore depends on the chosen threshold. It is not an estimate of how many providers bill incorrectly. All 40 providers of the strict core are also in the group with score 2 or more at 3.5.

Sensitivity to the choice of metrics (threshold 3.5, strict core at 5.0):

| | All three metrics | Metrics 1 and 2 only |
|---|---|---|
| Providers with score 1 or more | 1,902 | 1,148 |
| Providers with score 2 or more | 103 | 29 |
| Strict core | 40 | 9 |

For "metrics 1 and 2 only", the strict core means standing out on both service-line metrics at the threshold of 5.0. 754 of the 1,902 flagged providers (about 40 %) stand out only on the visit-level metric. Of the 40 providers in the strict core, 9 remain without it. The strict core is therefore stable against the threshold but depends on the choice of metrics. Read it as "stands out on several metrics", not as a validated finding.

### Fallback rule

- In 139 of 290 peer groups the MAD of services per beneficiary is 0 (more than half of the values are identical). In 13 of these, all values are identical, so no z-value is computed (558 service lines, 0.5 %). In the other 126 groups the fallback rule is used. For the charge to paid ratio the MAD is never 0.
- For the visit-level metric, more than half of the providers bill no code 99215, so median and MAD are both 0 and the fallback applies to every provider. With a median of 0 the rule means: a provider is flagged when the share of code 99215 is more than about 30 % of its visits (3.5 × 1.2533 × the average share of 6.9 %). The threshold for the strict core is about 44 %. This is a ratio to the mean, not a robust statistic.

### Other findings

- 4.7 % of service lines are flagged on services per beneficiary, 4.3 % on charge to paid ratio.
- 832 of 9,714 providers with enough visit services stand out on the share of the highest level (8.6 %).
- The 15 service codes with the highest share of flagged lines are a mix of laboratory tests, screening and diagnostic procedures. Most of their peer groups have 20 to 50 providers (two have more than 100), so the shares are unstable. The list shows where the rule is most active, not where billing is most questionable.

## Dashboard

Power BI, three pages:

1. **Overview:** share of flagged providers by state, key numbers, a funnel from all providers to the strict core, and combinations of flagged metrics
2. **Robustness:** distribution of robust z-values, sensitivity to the threshold, service codes with the most flagged lines
3. **Case list and About:** the 40 providers of the strict core (pseudonyms only), method and limits

Screenshots are in `06_dashboard/`. The Power BI file itself is not published because it contains the pseudonyms and states of all providers.

## How to reproduce

Requirements: Python 3 (tested with 3.11), `pip install requests duckdb`

Run all commands from the project root folder:

```powershell
# 1) Download the data (set specialty and dataset ID at the top of the script)
python 02_scripts\download_cms.py

# 2) Run the SQL files in this order
python 02_scripts\run_sql.py 03_sql\01_condense.sql
python 02_scripts\run_sql.py 03_sql\02_data_quality.sql
python 02_scripts\run_sql.py 03_sql\03_metrics.sql
python 02_scripts\run_sql.py 03_sql\04_sensitivity.sql
python 02_scripts\run_sql.py 03_sql\05_exports.sql
```

Notes:

- `01_condense.sql` contains the name of the downloaded CSV file. Adjust it if your download date differs.
- Pseudonyms are drawn randomly on a fresh run of `01_condense.sql`. Counts, shares and flags are the same, only the labels differ. Do not re-run it if you want to keep the labels used in screenshots or local notes.
- SQL uses DuckDB. DuckDB-specific parts (`read_csv`, `COPY ... TO`, `SELECT * EXCLUDE`) are marked in the comments. The rest is close to standard SQL.
- The dashboard (not published) reads CSV files that the SQL scripts write to `05_output/`. `provider_metrics.csv` contains one pseudonymised row per provider and stays on the local computer. When importing into Power BI, set the locale to English (United States), otherwise decimal points are read wrongly.

## Runtimes

Measured with PowerShell `Measure-Command` on the already filtered General Surgery file (122,908 rows), including Python start-up:

| Step | Time |
|---|---|
| `01_condense.sql` (load, pseudonymise, metrics per row) | 2.5 s |
| `03_metrics.sql` (peer groups, flags, score, export) | 2.1 s |

Computer: Huawei MateBook D16, 16 GB RAM, Windows.

## Repository structure

```
01_data/        raw data and local database (not published)
02_scripts/     download_cms.py, run_sql.py
03_sql/         01_condense, 02_data_quality, 03_metrics, 04_sensitivity, 05_exports
04_notebooks/   reserved for a possible machine learning comparison (see Possible next steps)
05_output/      CSV files created locally by the SQL scripts. Only the aggregated tables are published, the pseudonymised       provider-level file (provider_metrics.csv) is not.
06_dashboard/   screenshots
```

## Privacy

Names and street addresses are never loaded. National Provider Identifiers are replaced by random pseudonyms, and the mapping stays on the local computer. No single provider is named. The data itself is public, so a pseudonym is no protection against someone who deliberately matches figures with the public CMS file. For this reason the case list shows no state and no exact figures.
The provider-level file with pseudonyms (provider_metrics.csv) is created locally and is not part of this repository. Only aggregated tables without pseudonyms are published.

## Limits

- US Medicare data, not Swiss health insurance (KVG/VVG). The method can be transferred, the results cannot.
- Aggregated data: single invoices cannot be checked, and duplicate invoices cannot be found.
- No patient severity in the data, so a legitimate case mix can look unusual.
- CMS leaves out small counts (the smallest number of beneficiaries in the data is 11), so very small cases are missing.
- No external fraud labels, so there is no hit rate. Flags are statistical outliers, not findings.
- The size of the flagged group depends on the threshold.
- The flagged group and the strict core depend on the choice of metrics. The visit-level metric uses the fallback rule for every provider (a ratio to the mean, not a robust statistic), and the strict core shrinks from 40 to 9 without it.
- In 126 of 290 peer groups the fallback rule replaces the MAD for services per beneficiary. Flags there are less robust and not strictly comparable with flags from groups where the MAD is used.
- Peer groups are partly small (at least 20 providers), and differences between small states are mostly noise.
- The third metric is compared across all providers and does not reflect patient severity.

## Possible next steps

A machine learning comparison would be a natural follow-up project:

- Fit an unsupervised outlier model (for example Isolation Forest or Local Outlier Factor) on provider-level features such as the median services per beneficiary, the median charge to paid ratio, the share of the highest visit level and the number of service codes. Features would be log-transformed or scaled first because the values are strongly skewed.
- Compare the model with the rule-based flags: how many of the highest-ranked providers also have a score of 2 or more, and how strongly the model ranking and the score are correlated.
- Look at the differences between both approaches on an aggregated level, without naming single providers.

An agreement between both approaches would not validate either of them. They use the same data and similar features, and there are no external fraud labels. The rule stays the main result because every flag can be explained in one sentence. A model would serve as a cross-check.

A further option is to replace the visit-level rule with a percentile-based rule, for example above the 95th percentile among providers that bill code 99215 at all, because the current rule is a ratio to the mean.

## Data quality notes

- No duplicate keys (provider × service code × place of service).
- No missing values in beneficiaries, paid amount and state. 80 rows (0.07 %) have a submitted charge below the allowed amount, they were kept.
- The data contains 58 state values: 50 states, D.C., territories and military codes. Territories and military codes (AA, AE, AP, MP, VI, GU, PR) are excluded from the state map.
- Every provider in the data is an individual (entity type "I").