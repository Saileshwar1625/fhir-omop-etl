# Phase 3 Plan — Concept Mapping

Goal (from the brief): map source codes to standard OMOP concepts and load
`CONDITION_OCCURRENCE` and `MEASUREMENT` — the two remaining in-scope
clinical tables. `DRUG_EXPOSURE` is stretch only.

## Prerequisite: CONCEPT_RELATIONSHIP

Mapping a source code (ICD9CM/ICD10CM, LOINC-adjacent codes) to a standard
concept (SNOMED, LOINC) isn't a formula — it's a lookup in
`CONCEPT_RELATIONSHIP` where `relationship_id = 'Maps to'`. Phase 2's vocab
load deliberately skipped this table (1.6GB, nothing needed it yet).
`scripts/load_concept_relationship.sh` loads `RELATIONSHIP` (tiny, a hard
FK dependency of `CONCEPT_RELATIONSHIP`) and a `'Maps to'`-filtered
`CONCEPT_RELATIONSHIP` (filtered with `awk` before loading — the full file
has many relationship types not needed here — 722 / 1,258,122 rows loaded).

## Step 1 — CONDITION_OCCURRENCE — **Completed**

`sql/transform/03_condition_occurrence.sql`. Key findings, not assumptions:

- MIMIC's `Condition` resources carry **no date field of their own** —
  checked the full resource, not just `.code`. Always categorized
  `"encounter-diagnosis"`, always linked via `.encounter`. **Judgment
  call**: `condition_start_date`/`datetime` borrow the linked visit's
  `visit_start_date` from the already-loaded `cdm.visit_occurrence`.
  `condition_end_date` stays genuinely `NULL` — no resolution data exists,
  and assuming discharge = resolution isn't supportable for a chronic
  diagnosis.
- `condition_type_concept_id = 32827` ("EHR encounter record") — chosen
  over the generic `32817` ("EHR") used for `VISIT_OCCURRENCE`, since these
  are specifically encounter-linked diagnosis codes.
- ICD9CM/ICD10CM raw codes need a decimal inserted after the 3rd character
  to match `cdm.concept.concept_code` (`"5715"` → `"571.5"`, `"K766"` →
  `"K76.6"`; short codes like `"Z66"` stay undotted) — confirmed against
  the real vocabulary for both code systems before writing the transform,
  not assumed from one.
- Source concept resolved from `cdm.concept` (formatted code + correct
  vocabulary_id from the FHIR `system` URI), then resolved to a standard
  SNOMED concept via `CONCEPT_RELATIONSHIP` `'Maps to'`.

**Verified**: 5,051 rows loaded (matches `staging.condition` exactly, 0
dropped), 0 orphaned `person_id`/`visit_occurrence_id` references. 179/5,051
(~3.5%) have `condition_concept_id = 0` — no `'Maps to'` target exists for
those specific codes (largely administrative/status codes like "Do not
resuscitate status" that don't correspond to a disease concept). Mapped
coverage: 4,872/5,051 = **96.5%**.

## Step 2 — MEASUREMENT — **Completed**

`sql/transform/04_measurement.sql`. `staging.observation` (813,540 rows
across 9 source files — chartevents, datetimeevents, ED, labevents, 3
microbiology files, outputevents, vitalsigns ED) → `cdm.measurement`.

Scope, checked before writing any SQL, not assumed: only 9,042/813,540
(1.1%) of these observations carry a real LOINC code (`system =
'http://loinc.org'`). The remaining 98.9% use MIMIC's own local item
dictionaries (chartevents-d-items, d-labitems, d-items, microbiology) —
confirmed via both the FHIR export's code systems AND the base (non-FHIR)
MIMIC-IV Clinical Database Demo's `d_labitems.csv.gz`/`d_items.csv.gz`
headers, neither of which carries a `loinc_code` crosswalk. This is a real
limitation of the source data, investigated and confirmed, not a shortcut
taken to avoid the work. All 813,540 rows still load regardless of concept
mapping outcome — `measurement_source_value`/`value_source_value` preserve
the raw data either way; concept mapping and row loading are separate
concerns.

Other decisions:

- `measurement_date`/`datetime` come directly from `effectiveDateTime` —
  Observation carries its own date, unlike Condition. Rows missing it would
  have been excluded (`WHERE ... IS NOT NULL`); confirmed 0 were.
- Value handling covers the 3 shapes actually seen in this dataset:
  `value_as_number`/`unit_source_value` from `valueQuantity` (labs, vitals);
  `value_source_value` falls back to `valueString`, then
  `valueCodeableConcept`'s display text, for rows without a numeric value.
  `range_low`/`range_high` from `referenceRange` when present, `NULL`
  otherwise.
- **Bug found and fixed during the first run**: `cdm.measurement.
  value_source_value` is `varchar(50)` in the DDL; free-text findings
  (some microbiology/exam-finding rows) ran past 50 chars and the
  unmodified INSERT failed with `value too long for type character
  varying(50)`. Fixed with `LEFT(..., 50)` — a deliberate, documented lossy
  truncation, not a silent one. OMOP's schema treats this field as a short
  label slot, not narrative text; the untruncated original isn't preserved
  anywhere else in this pipeline.
- `measurement_type_concept_id = 32817` "EHR" — generic, since this table
  spans labs/vitals/exam findings with no single more specific Type Concept
  fitting all of them.

**Verified**: 813,540/813,540 rows loaded (0 excluded — every row had an
`effectiveDateTime`), 0 orphaned `person_id`/`visit_occurrence_id`
references. 9,042/813,540 mapped = **1.11%** — and notably, all 9,042 of
the true-LOINC-coded rows resolved to a standard concept via `'Maps to'`
(mapped count == LOINC-coded count exactly), so within the mappable subset,
coverage is 100%; the ceiling is the source data, not the mapping logic.

## Definition of done for Phase 3

- [x] `cdm.condition_occurrence` loaded and verified (5,051 rows, 96.5%
      concept-mapped).
- [x] `cdm.measurement` loaded and verified (813,540 rows, 1.11%
      concept-mapped — source-data ceiling, not a mapping gap).
- [x] Concept-mapping coverage % (per table) reported here and in the
      README.
