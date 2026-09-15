# Phase 2 Plan — PERSON + VISIT_OCCURRENCE

Goal (from the brief): map and load `PERSON` (from `staging.patient`) and
`VISIT_OCCURRENCE` (from `staging.encounter`) into the `cdm` schema, with real
tests (row counts, referential integrity, no orphaned visits). Concept mapping
for `MEASUREMENT`/`CONDITION_OCCURRENCE` is Phase 3 — don't start it here.

One outstanding item before this starts: confirm the README edit from Phase 1
was actually pasted in and committed. If it wasn't yet, do that first — don't
let Phase 2 work pile up on top of an unconfirmed Phase 1 close-out.

## Why this phase is SQL, not Python

Phase 1 was the **L** (load) — Python, because you're doing IO: reading
compressed files off disk, one JSON object per line, inserting rows. Phase 2
is the **T** (transform) — you already have every FHIR resource sitting in
Postgres as JSONB. Reading JSON out of a JSONB column, reshaping it, and
writing it into another table in the same database is exactly what SQL is
for. Round-tripping that through Python (SELECT into Python, transform in
Python, INSERT back) would just be slower and more code for no benefit. This
is the ELT split in `docs/concepts-glossary.md` playing out for real: raw
data landed first (Phase 1), transformed in-database second (Phase 2+).

## The one new concept: ID crosswalks

FHIR `Patient.id` is a string UUID. OMOP's `person_id` is required to be an
`integer` (see `cdm.person` DDL — `person_id integer NOT NULL`). Every OMOP
table that references a person does so via that integer, not the source
system's original ID. So before you can write a single row into `cdm.person`,
you need a stable mapping from "FHIR patient string ID" to "OMOP integer
person_id" — and that same mapping gets reused by every other table that
needs to resolve a `Patient/xxx` reference into a `person_id` FK
(`VISIT_OCCURRENCE` today, `CONDITION_OCCURRENCE`/`MEASUREMENT`/
`DRUG_EXPOSURE` later).

