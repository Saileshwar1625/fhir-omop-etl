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
  `sql/init/`. Verified with `scripts/verify_setup.sh`.
- Phase 1: parsed MIMIC-IV-FHIR NDJSON files into `staging` tables — 100 patients, 637
  encounters, 5,051 conditions, 813,540 observations. Row counts independently verified
  against source file line counts (`scripts/verify_row_counts.py`, all exact matches).
  Profiled: 0 missing `birthDate`/`gender`, reference format confirmed as
  `"Patient/<id>"`, 0 orphaned encounters.
- Vocabulary load: `CONCEPT`/`VOCABULARY`/`DOMAIN`/`CONCEPT_CLASS` loaded from a targeted
  Athena download (`scripts/load_vocab.sh`) — SNOMED, ICD9CM, ICD10CM, LOINC, RxNorm,
  Gender, Race and Ethnicity Code Set, OMOP Ethnicity, OMOP Extension. Not a full
  vocabulary load — `CONCEPT_ANCESTOR`/`CONCEPT_RELATIONSHIP`/`CONCEPT_SYNONYM`/
  `DRUG_STRENGTH` deliberately excluded, not needed until Phase 3.
- Phase 2: mapped and loaded `PERSON` (100 rows) and `VISIT_OCCURRENCE` (637 rows) from
  staging into `cdm` (`sql/transform/`). Verified: row counts match source, gender/race/
  ethnicity concept distributions reconcile exactly against source data, visit_concept_id
  distribution reconciles exactly against source `Encounter.class` codes, 0 orphaned
  visits (every `person_id` resolves to a real `cdm.person` row).

### In Progress
- Nothing currently in progress — Phase 2 core scope is done; Phase 3 not started.

### Planned
- Phase 3: concept mapping — LOINC → `MEASUREMENT`, SNOMED → `CONDITION_OCCURRENCE`,
  RxNorm → `DRUG_EXPOSURE` (stretch) — using the loaded OHDSI Athena standard
  vocabularies.
- Phase 4: automated tests in CI (GitHub Actions), concept-mapping coverage % reported
  here, one demonstration SQL query, `v1.0` tag.
- Stretch (post-v1.0): extend to a wearable-native source (WESAD or PPG-DaLiA), mapping
  physiological signals into FHIR `Observation`/`Device` and then into `MEASUREMENT`.

## Architecture (current)

```
docker-compose.yml        Postgres 16 container definition
sql/init/                 OMOP CDM v5.4 DDL, run automatically on first container start
sql/transform/            Phase 2: staging -> cdm mapping SQL
  01_person.sql             staging.patient -> cdm.person
  02_visit_occurrence.sql   staging.encounter -> cdm.visit_occurrence
scripts/verify_setup.sh   confirms the DDL applied correctly after `docker compose up`
scripts/load_staging.py   Phase 1: parses FHIR NDJSON into staging tables
scripts/verify_row_counts.py  independent row-count check, staging vs. source files
scripts/load_vocab.sh     loads a targeted Athena vocabulary subset into cdm.concept etc.
docs/phase1-plan.md       Phase 1 step-by-step plan
docs/phase2-plan.md       Phase 2 step-by-step plan, including the vocab-load detour
requirements.txt          Python deps
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

- **1 of 100 patients** has an unmappable `race_source_value` (`'ASKU'`, HL7's
  "asked-but-unknown" code) — no matching concept exists anywhere in the loaded
  vocabulary. `race_concept_id` is honestly `0` for that patient, not silently guessed.
- **18 of 100 patients** have no `us-core-ethnicity` extension in the source FHIR data at
  all (not a mapping failure — the data genuinely doesn't have it).
  `ethnicity_concept_id` is `0` for those.
- **`visit_concept_id` involved two judgment calls**, not clean 1:1 mappings: FHIR
  encounter class `OBSENC` ("observation encounter," a real US billing status with no
  exact OMOP equivalent) is mapped to Outpatient Visit; `SS` ("short stay," also no
  dedicated concept) is mapped to Inpatient Visit. Documented in
  `sql/transform/02_visit_occurrence.sql` and `docs/phase2-plan.md`, not hidden.
- Vocabulary is a targeted subset, not the full Athena download — sufficient for Phase 2
  and the planned Phase 3 scope, but concept hierarchy/relationship lookups
  (`CONCEPT_ANCESTOR`/`CONCEPT_RELATIONSHIP`) aren't available yet if needed later.
- No concept mapping yet for `MEASUREMENT`/`CONDITION_OCCURRENCE` (Phase 3).
- No automated tests or CI yet (Phase 4).


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
