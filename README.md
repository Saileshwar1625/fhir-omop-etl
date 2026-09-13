# FHIR → OMOP CDM ETL Pipeline

An ETL pipeline that maps FHIR clinical resources into the OMOP Common Data Model (CDM) v5.4,
built on the MIMIC-IV Clinical Database Demo on FHIR (100 de-identified patients). This is a
work-in-progress, evening/weekend project — see the status sections below for what's actually
done versus planned. Nothing here is claimed as finished unless it has working, tested code
behind it, with verification queries run and their results checked.

## Status

### Completed

- **Phase 0 — Setup.** Postgres 16 via Docker Compose. Full OMOP CDM v5.4 schema applied and
  verified: 39 tables, primary keys, foreign key constraints, indices, all created automatically
  on container startup from `sql/init/`. Verified with `scripts/verify_setup.sh`.
- **Phase 1 — Load (staging).** `scripts/load_staging.py` parses MIMIC-IV-FHIR NDJSON files
  (Patient, Encounter, Condition, Observation — Medication resources deliberately excluded from
  scope, since `DRUG_EXPOSURE` is stretch-only) into a `staging` schema, one JSONB column per
  resource. Row counts independently verified against source file line counts
  (`scripts/verify_row_counts.py`, all exact matches): 100 patients, 637 encounters, 5,051
  conditions, 813,540 observations.
- **Phase 2 — Transform: PERSON + VISIT_OCCURRENCE.** `sql/transform/01_person.sql`,
  `02_visit_occurrence.sql`. Required building `scripts/load_vocab.sh` first (loads
  `CONCEPT`/`VOCABULARY`/`DOMAIN`/`CONCEPT_CLASS` from OHDSI Athena — every OMOP `_concept_id`
  column FKs to `cdm.concept`, which starts empty). `cdm.person`: 100 rows, gender/race/ethnicity
  concept IDs resolved (race 72 White / 17 Unknown / 10 Black / 1 unmapped-ASKU; ethnicity 77 Not
  Hispanic / 18 no extension / 5 Hispanic — reconciles exactly against source). `cdm.
  visit_occurrence`: 637 rows, 0 orphaned `person_id`, `visit_concept_id` distribution (341
  Emergency / 158 Inpatient / 138 Outpatient) reconciles exactly against `Encounter.class.code`.
  Full write-up: `docs/phase2-plan.md`.
- **Phase 3 — Transform: CONDITION_OCCURRENCE + MEASUREMENT.**
  `scripts/load_concept_relationship.sh` (loads `RELATIONSHIP` + a `'Maps to'`-filtered
  `CONCEPT_RELATIONSHIP`, the lookup table that resolves a source code to a standard concept),
  `sql/transform/03_condition_occurrence.sql`, `04_measurement.sql`.
  - `cdm.condition_occurrence`: 5,051 rows (matches `staging.condition` exactly), 0 orphaned
    `person_id`/`visit_occurrence_id`. **96.5% concept-mapping coverage** (4,872/5,051 resolve to
    a standard SNOMED concept via ICD9CM/ICD10CM → `'Maps to'`; the remaining 3.5% are mostly
    administrative/status codes with no disease-concept equivalent).
  - `cdm.measurement`: 813,540 rows (100% of `staging.observation`, 0 excluded). **1.11%
    concept-mapping coverage** (9,042/813,540) — this is a hard ceiling set by the source data,
    not a mapping-logic gap: only 9,042 observations carry a real LOINC code in the first place
    (confirmed against both the FHIR export and the base, non-FHIR MIMIC-IV Clinical Database
    Demo — neither has a LOINC crosswalk for MIMIC's local chartevents/labevents item
    dictionaries). All 9,042 of those LOINC-coded rows mapped successfully — 100% within the
    mappable subset.
  Full write-up: `docs/phase3-plan.md`.

### In Progress

- **Phase 4 — Testing, CI, Release.** `.github/workflows/ci.yml` runs the entire pipeline (DDL →
  staging load → vocab load → concept mapping) in GitHub Actions against a small synthetic fixture
  (`tests/fixtures/`) — real Athena vocabularies require individual license acceptance and can't be
  auto-fetched or redistributed in CI, so the fixture is fake data exercising the real pipeline
  code. Building the fixture found **two real edge-case bugs** that 5,051 real conditions and
  813,540 real measurements never triggered: `04_measurement.sql` could crash its entire 813,540-row
  insert on a single encounter missing a date (fixed, reverified against both the fixture and the
  real data — see `docs/phase4-plan.md`); `03_condition_occurrence.sql` silently drops a condition
  in the same situation (documented as a real limitation, not patched, since there's no valid date
  to insert in that case — see below). `tests/test_pipeline.py` asserts 20 exact expected values
  against the fixture, all currently passing. **CI confirmed green on GitHub Actions** (one real
  CI-only failure along the way: two scripts lost their git-tracked executable bit on a
  OneDrive-mounted Windows checkout, causing an exit-126 permission error — fixed via
  `git update-index --chmod=+x` and by switching `ci.yml` to invoke scripts via `bash` instead of
  `./`, see `docs/phase4-plan.md`). The demonstration query
  (`sql/demo/comorbidity_measurement_summary.sql`) has been run against the real, fully-loaded
  database — output recorded below. Still open: the `v1.0` tag — see `docs/phase4-plan.md` for the
  full Definition of Done.