This is not a MIMIC-specific hack — every real-world source-to-OMOP ETL faces
this, because essentially no source system natively uses OMOP's own integer
keys. The standard pattern is a small crosswalk table: one row per source
entity, an auto-generated integer as the OMOP-side key. `sql/transform/01_person.sql`
below creates one (`staging.person_id_map`) and builds it with
`GENERATED ALWAYS AS IDENTITY` so IDs are assigned once and stay stable across
reruns (the `INSERT ... ON CONFLICT DO NOTHING` means re-running the script
doesn't reassign or duplicate anything).

You'll build a second crosswalk (`staging.visit_id_map`) for
`visit_occurrence_id` when you get to Step 2, for the same reason —
`OBSERVATION`/`CONDITION_OCCURRENCE` will eventually need to resolve an
`Encounter` reference into a `visit_occurrence_id`.

## Step 1 — PERSON

File: `sql/transform/01_person.sql` (given below, run it as-is first, then
read through it against this explanation).

Field-by-field decisions:

- **`gender_concept_id`** — mapped from FHIR `Patient.gender` via a fixed
  `CASE`: `male` → `8507`, `female` → `8532`, anything else → `0`. These two
  concept IDs are part of OMOP's stable Gender vocabulary and don't change —
  safe to hardcode rather than look up, even before the vocabulary tables are
  loaded in Phase 3.
- **`year_of_birth`/`month_of_birth`/`day_of_birth`/`birth_datetime`** —
  parsed straight out of `Patient.birthDate` (format `YYYY-MM-DD`). Your
  Phase 1 profiling already confirmed 0 missing `birthDate` values, so no
  NULL-handling branch is needed for this dataset — but note in your own
  head that a real-world source with partial dates (year-only, e.g.) would
  need one.
- **`race_concept_id`/`ethnicity_concept_id`** — hardcoded to `0`
  ("No matching concept") **for now, deliberately, not out of laziness**.
  Checking `resource->'extension'` confirmed MIMIC's Patient resources *do*
  carry real race/ethnicity via US Core extensions (OMB category codes like
  `2106-3` = White, `2186-5` = Not Hispanic or Latino). But mapping those
  codes to OMOP `concept_id`s requires joining against `cdm.concept`, which
  isn't populated until Phase 3 (vocab load). Rather than hardcode concept
  IDs from memory into a script meant to be defensible in an interview, the
  SQL captures the raw OMB codes into `race_source_value`/
  `ethnicity_source_value` now (pulled out of the nested extension array via
  `jsonb_array_elements`) and leaves `race_concept_id`/`ethnicity_concept_id`
  at `0` until Phase 3, when a follow-up `UPDATE` can join
  `race_source_value` against `cdm.concept.concept_code` where
  `vocabulary_id = 'Race'` to resolve the real concept IDs. This is the
  standard OMOP ETL pattern for a field you have raw but can't yet map:
  preserve the source value, defer concept resolution — not a shortcut.
- **`location_id`/`provider_id`/`care_site_id`** — left `NULL`. `Location`
  and `Organization` FHIR resources aren't in your v1 scope.
- **`person_source_value`** — the original FHIR `Patient.id`, so you can
  always trace an OMOP row back to its source.

Run it:
```
docker exec -i omop_postgres psql -U omop_admin -d omop_cdm < sql/transform/01_person.sql
```

## Step 2 — Verify PERSON before touching VISIT_OCCURRENCE

Don't move on until these check out — same discipline as Phase 1's row-count
verification:

```sql
-- row count must match staging.patient (100)
SELECT count(*) FROM cdm.person;

-- gender distribution -- sanity check the CASE mapping did what you expect
SELECT gender_concept_id, count(*) FROM cdm.person GROUP BY 1;

-- every person_id in cdm.person should trace back to a real crosswalk entry
SELECT count(*) FROM cdm.person p
WHERE NOT EXISTS (
    SELECT 1 FROM staging.person_id_map m WHERE m.person_id = p.person_id
);
-- expect 0
```

## Step 3 — VISIT_OCCURRENCE

`sql/transform/02_visit_occurrence.sql`. `visit_concept_id` is mapped from
`Encounter.class.code`, not source file — the "general" `MimicEncounter`
file turned out to contain a mix of classes itself, so file-of-origin
wasn't a reliable signal (checked before writing the mapping, not assumed).
Full distribution across all 637 encounters: `EMER`(341)→`9203` Emergency
Room Visit, `ACUTE`(140)→`9201` Inpatient Visit, `AMB`(56)→`9202`
Outpatient Visit — all clean matches. `OBSENC`(82)→`9202` and `SS`(18)→
`9201` are judgment calls (no exact OMOP concept for either "observation
status" or "short stay" in this vocab) — defensible, but be ready to
explain them, not just cite them.

`person_id` resolves via `Encounter.subject.reference` (`"Patient/<id>"`,
format confirmed in Phase 1 profiling) joined against
`staging.person_id_map`. `visit_type_concept_id` is a fixed `32817` ("EHR"),
confirmed present in the loaded `Type Concept` vocabulary before use.

## Unplanned but necessary: the vocabulary load

Not in the original Phase 2 plan — `PERSON`/`VISIT_OCCURRENCE` inserts
failed on FK violations because every `_concept_id` column in OMOP
references `cdm.concept`, which was empty. Loading it turned into its own
mini-project: `scripts/load_vocab.sh` (drops/reloads/re-adds 6 circular FK
constraints among `CONCEPT`/`VOCABULARY`/`DOMAIN`/`CONCEPT_CLASS`, loads
those 4 tables only — not `CONCEPT_ANCESTOR`/`CONCEPT_RELATIONSHIP`/
`CONCEPT_SYNONYM`/`DRUG_STRENGTH`, which nothing in Phase 2 needs). The
Athena selection also had to be redone once — the first download was
missing `Gender`/`Race`/`Ethnicity` entirely. Treat this as infrastructure
setup (like Phase 0's DDL), not Phase 3's actual concept-mapping work.

Race/ethnicity concept resolution ended up happening here too, once the
vocab was loaded — not deferred to Phase 3 as originally planned. First
attempt (a dynamic `JOIN` on `concept_code`) failed for everything except
`'UNK'`: querying `cdm.concept` directly showed `White`'s `concept_code` is
`'5'`, not the raw CDC/OMB code `'2106-3'` FHIR provides — OMOP's
Race/Ethnicity vocabularies use their own internal codes, no formula
translates one to the other. Fixed with an explicit `CASE`, each value
confirmed by querying `cdm.concept` directly, not assumed. `ASKU`
(Asked-but-unknown, 1 patient) has no matching concept anywhere in the
loaded vocabulary — genuinely unmapped, `race_concept_id` stays `0` for
that one patient. Real, small, documented gap — see README limitations.

## Definition of done for Phase 2

- [x] `cdm.person` loaded (100 rows), row count verified against
      `staging.patient`, gender/race/ethnicity concept_ids resolved and
      confirmed against real distributions (72/17/10/1 race, 77/18/5
      ethnicity — reconciles exactly).
- [x] `cdm.visit_occurrence` loaded (637 rows), row count verified against
      `staging.encounter`, 0 orphaned visits (every `person_id` resolves),
      `visit_concept_id` distribution (158/138/341) reconciles exactly
      against the source `class.code` distribution.
- [ ] README's Phase 2 line moved from Planned to Completed.
- [ ] Concept mapping for `MEASUREMENT`/`CONDITION_OCCURRENCE` explicitly
      left as "started, not finished" or not started at all — that's fine,
      it's Phase 3 scope per the brief.
