"""
Verify staging table row counts against source file line counts.
 
Run this after load_staging.py to confirm nothing was silently dropped during
ingestion -- "inserted" matching "read" (printed by load_staging.py) only
proves the upsert logic worked, not that every source record was captured.
This checks against the actual source files independently.
 
USAGE:
    python scripts/verify_row_counts.py
"""
import gzip
 
import psycopg2
 
from load_staging import DB_CONFIG, RAW_DIR, RESOURCE_FILE_MAP
 
 
def count_lines(path):
    with gzip.open(path, "rt", encoding="utf-8") as f:
        return sum(1 for _ in f)
 
 
def main():
    conn = psycopg2.connect(**DB_CONFIG)
    cur = conn.cursor()
 
    print(f"{'table':<15} {'source lines':>13} {'staging rows':>13} {'match':>9}")
    print("-" * 54)
 
    all_ok = True
    for table_name, filenames in RESOURCE_FILE_MAP.items():
        source_total = sum(count_lines(RAW_DIR / f) for f in filenames)
 
        cur.execute(f"SELECT count(*) FROM staging.{table_name}")
        staging_total = cur.fetchone()[0]
 
        ok = source_total == staging_total
        all_ok = all_ok and ok
        print(f"{table_name:<15} {source_total:>13} {staging_total:>13} {'OK' if ok else 'MISMATCH':>9}")
 
    cur.close()
    conn.close()
 
    print()
    if all_ok:
        print("All staging tables match source line counts.")
    else:
        print("At least one mismatch -- investigate before calling Phase 1 verified.")
 
 
if __name__ == "__main__":
    main()
 