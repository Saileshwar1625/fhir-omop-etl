# FHIR → OMOP CDM ETL Pipeline — Project Plan

Single source of truth for the whole roadmap. Per-phase docs (`docs/phase1-plan.md`,
`docs/phase2-plan.md`, etc.) have the step-by-step detail for each phase; this file is
the map of how they fit together and what's actually done versus planned. If this file
and a phase doc ever disagree on status, this file wins — update it whenever a phase
closes out.

## What this project is

An ETL pipeline mapping FHIR clinical resources (MIMIC-IV Clinical Database Demo on
FHIR, 100 de-identified patients) into the OMOP Common Data Model v5.4. Portfolio
project — demonstrates competency with a real interoperability standard (FHIR) and a
real research data model (OMOP), not novel research itself. See `docs/design-doc.md`
for the original one-paragraph framing.

## v1 scope

**In scope:** `Patient`, `Encounter`, `Condition`, `Observation` FHIR resources →
`PERSON`, `VISIT_OCCURRENCE`, `CONDITION_OCCURRENCE`, `MEASUREMENT` OMOP tables.

**Stretch (attempt only if time allows):** `MedicationRequest`/`MedicationAdministration`
→ `DRUG_EXPOSURE`.

**Explicitly out of scope for v1:** `Location`, `Organization`, `Provider` FHIR
resources and their OMOP counterparts (`LOCATION`, `CARE_SITE`, `PROVIDER`) —
`location_id`/`provider_id`/`care_site_id` stay `NULL` throughout.

## Timeline

Target: PhD-application-ready (v1.0 tagged, able to defend every design decision) well
before the December 2026 application deadline, with November reserved for interview
prep, not pipeline work. ~10–15 hrs/week available.

| Phase | Target | Actual | Status |
|---|---|---|---|
| 0 — Setup | — | ~Aug 18, 2026 *(from file timestamps — confirm exact date)* | Completed |
| 1 — Ingestion / Staging | — | ~Aug 19–24, 2026 *(confirm exact date)* | Completed |
| 2 — PERSON + VISIT_OCCURRENCE | Sept 1, 2026 | **Aug 26, 2026** | Completed (ahead of target) |
| 3 — Concept Mapping | ~Sept 15, 2026 | **~Sept 1, 2026** (committed to git Sept 10) | Completed |
| 4 — Testing, CI, `v1.0` | ~Oct 15, 2026 | — | In progress (started Sept 10) |
| Interview prep | Nov 1 – Dec 2026 | — | Scheduled |

Note on Phase 3: the transform SQL and scripts were written and verified against the
database around Sept 1, but sat uncommitted on disk for over a week — `git log` showed
only Phase 0–2 as of Sept 10, and `docs/phase3-plan.md`/this file weren't even saved to
disk yet. Caught by directly auditing `git log`/`git status`/the filesystem before
starting Phase 4, rather than trusting the earlier chat summary. Lesson for the rest of
this project: commit at the end of the session a phase's work happens in, not "later."

## Phases

### Phase 0 — Setup — **Completed** (~Aug 18, 2026)
Docker Postgres 16, full OMOP CDM v5.4 DDL applied (39 tables, PKs, FKs, indices).
Verified via `scripts/verify_setup.sh`. Doc: `docs/design-doc.md`.

### Phase 1 — Ingestion / Staging — **Completed** (~Aug 19–24, 2026)
FHIR NDJSON → `staging` schema (JSONB, one table per resource type). 100 patients, 637
encounters, 5,051 conditions, 813,540 observations. Row counts independently verified
against source file line counts (`scripts/verify_row_counts.py`); profiled (missingness,
reference format, orphan check). Doc: `docs/phase1-plan.md`. Script:
`scripts/load_staging.py`.

