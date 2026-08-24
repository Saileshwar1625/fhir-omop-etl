"""
Phase 1 ingestion script: parse MIMIC-IV-FHIR NDJSON files into staging tables.

USAGE:
    python scripts/load_staging.py --resource patient
    python scripts/load_staging.py --resource all

WHAT'S ALREADY DONE FOR YOU:
  - CLI argument parsing (main())
  - DB connection handling (main())
  - RESOURCE_FILE_MAP: which source files feed which staging table
  - read_ndjson_gz(): streams a gzipped NDJSON file, skips bad lines with a warning

WHAT YOU NEED TO IMPLEMENT:
  - load_resource_type(): the actual read-and-upsert loop. Full spec is in its
    docstring below. This is the one real piece of Phase 1 logic -- everything
    else here is plumbing you'd otherwise have to look up anyway.
"""
import argparse
import gzip
import json
import sys
from pathlib import Path

import psycopg2
from psycopg2.extras import Json

DB_CONFIG = dict(
    host="127.0.0.1", port=5433, dbname="omop_cdm",
    user="omop_admin", password="omop_admin_pw",
)

RAW_DIR = Path("data/raw/mimic-iv-clinical-database-demo-on-fhir-2.1.0/fhir")

# Key = staging table name, value = list of source filenames (relative to RAW_DIR)
# that contain that FHIR resourceType. Medication files deliberately excluded --
# see docs/phase1-plan.md before adding them.
RESOURCE_FILE_MAP = {
    "patient": [
        "MimicPatient.ndjson.gz",
    ],
    "encounter": [
        "MimicEncounter.ndjson.gz",
        "MimicEncounterED.ndjson.gz",
        "MimicEncounterICU.ndjson.gz",
    ],
    "condition": [
        "MimicCondition.ndjson.gz",
        "MimicConditionED.ndjson.gz",
    ],
    "observation": [
        "MimicObservationChartevents.ndjson.gz",
        "MimicObservationDatetimeevents.ndjson.gz",
        "MimicObservationED.ndjson.gz",
        "MimicObservationLabevents.ndjson.gz",
        "MimicObservationMicroOrg.ndjson.gz",
        "MimicObservationMicroSusc.ndjson.gz",
        "MimicObservationMicroTest.ndjson.gz",
        "MimicObservationOutputevents.ndjson.gz",
        "MimicObservationVitalSignsED.ndjson.gz",
    ],
}


def read_ndjson_gz(path):
    """Yield one parsed JSON object per line from a gzipped NDJSON file.
    Skips and warns on malformed lines instead of crashing the whole load."""
    with gzip.open(path, "rt", encoding="utf-8") as f:
        for lineno, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError as e:
                print(f"  [WARN] {path.name} line {lineno}: bad JSON ({e}) -- skipped", file=sys.stderr)


def load_resource_type(conn, table_name, filenames):
    total_inserted=0

    for filename in filenames:
        path = RAW_DIR / filename
        cur = conn.cursor()
        read_count = 0
        inserted_count = 0
        skipped_count = 0

        for resource in read_ndjson_gz(path):
            # Process each resource and insert into the staging table
            read_count += 1
            resource_id = resource.get("id")

            if resource_id is None:
                print(f"  [WARN] {filename}: missing 'id' field -- skipped")
                skipped_count += 1
                continue

            cur.execute(
                f"""
                INSERT INTO staging.{table_name} (resource_id, resource)
                VALUES (%s, %s)
                ON CONFLICT (resource_id) DO NOTHING
                """,
                (resource_id, Json(resource)),
            )
            inserted_count += cur.rowcount

            if read_count % 500 == 0:
                conn.commit()

        conn.commit()
        cur.close()

        print (f"  {filename}: read {read_count}, inserted {inserted_count}, skipped {skipped_count}")
        total_inserted += inserted_count

    return total_inserted




def main():
    parser = argparse.ArgumentParser(description="Load MIMIC-IV-FHIR NDJSON into staging tables")
    parser.add_argument(
        "--resource",
        choices=list(RESOURCE_FILE_MAP.keys()) + ["all"],
        required=True,
        help="which staging table to load, or 'all'",
    )
    args = parser.parse_args()

    targets = list(RESOURCE_FILE_MAP.keys()) if args.resource == "all" else [args.resource]

    conn = psycopg2.connect(**DB_CONFIG)
    try:
        for table_name in targets:
            filenames = RESOURCE_FILE_MAP[table_name]
            print(f"\n== Loading staging.{table_name} ==")
            count = load_resource_type(conn, table_name, filenames)
            print(f"staging.{table_name}: {count} rows inserted total")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
