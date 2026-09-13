# Phase 4 Plan — Testing, CI, Release

Goal (from the brief): automated tests in CI, one demonstration SQL query, a `v1.0` tag.
Concept-mapping coverage % was already reported in Phase 3's README update, ahead of
schedule.

## The constraint that shapes everything else here

OHDSI Athena vocabulary downloads require accepting an individual license before you
can get the files at all, and the files themselves aren't licensed for redistribution.
That rules out both obvious ways of testing this pipeline in CI: you can't have GitHub
Actions download the real vocabularies (no way to script the license click-through, and
even if you could, it's not yours to redistribute by committing it to the repo), and you
can't commit even a slice of the real `CONCEPT.csv`/`CONCEPT_RELATIONSHIP.csv` to the
repo for the same reason.

The approach here: build a small, **entirely synthetic** fixture — fake FHIR resources
and a fake-but-structurally-valid OMOP vocabulary subset (`tests/fixtures/`) — and run
the real, unmodified pipeline code against it in CI. The fixture data has no
relationship to real clinical terminology (concept names like "Fixture standard dx A"
make that obvious on sight), so there's nothing to license. What's real is the SQL, the
Python, and the schema — the exact same files that run against the real MIMIC/Athena
data locally.

## Fixture design (`tests/fixtures/`)

**`tests/fixtures/fhir/`** — 3 synthetic patients, 4 encounters, 4 conditions, 7
observations, gzipped NDJSON in the same filenames `scripts/load_staging.py`'s
`RESOURCE_FILE_MAP` already expects (the source files this project doesn't use for a
given resource type — e.g. `MimicEncounterED.ndjson.gz` — exist too, as empty gzip
files, so the real multi-file-per-resource loading logic actually gets exercised, not
bypassed).

This is deliberately not a "happy path" fixture. Two cases are built in on purpose:

- **`encounter-4` is missing `period.end`.** `02_visit_occurrence.sql`'s `WHERE` clause
  (written in Phase 2, to avoid a `NOT NULL` insert failure) excludes it from
  `cdm.visit_occurrence`. This case never occurred in the real MIMIC data (0/637
  encounters were missing a date), so it was never exercised until this fixture.
- **`condition-4` and `observation-7` both reference `encounter-4`.** Nothing in Phases
  2–3 ever tested what happens when a condition or observation points at an encounter
  that didn't make it into `cdm.visit_occurrence`. It turns out `CONDITION_OCCURRENCE`
  and `MEASUREMENT` handle this completely differently — see "Two real bugs found by
  this fixture" below.

Also covered: a patient with no `us-core-ethnicity` extension at all, a patient with an
unmappable race code (`ASKU`), both ICD9CM and ICD10CM condition codes (one mappable,
one deliberately not — code `V70` has no concept in the fixture vocab), all three
`Observation` value shapes from Phase 3 (`valueQuantity`+`referenceRange`,
`valueQuantity` alone, `valueString`, `valueCodeableConcept` display fallback), a LOINC
code that IS in the fixture vocab and one that ISN'T (both tagged `system =
http://loinc.org`, to distinguish "not LOINC" from "LOINC but unmapped"), a
`valueString` longer than 50 characters (to regression-test the `LEFT(...,50)`
truncation from Phase 3), and an observation missing `effectiveDateTime` entirely (to
regression-test that exclusion).

**`tests/fixtures/vocab/`** — tab-delimited CSVs in the exact format Athena's real
export uses (so `load_vocab.sh`/`load_concept_relationship.sh` don't need a fixture-only
code path), containing:

- The **fixed-ID reference concepts** that `sql/transform/*.sql` hardcodes by number —
  Gender (8507/8532/8521/8551), Race (8527/8516/8552), Ethnicity (38003563/38003564),
  Visit (9201/9202/9203), Type Concept (32817/32827), plus `concept_id = 0` ("No
  matching concept", which OMOP's own real vocabulary always includes, and which every
  `COALESCE(..., 0)` in this pipeline's transform SQL depends on existing). These use
  the **real OMOP concept IDs** — they're not fabricated, because the transform SQL's
  `CASE` statements are hardcoded to these specific integers, not looked up dynamically.
  Concept IDs are stable identifiers, not the copyrighted part of a vocabulary (that's
  the bulk curated content — millions of code-to-code mappings); using the same well
  known ID with a descriptive label isn't a licensing concern.
- **Fully synthetic source/standard concepts** for the ICD9CM/ICD10CM/SNOMED/LOINC
  codes the fixture's FHIR data references, plus matching `CONCEPT_RELATIONSHIP` `'Maps
  to'` rows. These ARE fake — fake IDs, fake `concept_code`s, fake names — because this
  half of the mapping is resolved dynamically by code lookup, not hardcoded by ID, so
  there's no need for (and no license to use) real terminology here.

## Two real bugs found by this fixture

Building an edge case into test data instead of only testing the happy path found two
things that 5,051 real conditions and 813,540 real measurements never surfaced, because
the real data happened not to trigger either one.

### 1. `04_measurement.sql` — fixed

**The bug**: `visit_occurrence_id` was resolved from `staging.visit_id_map` alone — the
crosswalk that assigns an id to every encounter *unconditionally*, regardless of whether
that encounter's visit actually made it into `cdm.visit_occurrence`. When
`observation-7` (referencing the excluded `encounter-4`) ran through the real INSERT,
Postgres rejected it: `insert or update on table "measurement" violates foreign key
constraint "fpk_measurement_visit_occurrence_id"` — and because the whole transform is
one `INSERT ... SELECT` statement, **that one bad reference aborted the entire
statement**. Confirmed by actually running it and watching it fail, not by inspection.
If even one real MIMIC encounter had been missing a date, this would have zeroed out all
813,540 measurement rows with a cryptic FK error, on a table that took several minutes
to process.

**The fix**: added `LEFT JOIN cdm.visit_occurrence vo ON vo.visit_occurrence_id =
vm.visit_occurrence_id` and select `vo.visit_occurrence_id` (not `vm`'s) — `NULL` when
the visit never actually loaded, which is valid here because `MEASUREMENT.
visit_occurrence_id` is nullable and `MEASUREMENT` has its own date
(`effectiveDateTime`) independent of the visit. Re-verified against the fixture:
`observation-7` now loads with `visit_occurrence_id = NULL` instead of crashing the
batch. Also re-verified this is a no-op against the real Phase 3 data (0/637 encounters
were excluded there, so the join always resolved anyway) — the real measurement numbers
in the README are unchanged.

### 2. `03_condition_occurrence.sql` — documented limitation, not fixed

**The bug-shaped behavior**: `condition-4` (referencing `encounter-4`) is silently
**dropped** — not inserted with `condition_concept_id = 0` like an unmapped code, just
absent, with no error and no log line. Unlike `MEASUREMENT`, this can't be fixed the
same way: `CONDITION_OCCURRENCE` has no date of its own (Phase 3's design already
borrows `visit_start_date` from the linked visit), and `condition_start_date` is `NOT
NULL` in the DDL. If the visit never loaded, there is no date to borrow and genuinely no
valid value to insert — a `LEFT JOIN` would just turn a clean FK failure into a `NOT
NULL` failure instead. The INNER JOIN's silent exclusion is a real consequence of
Phase 3's original judgment call (borrow the visit's date), not a new mistake.

This is left as a **documented limitation**, not silently patched: a condition whose
linked encounter is missing a start/end date will not appear in `cdm.condition_occurrence`
at all. `tests/test_pipeline.py` asserts this exact count (3, not 4) as a regression
guard with an explanatory comment, specifically so a future change to this number gets
noticed and questioned rather than passing unremarked. This is also why Phase 3's
README claim of "0 dropped" needs a footnote: it was true for this dataset, not
structurally guaranteed by the SQL — worth remembering if this pipeline is ever pointed
at a different or larger MIMIC cohort.

## Why `load_vocab.sh`/`load_concept_relationship.sh`/`load_staging.py` changed

All three originally hardcoded either `docker exec -i omop_postgres psql ...` or a fixed
local file path. Neither survives contact with CI: there's no `omop_postgres` container
in GitHub Actions (Postgres runs as a `services:` container with a different name), and
the fixture data doesn't live where the real MIMIC download does.

Fix: connect with plain `psql` using the standard `PGHOST`/`PGPORT`/`PGDATABASE`/
`PGUSER`/`PGPASSWORD` environment variables (which `psql` already reads natively — no
custom flag-parsing needed), and read the data directory from `VOCAB_DIR`/`RAW_DIR`
environment variables. All five variables default to this project's existing local
`docker-compose.yml` values, so **running these scripts locally with no environment
variables set behaves exactly as before** — this was verified by re-running the entire
Phase 2/3 sequence against the fixture end-to-end (not just read through) and comparing
output to what Phase 2/3 already had checked in. CI just exports different values before
calling the same scripts.

## CI workflow (`.github/workflows/ci.yml`)

Triggers on every push/PR to `main`. Uses GitHub Actions' native `services: postgres`
(not nested `docker compose`, which would mean Docker-in-Docker — unnecessary
complexity when a plain service container does the same job). Steps, in order: checkout
→ install Python deps → apply `sql/init/*.sql` → confirm 39 tables → `load_staging.py`
against the fixture → `load_vocab.sh` against the fixture → `01_person.sql`/
`02_visit_occurrence.sql` → `load_concept_relationship.sh` against the fixture →
`03_condition_occurrence.sql`/`04_measurement.sql` → `tests/test_pipeline.py`.

Not used in CI: `scripts/verify_setup.sh`. Its healthcheck loop calls `docker inspect
<container-name>`, which only means something against the specific named local
docker-compose container — there's no equivalent "container name" to inspect for a
GitHub Actions service container (which is already guaranteed healthy, via its own
`--health-cmd`, before any step runs). CI does the one check from that script that still
applies (39 tables) directly instead.

This whole sequence was run manually, start to finish, against a local Postgres before
ever being written into the workflow YAML — every step above was actually executed and
its output checked, not assumed to work from reading the code.

## `tests/test_pipeline.py`

Asserts exact, by-hand-derived-then-empirically-confirmed values: staging row counts,
`cdm.person`'s per-patient gender/race/ethnicity resolution, the visit exclusion count,
both "silently dropped" and "fixed" edge cases above (as explicit regression guards with
comments explaining why the number is what it is, not just what it is), concept-mapping
counts for both `CONDITION_OCCURRENCE` and `MEASUREMENT`, the `value_source_value`
truncation, and referential integrity (no orphaned `person_id`/`visit_occurrence_id`
anywhere). 20 checks, all passing against the fixture as of this writing.

## Demonstration SQL query

`sql/demo/comorbidity_measurement_summary.sql` — see the file for the full query and
comments. Answers a real question the loaded data can support: for each standard
condition concept that's present, how many distinct patients have it, and what's their
average count of (any) measurements recorded during the encounter where that condition
was diagnosed. This is a genuine "does the CDM actually let you ask a clinical/RWE-style
question across tables" demonstration, not a `SELECT count(*)` — it joins
`CONDITION_OCCURRENCE` → `CONCEPT` (for the human-readable condition name) →
`VISIT_OCCURRENCE` → `MEASUREMENT`, which only works because Phase 2's crosswalks and
Phase 3's concept resolution are both correct. Run against the real, fully-loaded
database on Sept 13, 2026 — top result: 72 patients with "History of event" (a
non-specific administrative/status concept, expected to lead by count), followed by the
expected chronic-disease conditions for an ICU-derived cohort (essential hypertension 55,
hyperlipidemia 47, acute kidney injury 32, type 2 diabetes 30). `avg_measurements_per_visit`
tracks roughly with acuity — acidosis, thrombocytopenic disorder, and AKI (all associated
with sicker ICU patients) sit at the high end (605–673), while chronic-but-stable
conditions like hypertension and tobacco dependence sit at the low end (~187–190). Full
output recorded in the README (`## Running the tests` → `### Demonstration query`).

## Definition of done for Phase 4

- [x] CI runs the full pipeline against a synthetic fixture on every push (no license
      issue, since nothing real is committed).
- [x] Two real edge-case bugs found via the fixture; one fixed and reverified against
      both the fixture and the real Phase 3 data, one documented as a limitation with a
      regression-guarding test rather than silently patched or ignored.
- [x] `load_staging.py`/`load_vocab.sh`/`load_concept_relationship.sh` made
      environment-configurable (DB connection + data directory) without changing their
      default (local, no env vars set) behavior — reverified against the fixture
      end-to-end after the change.
- [x] Demonstration SQL query run against the real database, output recorded in the
      README (Sept 13, 2026).
- [x] CI actually green on GitHub — confirmed via an actual GitHub Actions run
      (`pipeline` job, status: success) after fixing an exit-126 failure caused by two
      scripts losing their git-tracked executable bit on a OneDrive-mounted Windows
      checkout (`git update-index --chmod=+x`, plus switching `ci.yml` to invoke them
      via `bash scripts/...` instead of `./scripts/...` so this can't recur the same way).
      The one warning on the run (Node.js 20 deprecation notice on `actions/checkout@v4`/
      `actions/setup-python@v5`) is a GitHub Actions runner-infrastructure notice, unrelated
      to this pipeline's correctness — not something this phase needs to fix.
- [ ] `v1.0` tag, only after the above two are both actually true.