### Phase 2 — PERSON + VISIT_OCCURRENCE — **Completed** (Aug 26, 2026, ahead of the Sept 1 target)
Mapped and loaded `staging.patient` → `cdm.person` (100 rows) and `staging.encounter` →
`cdm.visit_occurrence` (637 rows). Required an unplanned detour: every OMOP
`_concept_id` column FKs to `cdm.concept`, which had to be loaded from Athena first
(`scripts/load_vocab.sh`) before either table could accept a single row. Introduced the
ID crosswalk pattern (`staging.person_id_map`, `staging.visit_id_map`) that later phases
reuse. Doc: `docs/phase2-plan.md`. SQL: `sql/transform/01_person.sql`,
`sql/transform/02_visit_occurrence.sql`.

### Phase 3 — Concept Mapping — **Completed** (~Sept 1, 2026)
Mapped source codes to standard OMOP concepts and loaded the two remaining in-scope
clinical tables:
- `staging.condition` → `cdm.condition_occurrence`: 5,051 rows, 96.5% concept-mapped to
  standard SNOMED via ICD9CM/ICD10CM → `CONCEPT_RELATIONSHIP` `'Maps to'`.
- `staging.observation` → `cdm.measurement`: 813,540 rows, 1.11% concept-mapped — a
  source-data ceiling (only 9,042 observations carry a real LOINC code at all; the rest
  use MIMIC's own local item dictionaries with no LOINC crosswalk anywhere, confirmed
  against both the FHIR export and the base MIMIC-IV Clinical Database Demo). All 9,042
  LOINC-coded rows mapped successfully — 100% within the mappable subset.

`scripts/load_concept_relationship.sh` (loads `RELATIONSHIP` + a `'Maps to'`-filtered
`CONCEPT_RELATIONSHIP`, skipped deliberately in Phase 2) was the prerequisite. Both
transforms reuse the Phase 2 ID-crosswalk pattern — no new crosswalk mechanism needed.
Doc: `docs/phase3-plan.md`. SQL: `sql/transform/03_condition_occurrence.sql`,
`sql/transform/04_measurement.sql`.

Stretch, not attempted: `DRUG_EXPOSURE` — medication resources were deliberately
excluded from Phase 1 scope (see `scripts/load_staging.py`), so the staging tables it
would need don't exist.

### Phase 4 — Testing, CI, Release — **In progress** (started Sept 10, 2026; target ~Oct 15, 2026)
Automated tests in CI (GitHub Actions), one demonstration SQL query showing the
pipeline answering a real question, `v1.0` tag. (Concept-mapping coverage % — originally
scoped for this phase — is already reported in the README and `docs/phase3-plan.md`,
ahead of schedule.)

Key constraint driving the CI design: OHDSI Athena vocabulary downloads require
individual license acceptance and can't be auto-fetched or redistributed in CI. CI
instead runs the full pipeline (DDL → staging load → transforms → concept mapping)
against a small, hand-built synthetic fixture — fake FHIR resources and a structurally
valid but made-up vocabulary subset (no real SNOMED/LOINC content, so no licensing
issue) — and asserts exact expected outputs. See `docs/phase4-plan.md` once written.

### Stretch (post-v1.0)
Extend to a wearable-native source (WESAD or PPG-DaLiA) — physiological signals mapped
into FHIR `Observation`/`Device`, then into `MEASUREMENT`. Not started, not required for
v1.

## Where things live

| Doc | Covers | Committed to repo? |
|---|---|---|
| `docs/design-doc.md` | Original 1-paragraph project framing | Yes |
| `docs/project-plan.md` | This file — full roadmap, phase status | Yes (as of Sept 10 cleanup) |
| `docs/phase1-plan.md` | Phase 1 step-by-step | Yes |
| `docs/phase2-plan.md` | Phase 2 step-by-step, incl. vocab-load detour | Yes |
| `docs/phase3-plan.md` | Phase 3 step-by-step | Yes (as of Sept 10 cleanup) |
| `docs/phase4-plan.md` | Phase 4 step-by-step (CI fixture design) | Not written yet |
| `docs/phase1-explanation.md` | Personal build log / interview prep, full code + reasoning | No — study doc only |
| `docs/concepts-glossary.md` | FHIR/OMOP/OHDSI term reference | No — study doc only |
| `README.md` | Live, high-level status snapshot for anyone landing on the repo | Yes |