### Planned

- Stretch (post-v1.0): `DRUG_EXPOSURE` via RxNorm (medication resources not yet parsed into
  staging — would need a Phase 1 extension first). Extend to a wearable-native source (WESAD or
  PPG-DaLiA), mapping physiological signals into FHIR `Observation`/`Device` and then into
  `MEASUREMENT`.

See `docs/project-plan.md` for the full roadmap with dates, and the table below for where each
phase's detailed writeup lives.

| Phase | Doc |
|---|---|
| All phases (roadmap) | `docs/project-plan.md` |
| Phase 1 (staging load) | `docs/phase1-plan.md` |
| Phase 2 (PERSON, VISIT_OCCURRENCE) | `docs/phase2-plan.md` |
| Phase 3 (CONDITION_OCCURRENCE, MEASUREMENT) | `docs/phase3-plan.md` |
| Phase 4 (CI, fixture testing, two bugs found) | `docs/phase4-plan.md` |

## Architecture (current)

```
docker-compose.yml              Postgres 16 container definition
sql/init/                       OMOP CDM v5.4 DDL, run automatically on first container start
  00_create_schema.sql            creates the "cdm" schema
  01_ddl.sql                      39 CDM tables (source: OHDSI/CommonDataModel v5.4.0)
  02_primary_keys.sql             primary key constraints
  03_constraints.sql              foreign key constraints (one upstream FK commented out — see file)
  04_indices.sql                  indices
  05_staging_schema.sql           creates the "staging" schema (raw FHIR JSONB landing tables)
scripts/
  verify_setup.sh                 confirms the DDL applied correctly after `docker compose up`
  load_staging.py                 parses MIMIC-IV-FHIR NDJSON into staging.* (Phase 1)
  verify_row_counts.py            independent row-count check, staging vs. source files (Phase 1)
  load_vocab.sh                   loads CONCEPT/VOCABULARY/DOMAIN/CONCEPT_CLASS from Athena (Phase 2 prereq)
  load_concept_relationship.sh    loads RELATIONSHIP + 'Maps to'-filtered CONCEPT_RELATIONSHIP (Phase 3 prereq)
sql/transform/
  01_person.sql                   staging.patient -> cdm.person
  02_visit_occurrence.sql         staging.encounter -> cdm.visit_occurrence
  03_condition_occurrence.sql     staging.condition -> cdm.condition_occurrence
  04_measurement.sql              staging.observation -> cdm.measurement
sql/demo/
  comorbidity_measurement_summary.sql   Phase 4 demonstration query (real DB, not the fixture)
docs/
  design-doc.md                   one-paragraph design doc (first real commit)
  project-plan.md                 roadmap for all phases, with dates
  phase1-plan.md                  Phase 1 detailed writeup
  phase2-plan.md                  Phase 2 detailed writeup
  phase3-plan.md                  Phase 3 detailed writeup
  phase4-plan.md                  Phase 4 detailed writeup, incl. the two bugs the fixture found
tests/
  fixtures/fhir/                   synthetic FHIR NDJSON.gz fixture (fake patients/encounters/etc.)
  fixtures/vocab/                  synthetic OMOP vocabulary CSVs (fake terminology, real fixed IDs)
  test_pipeline.py                 asserts exact expected pipeline output against the fixture
.github/workflows/ci.yml          runs the full pipeline against the fixture on every push
requirements.txt                  Python deps (Phase 1)
```

## Design decisions & tradeoffs

- **Schema names**: `cdm` for the OMOP tables, `staging` for raw FHIR JSONB landing tables — kept
  separate so the staging layer (source-shaped, disposable) never gets confused with the CDM
  layer (target-shaped, what downstream tools query).
- **One upstream DDL constraint was removed.** The official OHDSI v5.4.0 `constraints.sql`
  includes a foreign key from `COHORT_DEFINITION.cohort_definition_id` to
  `COHORT.COHORT_DEFINITION_ID`, but the standard CDM DDL never defines a unique/primary key on
  that column of `COHORT`. Since `COHORT`/`COHORT_DEFINITION` are outside this project's v1 table
  scope, the single FK line was commented out (with a comment explaining why). See
  `sql/init/03_constraints.sql`.
