"""
Downloads "Medicare Physician & Other Practitioners - by Provider and Service"
via the data.cms.gov API, filtered to one specialty, and saves the rows as a
CSV file (local only, do not commit it to the repository!).

Requires: Python 3, package "requests" (pip install requests)
Run:      python download_cms.py
"""

import csv
import datetime
import os
import time

import requests

# --------------------------------------------------------------- Parameters
# Dataset ID. According to the catalog this ID points to the latest version.
# For a fixed year: on the dataset page click "Access API", choose the year in
# the "Time Period" dropdown and copy the ID from the URL into DATASET_ID.
DATASET_ID = "92396110-2aed-4d63-a6a2-5d6207d46a29"

SPECIALTY = "General Surgery"
SPECIALTY_COLUMN = "Rndrng_Prvdr_Type"   # column name from memory: check in the data dictionary!

# Columns with names/addresses that are dropped right away (only existing ones are removed).
# Names from memory: compare with the real header after the first run!
COLUMNS_TO_DROP = [
    "Rndrng_Prvdr_Last_Org_Name",
    "Rndrng_Prvdr_First_Name",
    "Rndrng_Prvdr_MI",
    "Rndrng_Prvdr_St1",
    "Rndrng_Prvdr_St2",
]

PAGE_SIZE = 5000        # rows per API call
MAX_PAGES = 1000        # safeguard against endless loops
OUTPUT_DIR = "01_data"
# -------------------------------------------------------------------------

BASE_URL = f"https://data.cms.gov/data-api/v1/dataset/92396110-2aed-4d63-a6a2-5d6207d46a29/data"


def fetch_page(offset):
    params = {
        "size": PAGE_SIZE,
        "offset": offset,
        f"filter[{SPECIALTY_COLUMN}]": SPECIALTY,
    }
    for attempt in range(3):
        try:
            response = requests.get(BASE_URL, params=params, timeout=60)
            response.raise_for_status()
            return response.json()
        except requests.RequestException as error:
            print(f"  Error at offset={offset} (attempt {attempt + 1}/3): {error}")
            time.sleep(3)
    raise RuntimeError(f"Aborted: offset={offset} could not be fetched after 3 attempts.")


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    today = datetime.date.today().isoformat()
    filename = os.path.join(
        OUTPUT_DIR, f"medicare_{SPECIALTY.lower().replace(' ', '_')}_{today}.csv"
    )

    offset, total = 0, 0
    with open(filename, "w", newline="", encoding="utf-8") as output:
        writer = None
        for _ in range(MAX_PAGES):
            rows = fetch_page(offset)
            if not rows:
                break

            if writer is None:
                all_columns = list(rows[0].keys())
                print("Columns in the data:")
                print(", ".join(all_columns))
                kept = [c for c in all_columns if c not in COLUMNS_TO_DROP]
                dropped = [c for c in all_columns if c in COLUMNS_TO_DROP]
                print(f"Dropped: {dropped}")
                writer = csv.DictWriter(output, fieldnames=kept, extrasaction="ignore")
                writer.writeheader()

            writer.writerows(rows)
            total += len(rows)
            offset += PAGE_SIZE
            print(f"  {total} rows")

            if len(rows) < PAGE_SIZE:
                break
        else:
            print("Warning: MAX_PAGES reached, data may be incomplete.")

    print(f"\nDone: {total} rows -> {filename}")
    print(f"Retrieval date (for the README): {today}")
    if total == 0:
        print("No rows received: check the filter syntax, column name or specialty.")


if __name__ == "__main__":
    main()