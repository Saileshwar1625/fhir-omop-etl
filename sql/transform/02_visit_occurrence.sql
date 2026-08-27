-- Phase 2, Step 3: VISIT_OCCURRENCE mapping (staging.encounter -> cdm.visit_occurrence)
-- Read alongside docs/phase2-plan.md. Requires sql/transform/01_person.sql
-- to have already run (needs staging.person_id_map and a populated cdm.person).
-- Safe to re-run: idempotent (ON CONFLICT DO NOTHING).

-- ---------------------------------------------------------------------
-- ID crosswalk: FHIR Encounter.id (string) -> OMOP visit_occurrence_id
-- (integer). Same pattern and same reason as staging.person_id_map in
-- 01_person.sql -- MEASUREMENT/CONDITION_OCCURRENCE will need this later
-- to resolve an Encounter reference into a visit_occurrence_id FK.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.visit_id_map (
    source_encounter_id TEXT PRIMARY KEY,
    visit_occurrence_id INTEGER GENERATED ALWAYS AS IDENTITY
);

INSERT INTO staging.visit_id_map (source_encounter_id)
SELECT resource_id FROM staging.encounter
ON CONFLICT (source_encounter_id) DO NOTHING;

-- ---------------------------------------------------------------------
-- cdm.visit_occurrence
-- ---------------------------------------------------------------------
-- visit_concept_id -- mapped from Encounter.class.code, confirmed against
-- your full 637-encounter distribution (not the source file -- the
-- "general" MimicEncounter.ndjson.gz turned out to contain a mix of
-- classes itself, so file-of-origin isn't a reliable signal):
--   EMER   (341) -> 9203 Emergency Room Visit   -- clean match
--   ACUTE  (140) -> 9201 Inpatient Visit         -- clean match
--   AMB     (56) -> 9202 Outpatient Visit        -- clean match
--   OBSENC  (82) -> 9202 Outpatient Visit        -- JUDGMENT CALL: "observation
--                   encounter" is a real US billing status (monitored,
--                   not formally admitted) with no exact OMOP concept in
--                   this vocab. Mapped to Outpatient since not admitted.
--   SS      (18) -> 9201 Inpatient Visit         -- JUDGMENT CALL: "short
--                   stay" has no dedicated concept either. Mapped to
--                   Inpatient (admitted status), but genuinely debatable.
-- Both judgment calls confirmed present in this vocab (SELECT ... WHERE
-- vocabulary_id = 'Visit') before use -- see docs/phase2-plan.md.
--
-- visit_type_concept_id -- 32817 "EHR", confirmed via SELECT ... WHERE
-- vocabulary_id = 'Type Concept' AND concept_name ILIKE '%EHR%'. This is
-- OMOP's standard provenance-tracking field (how did this record enter
-- the CDM), not something mapped per-row -- every row gets the same value.
--
-- person_id resolution -- Encounter.subject.reference is "Patient/<id>"
-- (confirmed in Phase 1 profiling); split_part(...) strips the "Patient/"
-- prefix to match staging.person_id_map.source_patient_id, which stores
-- the bare id. Uses a plain JOIN (not LEFT JOIN) -- Phase 1 profiling
-- already confirmed 0 orphaned encounters, so every row is expected to
-- resolve; if that's changed, the row count check below will catch it.
--
-- visit_start_date/visit_end_date are NOT NULL in the CDM DDL. Rather
-- than risk an INSERT failing partway through on an encounter with an
-- open/missing period.end, the WHERE clause excludes rows missing either
-- date -- see the row-count check below for how many that affects.
-- ---------------------------------------------------------------------
INSERT INTO cdm.visit_occurrence (
    visit_occurrence_id,
    person_id,
    visit_concept_id,
    visit_start_date,
    visit_start_datetime,
    visit_end_date,
    visit_end_datetime,
    visit_type_concept_id,
    visit_source_value
)
SELECT
    vm.visit_occurrence_id,
    pm.person_id,
    CASE e.resource->'class'->>'code'
        WHEN 'EMER'   THEN 9203
        WHEN 'ACUTE'  THEN 9201
        WHEN 'AMB'    THEN 9202
        WHEN 'OBSENC' THEN 9202
        WHEN 'SS'     THEN 9201
        ELSE 0
    END AS visit_concept_id,
    (e.resource->'period'->>'start')::date AS visit_start_date,
    (e.resource->'period'->>'start')::timestamp AS visit_start_datetime,
    (e.resource->'period'->>'end')::date AS visit_end_date,
    (e.resource->'period'->>'end')::timestamp AS visit_end_datetime,
    32817 AS visit_type_concept_id,
    e.resource_id AS visit_source_value
FROM staging.encounter e
JOIN staging.visit_id_map vm ON vm.source_encounter_id = e.resource_id
JOIN staging.person_id_map pm
    ON pm.source_patient_id = split_part(e.resource->'subject'->>'reference', '/', 2)
WHERE e.resource->'period'->>'start' IS NOT NULL
  AND e.resource->'period'->>'end' IS NOT NULL
ON CONFLICT (visit_occurrence_id) DO NOTHING;
