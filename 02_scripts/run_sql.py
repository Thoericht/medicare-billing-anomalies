"""
Runs a .sql file against the local DuckDB database and prints the results of
all SELECT statements.

Requires: Python 3, package "duckdb" (pip install duckdb)
Run from the project root folder:
    python 02_scripts\\run_sql.py 03_sql\\01_condense.sql
"""

import sys

import duckdb

DB_PATH = "01_data/medicare.duckdb"   # local database file (gitignored)


def split_statements(sql_text):
    """Remove -- comments, then split the text into single statements at ';'."""
    lines = [line.split("--")[0] for line in sql_text.splitlines()]
    cleaned = "\n".join(lines)
    return [s.strip() for s in cleaned.split(";") if s.strip()]


def main():
    if len(sys.argv) != 2:
        print("Usage: python 02_scripts\\run_sql.py <path-to-sql-file>")
        sys.exit(1)

    with open(sys.argv[1], encoding="utf-8") as f:
        statements = split_statements(f.read())

    con = duckdb.connect(DB_PATH)
    for number, statement in enumerate(statements, start=1):
        first_line = statement.splitlines()[0][:70]
        print(f"[{number}/{len(statements)}] {first_line}")
        result = con.execute(statement)
        if result.description:   # only SELECT statements return rows
            columns = [c[0] for c in result.description]
            print("   ", columns)
            for row in result.fetchall()[:20]:
                print("   ", row)
    con.close()
    print("\nDone.")


if __name__ == "__main__":
    main()