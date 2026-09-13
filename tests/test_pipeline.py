"""
Phase 4 CI test: asserts the pipeline produces exact, known-correct results
when run against the small synthetic fixture in tests/fixtures/.

This does NOT load any data itself -- it assumes the fixture has already
been run through the real pipeline (load_staging.py, load_vocab.sh, the
sql/transform/*.sql files, load_concept_relationship.sh) against a fresh
Postgres, exactly as .github/workflows/ci.yml does. Run it locally with:

    PGPORT=5432 python tests/test_pipeline.py   # after running the fixture through the pipeline

Every expected number here was derived BY HAND from tests/fixtures/fhir/*
and tests/fixtures/vocab/*.csv, then independently confirmed by actually
running the pipeline once and reading back what came out -- see
docs/phase4-plan.md for the full worked-out expectations and why each one
is what it is. This script is what makes that verification repeatable
instead of a one-time manual check.

The fixture is deliberately small (3 patients, 4 encounters, 4 conditions,
7 observations) but is NOT a "happy path" toy -- it includes two edge cases
on purpose:
  - encounter-4 is missing period.end, so 02_visit_occurrence.sql's WHERE
    clause excludes it from cdm.visit_occurrence (by design).
  - condition-4 and observation-7 both reference encounter-4. Neither the
    real MIMIC dataset nor this project's earlier testing ever exercised
    what happens when a condition/observation points at an encounter that
    didn't make it into cdm.visit_occurrence -- this fixture is what
    surfaced it (see docs/phase4-plan.md, "Two real bugs found by this
    fixture").
"""
import os
import sys

import psycopg2

DB_CONFIG = dict(
    host=os.environ.get("PGHOST", "127.0.0.1"),
    port=int(os.environ.get("PGPORT", "5433")),
    dbname=os.environ.get("PGDATABASE", "omop_cdm"),
    user=os.environ.get("PGUSER", "omop_admin"),
    password=os.environ.get("PGPASSWORD", "omop_admin_pw"),
)

failures = []


def check(label, actual, expected):
    ok = actual == expected
    status = "PASS" if ok else "FAIL"
    print(f"[{status}] {label}: expected {expected!r}, got {actual!r}")
    if not ok:
        failures.append(label)


def scalar(cur, sql):
    cur.execute(sql)
    return cur.fetchone()[0]


def main():
    conn = psycopg2.connect(**DB_CONFIG)
    cur = conn.cursor()

    print("== Staging row counts (everything loads regardless of mapping outcome) ==")
    check("staging.patient", scalar(cur, "SELECT count(*) FROM staging.patient"), 3)
    check("staging.encounter", scalar(cur, "SELECT count(*) FROM staging.encounter"), 4)
    check("staging.condition", scalar(cur, "SELECT count(*) FROM staging.condition"), 4)
    check("staging.observation", scalar(cur, "SELECT count(*) FROM staging.observation"), 7)

    print("\n== cdm.person: 1 per patient, gender/race/ethnicity resolved per-person ==")
    check("cdm.person row count", scalar(cur, "SELECT count(*) FROM cdm.person"), 3)
    cur.execute("SELECT gender_concept_id, race_concept_id, ethnicity_concept_id FROM cdm.person ORDER BY person_id")
    rows = cur.fetchall()
    check(
        "cdm.person gender/race/ethnicity per patient",
        rows,
        [
            (8507, 8527, 38003564),  # patient-1: male, White, Not Hispanic -- clean full case
            (8532, 8516, 0),         # patient-2: female, Black, no ethnicity extension in source -- stays 0
            (8521, 0, 38003563),     # patient-3: other, race 'ASKU' has no matching concept -- stays 0
        ],
    )

    print("\n== cdm.visit_occurrence: encounter-4 excluded (missing period.end) ==")
    check(
        "cdm.visit_occurrence row count (4 encounters, 1 excluded)",
        scalar(cur, "SELECT count(*) FROM cdm.visit_occurrence"),
        3,
    )

    print("\n== cdm.condition_occurrence: KNOWN LIMITATION -- condition-4 silently dropped ==")
    print("   (its encounter never loaded into cdm.visit_occurrence, so the INNER JOIN")
    print("    that borrows visit_start_date for condition_start_date finds nothing to")
    print("    borrow, and the row is excluded. See docs/phase4-plan.md before treating")
    print("    a change to this number as either a regression or a bug fix.)")
    check(
        "cdm.condition_occurrence row count (4 staged, 1 dropped)",
        scalar(cur, "SELECT count(*) FROM cdm.condition_occurrence"),
        3,
    )
    check(
        "cdm.condition_occurrence concept-mapped count (5715, K766 map; V70 doesn't)",
        scalar(cur, "SELECT count(*) FROM cdm.condition_occurrence WHERE condition_concept_id != 0"),
        2,
    )

    print("\n== cdm.measurement: observation-6 excluded (no effectiveDateTime); ==")
    print("   observation-7 included with visit_occurrence_id = NULL (regression guard")
    print("   for the FK-violation bug this fixture found and 04_measurement.sql fixed)")
    check(
        "cdm.measurement row count (7 staged, 1 excluded)",
        scalar(cur, "SELECT count(*) FROM cdm.measurement"),
        6,
    )
    check(
        "cdm.measurement concept-mapped count (99001-1, 99002-2 x2 map; rest don't)",
        scalar(cur, "SELECT count(*) FROM cdm.measurement WHERE measurement_concept_id != 0"),
        3,
    )
    check(
        "cdm.measurement rows with visit_occurrence_id NULL (observation-7's case)",
        scalar(cur, "SELECT count(*) FROM cdm.measurement WHERE visit_occurrence_id IS NULL"),
        1,
    )
    check(
        "cdm.measurement.value_source_value truncated to <=50 chars",
        scalar(cur, "SELECT count(*) FROM cdm.measurement WHERE length(value_source_value) > 50"),
        0,
    )

    print("\n== Referential integrity: no orphaned person_id / visit_occurrence_id anywhere ==")
    for table in ("condition_occurrence", "measurement", "visit_occurrence"):
        check(
            f"cdm.{table}: 0 rows with person_id not in cdm.person",
            scalar(cur, f"""
                SELECT count(*) FROM cdm.{table} t
                WHERE NOT EXISTS (SELECT 1 FROM cdm.person p WHERE p.person_id = t.person_id)
            """),
            0,
        )
    for table in ("condition_occurrence", "measurement"):
        check(
            f"cdm.{table}: 0 rows with a non-NULL visit_occurrence_id missing from cdm.visit_occurrence",
            scalar(cur, f"""
                SELECT count(*) FROM cdm.{table} t
                WHERE t.visit_occurrence_id IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM cdm.visit_occurrence v WHERE v.visit_occurrence_id = t.visit_occurrence_id)
            """),
            0,
        )

    cur.close()
    conn.close()

    print()
    if failures:
        print(f"{len(failures)} check(s) FAILED: {failures}")
        sys.exit(1)
    print("All checks passed.")


if __name__ == "__main__":
    main()