- **ID crosswalks** (`staging.person_id_map`, `visit_id_map`, `condition_id_map`,
  `observation_id_map`): FHIR resource IDs are string UUIDs; OMOP's `_id` columns are integers.
  Each crosswalk is a small `GENERATED ALWAYS AS IDENTITY` table, built with `ON CONFLICT DO
  NOTHING` so IDs are assigned once and stay stable across re-runs.
- **Race/ethnicity, condition dates, and value-field truncation** — several source-data quirks
  required judgment calls (e.g. `CONDITION` has no date field of its own and borrows its linked
  visit's date; OMOP's `value_source_value` column is `varchar(50)` and truncates some free-text
  lab/exam findings). Each is explained in detail, with the reasoning, in `docs/phase2-plan.md`
  and `docs/phase3-plan.md` rather than repeated here.

## Limitations

- `DRUG_EXPOSURE` not implemented — medication resources were deliberately excluded from Phase 1
  scope (stretch-only per the original plan).
- `MEASUREMENT` concept-mapping coverage is 1.11% — a source-data ceiling (see Phase 3 status
  above), not something further mapping logic can improve without a different source or a manual
  local-code-to-LOINC crosswalk (out of scope for v1).
- 1 patient's `race_concept_id` and all 18 patients with a missing race/ethnicity extension stay
  at `0`/have no source extension — documented in `docs/phase2-plan.md`, not silently dropped.
- `OBSENC`/`SS` encounter classes map to `visit_concept_id` via judgment call (no exact OMOP
  concept exists for either) — see `docs/phase2-plan.md`.
- `value_source_value` in `cdm.measurement` is truncated to 50 characters (OMOP schema limit) —
  the untruncated original text isn't preserved elsewhere in this pipeline.
- **A condition whose linked encounter is missing `period.start`/`period.end` will not appear in
  `cdm.condition_occurrence` at all** — silently, no error. Found via Phase 4 fixture testing, not
  observed in the real data (0/637 real encounters were missing a date, so this has never actually
  happened here). Can't be fixed the way the equivalent `MEASUREMENT` bug was: `CONDITION_OCCURRENCE`
  has no date of its own and borrows the visit's date, and `condition_start_date` is `NOT NULL` — if
  the visit's date doesn't exist, there's genuinely nothing valid to insert. See `docs/phase4-plan.md`.
- CI (`.github/workflows/ci.yml`) tests against a synthetic fixture, not the real MIMIC/Athena data
  — real Athena vocabularies can't legally be fetched or redistributed in CI (individual license
  required). The fixture exercises the same pipeline code, but its "results" are meaningless as
  data — see `docs/phase4-plan.md`.

## How to run this locally

Prerequisites: Docker Desktop installed and running.

```bash
git clone <this-repo-url>
cd fhir-omop-etl
docker compose up -d
./scripts/verify_setup.sh   # on Windows: use Git Bash, or run the psql commands from the script manually
```

Expected output: `Phase 0 verification passed.` with a table count of 39.

Then run the load and transform scripts in order (each is documented in its own header comment,
and in `docs/phase2-plan.md`/`docs/phase3-plan.md`):

```bash
python scripts/load_staging.py --resource all
python scripts/verify_row_counts.py   # confirm nothing was silently dropped

./scripts/load_vocab.sh
docker exec -i omop_postgres psql -U omop_admin -d omop_cdm < sql/transform/01_person.sql
docker exec -i omop_postgres psql -U omop_admin -d omop_cdm < sql/transform/02_visit_occurrence.sql

./scripts/load_concept_relationship.sh
docker exec -i omop_postgres psql -U omop_admin -d omop_cdm < sql/transform/03_condition_occurrence.sql
docker exec -i omop_postgres psql -U omop_admin -d omop_cdm < sql/transform/04_measurement.sql
```

To tear down and start clean (e.g. to re-test the DDL scripts from scratch):
```bash
docker compose down -v   # -v also deletes the data volume, so init scripts re-run next time
```

## Running the tests

`.github/workflows/ci.yml` runs this automatically on every push, against a synthetic fixture
(`tests/fixtures/`) instead of the real data — see `docs/phase4-plan.md` for why. To run the same
sequence locally (e.g. against a scratch Postgres, not your real loaded database):

