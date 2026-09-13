"""
Phase 1 ingestion script: parse MIMIC-IV-FHIR NDJSON files into staging tables.

USAGE:
    python scripts/load_staging.py --resource patient
    python scripts/load_staging.py --resource all

DB connection and the source data directory are read from environment
variables, falling back to this project's local docker-compose defaults if
unset -- this lets the exact same script run against the local Docker
Postgres (port 5433) or a CI Postgres service container (typically port
5432) or any other Postgres, and against either the real MIMIC download or
a small test fixture, without editing the script. See docs/phase4-plan.md
for why this became configurable (originally hardcoded; Phase 4's CI needed
to point this at tests/fixtures/fhir and a different host/port).

Environment variables (all optional):
    PGHOST      default 127.0.0.1
    PGPORT      default 5433   (docker-compose.yml's host-side port mapping)
    PGDATABASE  default omop_cdm
    PGUSER      default omop_admin
    PGPASSWORD  default omop_admin_pw  (dev-only password, see docker-compose.yml)
    RAW_DIR     default data/raw/mimic-iv-clinical-database-demo-on-fhir-2.1.0/fhir
"""
import argparse
import gzip
import json
import os
import sys
from pathlib import Path

import psycopg2
from psycopg2.extras import Json

DB_CONFIG = dict(
    host=os.environ.get("PGHOST", "127.0.0.1"),
    port=int(os.environ.get("PGPORT", "5433")),
    dbname=os.environ.get("PGDATABASE", "omop_cdm"),
    user=os.environ.get("PGUSER", "omop_admin"),
    password=os.environ.get("PGPASSWORD", "omop_admin_pw"),
)

RAW_DIR = Path(os.environ.get(
    "RAW_DIR", "data/raw/mimic-iv-clinical-database-demo-on-fhir-2.1.0/fhir"
))

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
    total_inserted = 0

    for filename in filenames:
        path = RAW_DIR / filename
        cur = conn.cursor()
        read_count = 0
        inserted_count = 0
        skipped_count = 0

        for resource in read_ndjson_gz(path):
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

        print(f"  {filename}: read {read_count}, inserted {inserted_count}, skipped {skipped_count}")
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
