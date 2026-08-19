# Design Doc (v0 — Phase 0)

**Goal.** Build a working ETL pipeline that maps FHIR clinical resources from the MIMIC-IV
Clinical Database Demo on FHIR (100 de-identified patients, PhysioNet) into the OMOP Common
Data Model v5.4, covering `PERSON`, `VISIT_OCCURRENCE`, `MEASUREMENT`, `CONDITION_OCCURRENCE`,
and — time permitting — `DRUG_EXPOSURE`. The pipeline runs against a local Postgres instance
(Docker Compose), is driven by Python for parsing/staging and SQL for the OMOP load, is
covered by automated tests (row counts, referential integrity, and concept-mapping coverage),
and runs in GitHub Actions CI on every push. Scope is deliberately narrow: two or three fully
working, tested tables are worth more than five stubbed-out ones. This document — along with
the repo's README — will be updated as design decisions are made or revised; nothing here is
final.

**Why this design.** FHIR is the interoperability standard EHR systems and wearables actually
emit; OMOP CDM is the standard analytic model used across the OHDSI network for real-world
evidence research. Building and honestly documenting a working FHIR→OMOP pipeline demonstrates
the specific infrastructure skill set (clinical data interoperability engineering) relevant to
PhD labs combining device-generated and EHR data — this project exists to be that evidence,
not to be impressive on paper.

**Status as of this commit.** Phase 0 only: Postgres running in Docker, OMOP CDM v5.4 DDL
(schema, tables, primary keys, foreign key constraints, indices) applied and verified against
a live database — see `sql/init/` and `scripts/verify_setup.sh`. No FHIR data has been parsed
or loaded yet. See the README's Completed / In Progress / Planned sections for the current,
honest state.