```bash
export PGHOST=127.0.0.1 PGPORT=5433 PGDATABASE=omop_cdm PGUSER=omop_admin PGPASSWORD=omop_admin_pw
export RAW_DIR=tests/fixtures/fhir
export VOCAB_DIR=tests/fixtures/vocab

for f in sql/init/*.sql; do psql -f "$f"; done
python scripts/load_staging.py --resource all
./scripts/load_vocab.sh
psql -f sql/transform/01_person.sql
psql -f sql/transform/02_visit_occurrence.sql
./scripts/load_concept_relationship.sh
psql -f sql/transform/03_condition_occurrence.sql
psql -f sql/transform/04_measurement.sql
python tests/test_pipeline.py
```

Expected output: 20 `[PASS]` lines, ending `All checks passed.` Run this against a disposable
database, not your real one — it truncates vocabulary tables and inserts fixture data that has
nothing to do with the real 100-patient MIMIC cohort.

### Demonstration query

`sql/demo/comorbidity_measurement_summary.sql` answers a real question against the actual loaded
database (not the fixture): for each standard diagnosis, how many patients have it, and how many
measurements were typically recorded during the visit where it was diagnosed. Run it against your
real, fully-loaded database:

```bash
docker exec -i omop_postgres psql -U omop_admin -d omop_cdm < sql/demo/comorbidity_measurement_summary.sql
```

Run against the real 100-patient MIMIC-IV cohort (Sept 13, 2026):

| condition_concept_id | condition_name | patient_count | diagnosis_count | avg_measurements_per_visit |
|---|---|---|---|---|
| 1340204 | History of event | 72 | 320 | 301.0 |
| 320128 | Essential hypertension | 55 | 134 | 186.9 |
| 432867 | Hyperlipidemia | 47 | 114 | 267.3 |
| 197320 | Acute kidney injury | 32 | 77 | 440.7 |
| 201826 | Type 2 diabetes mellitus | 30 | 102 | 224.2 |
| 313217 | Atrial fibrillation | 27 | 68 | 363.1 |
| 439777 | Anemia | 26 | 45 | 401.2 |
| 81902 | Urinary tract infectious disease | 23 | 47 | 318.9 |
| 4119499 | Not for resuscitation | 22 | 26 | 540.4 |
| 319835 | Congestive heart failure | 20 | 58 | 448.3 |
| 433736 | Obesity | 20 | 43 | 281.9 |
| 432870 | Thrombocytopenic disorder | 20 | 26 | 605.0 |
| 46272451 | Long-term current use of insulin | 19 | 86 | 205.7 |
| 46273937 | Long-term current use of anticoagulant | 19 | 52 | 307.6 |
| 437827 | Pure hypercholesterolemia | 19 | 42 | 219.8 |
| 435515 | Hypo-osmolality and or hyponatremia | 19 | 33 | 476.9 |
| 317576 | Coronary arteriosclerosis | 19 | 28 | 298.3 |
| 435517 | Acidosis | 19 | 27 | 672.9 |
| 434894 | Acute posthemorrhagic anemia | 18 | 25 | 566.9 |
| 437264 | Tobacco dependence syndrome | 18 | 24 | 189.5 |

(Full result set — query is capped at `LIMIT 20`, ordered by `patient_count` descending.)
No independent ground truth to check this against (this isn't a claim of "verified correct," just
"ran and produced output") — but it's a directionally sane result for an ICU-derived cohort:
hypertension/hyperlipidemia/diabetes are the expected top chronic-disease conditions, and
measurement intensity per visit tracks roughly with acuity (acidosis, thrombocytopenia, and AKI —
all conditions associated with sicker ICU patients — have the highest `avg_measurements_per_visit`,
while hypertension and tobacco dependence, chronic but not acutely monitored, have the lowest).

## Dataset citations

This project uses:
- MIMIC-IV Clinical Database Demo on FHIR (v2.1.0 or later), PhysioNet:
  https://physionet.org/content/mimic-iv-fhir-demo/2.1.0/
- Base MIMIC-IV Clinical Database Demo (v2.2), PhysioNet:
  https://physionet.org/content/mimic-iv-demo/2.2/
- OHDSI Athena standard vocabularies (Gender, Race, Ethnicity, ICD9CM, ICD10CM, SNOMED, LOINC,
  and supporting internal vocabularies): https://athena.ohdsi.org/

Both MIMIC datasets are released under the Open Data Commons Open Database License v1.0. Neither
the base MIMIC-IV Clinical Database Demo files nor the Athena vocabulary files are committed to
this repo — both are gitignored and downloaded locally by whoever runs the pipeline.

## Schema source

OMOP CDM v5.4 DDL: OHDSI/CommonDataModel, tag `v5.4.0`
(https://github.com/OHDSI/CommonDataModel/tree/v5.4.0/inst/ddl/5.4/postgresql), used verbatim
except for the schema-name substitution and the one commented-out constraint noted above.
