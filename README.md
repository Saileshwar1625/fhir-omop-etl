# FHIR → OMOP CDM ETL Pipeline

An ETL pipeline that maps FHIR clinical resources into the OMOP Common Data Model (CDM) v5.4,
built on the MIMIC-IV Clinical Database Demo on FHIR (100 de-identified patients). This is a
work-in-progress, evening/weekend project — see the status sections below for what's actually
done versus planned. Nothing here is claimed as finished unless it has working, tested code
behind it.

## Status

### Completed
- Postgres 16 running via Docker Compose (`docker-compose.yml`).
- Full OMOP CDM v5.4 schema applied and verified: 39 tables, primary keys, foreign key
  constraints, and indices, all created automatically on container startup from
  `sql/init/`. Verified with `scripts/verify_setup.sh` (checks table count, confirms the
  5 in-scope tables exist, confirms PK/FK constraints applied).

### Completed
- Postgres 16 running via Docker Compose (`docker-compose.yml`). Host port mapped to 5433
  to avoid a local port 5432 conflict — see `docs/design-doc.md`.
- Full OMOP CDM v5.4 schema applied and verified: 39 tables, primary keys, foreign key
  constraints, and indices, all created automatically on container startup from
  `sql/init/`. Verified with `scripts/verify_setup.sh`.
- Phase 1 (Ingestion): FHIR NDJSON parsed into a `staging` schema via `scripts/load_staging.py`.
  All 4 in-scope resource types loaded:
  - `staging.patient`: 100 rows
  - `staging.encounter`: 637 rows
  - `staging.condition`: 5,051 rows
  - `staging.observation`: 813,540 rows

  Row counts independently verified against source NDJSON line counts for all 4 tables
  (`scripts/verify_row_counts.py`) — exact match, nothing dropped. Data profiled: 0 missing
  `birthDate`/`gender` across all patients; `Encounter.subject.reference` confirmed in
  `"Patient/<id>"` format; 0 orphaned encounters.

### In Progress
- Nothing currently — ready to start Phase 2.

### Planned
- Phase 2: map and load `PERSON` and `VISIT_OCCURRENCE` with tests (row counts, referential
  integrity, no orphaned visits).
- Phase 3: concept mapping — LOINC → `MEASUREMENT`, SNOMED → `CONDITION_OCCURRENCE`,
  RxNorm → `DRUG_EXPOSURE` (stretch) — using OHDSI Athena standard vocabularies.
- Phase 4: automated tests in CI (GitHub Actions), concept-mapping coverage % reported here,
  one demonstration SQL query, `v1.0` tag.
- Stretch (post-v1.0): wearable-native source extension.

## Architecture (current)

```
docker-compose.yml        Postgres 16 container definition
sql/init/                 OMOP CDM v5.4 DDL, run automatically on first container start
  00_create_schema.sql      creates the "cdm" schema
  01_ddl.sql                39 CDM tables (source: OHDSI/CommonDataModel v5.4.0)
  02_primary_keys.sql        primary key constraints
  03_constraints.sql         foreign key constraints (one upstream FK commented out — see file)
  04_indices.sql              indices
scripts/verify_setup.sh   confirms the DDL applied correctly after `docker compose up`
docs/design-doc.md        one-paragraph design doc (first real commit)
requirements.txt           Python deps, pinned ahead of Phase 1 (not used yet)
sql/init/05_staging_schema.sql Staging the FHIR data
scripts/load_staging.py     The main logic where the FHIR data is parsed
```

## Design decisions & tradeoffs

- **Schema name is `cdm`**, not `public` — keeps OMOP tables isolated from anything else that
  might later live in the same Postgres instance (e.g. a `staging` schema in Phase 1).
- **One upstream DDL constraint was removed.** The official OHDSI v5.4.0 `constraints.sql`
  includes a foreign key from `COHORT_DEFINITION.cohort_definition_id` to
  `COHORT.COHORT_DEFINITION_ID`, but the standard CDM DDL never defines a unique/primary key on
  that column of `COHORT` (it's a study-specific "results schema" table, not a core CDM
  dimension table) — applying it as-is throws `ERROR: there is no unique constraint matching
  given keys for referenced table "cohort"`. Since `COHORT`/`COHORT_DEFINITION` are outside this
  project's v1 table scope anyway, the single FK line was commented out (with a comment
  explaining why) rather than worked around. See `sql/init/03_constraints.sql`.

## Limitations

- FHIR data loaded into staging only — no OMOP tables (`PERSON`, `VISIT_OCCURRENCE`, etc.)
  populated yet.
- No standard vocabularies (LOINC/RxNorm/SNOMED) loaded into the database yet (files are
  downloaded, not loaded).
- No automated tests or CI yet.

## How to run this locally (Phase 0 only, for now)

Prerequisites: Docker Desktop installed and running.

```bash
git clone <this-repo-url>
cd fhir-omop-etl
docker compose up -d
./scripts/verify_setup.sh   # on Windows: use Git Bash, or run the psql commands from the script manually
```

Expected output: `Phase 0 verification passed.` with a table count of 39.

To tear down and start clean (e.g. to re-test the DDL scripts from scratch):
```bash
docker compose down -v   # -v also deletes the data volume, so init scripts re-run next time
```

## Dataset citations

This project uses:
- MIMIC-IV Clinical Database Demo on FHIR (v2.1.0 or later), PhysioNet:
  https://physionet.org/content/mimic-iv-fhir-demo/2.1.0/
- Base MIMIC-IV Clinical Database Demo (v2.2), PhysioNet:
  https://physionet.org/content/mimic-iv-demo/2.2/

Both are released under the Open Data Commons Open Database License v1.0.

## Schema source

OMOP CDM v5.4 DDL: OHDSI/CommonDataModel, tag `v5.4.0`
(https://github.com/OHDSI/CommonDataModel/tree/v5.4.0/inst/ddl/5.4/postgresql), used verbatim
except for the schema-name substitution and the one commented-out constraint noted above.
