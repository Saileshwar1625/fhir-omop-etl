-- Phase 3, Step 1: CONDITION_OCCURRENCE mapping (staging.condition -> cdm.condition_occurrence)
-- Requires: 01_person.sql, 02_visit_occurrence.sql already run, AND
-- scripts/load_concept_relationship.sh already run (needs a 'Maps to'
-- -filtered cdm.concept_relationship in place -- this INSERT will silently
-- map everything to condition_concept_id = 0 without it, not error).
-- Safe to re-run: idempotent (ON CONFLICT DO NOTHING).

CREATE TABLE IF NOT EXISTS staging.condition_id_map (
    source_condition_id TEXT PRIMARY KEY,
    condition_occurrence_id INTEGER GENERATED ALWAYS AS IDENTITY
);

INSERT INTO staging.condition_id_map (source_condition_id)
SELECT resource_id FROM staging.condition
ON CONFLICT (source_condition_id) DO NOTHING;

-- ---------------------------------------------------------------------
-- condition_start_date/datetime: MIMIC's Condition resources carry no
-- date of their own (checked the full resource, not just .code) and are
-- always categorized "encounter-diagnosis" -- so this borrows the linked
-- Encounter's visit_start_date via the Phase 2 crosswalk + already-loaded
-- cdm.visit_occurrence. JUDGMENT CALL: the diagnosis is only known to
-- pertain to that encounter, not to any more specific date within it.
-- condition_end_date is left out entirely (stays NULL, nullable in the
-- DDL) -- no end/resolution data exists in the source.
--
-- condition_type_concept_id = 32827 "EHR encounter record" -- confirmed
-- present in your Type Concept vocab; chosen over the generic "EHR" (used
-- for visit_type_concept_id) because these conditions are specifically
-- encounter-linked diagnosis codes, not a general provenance flag.
--
-- condition_concept_id: raw ICD9CM/ICD10CM source code -> formatted with
-- a decimal after the 3rd character (confirmed against cdm.concept for
-- both vocabularies -- "5715"->"571.5", "K766"->"K76.6"; short codes like
-- "Z66" stay undotted) -> matched to its non-standard concept in
-- cdm.concept -> resolved to a standard SNOMED concept via
-- cdm.concept_relationship WHERE relationship_id = 'Maps to'.
-- condition_source_concept_id keeps the non-standard source concept
-- (what OMOP's own source_concept_id fields are for). Either step failing
-- to find a match defaults honestly to 0, not silently dropped.
-- ---------------------------------------------------------------------
WITH condition_codes AS (
    SELECT
        c.resource_id,
        c.resource->'subject'->>'reference' AS subject_ref,
        c.resource->'encounter'->>'reference' AS encounter_ref,
        c.resource->'code'->'coding'->0->>'code' AS raw_code,
        CASE c.resource->'code'->'coding'->0->>'system'
            WHEN 'http://mimic.mit.edu/fhir/mimic/CodeSystem/mimic-diagnosis-icd9'  THEN 'ICD9CM'
            WHEN 'http://mimic.mit.edu/fhir/mimic/CodeSystem/mimic-diagnosis-icd10' THEN 'ICD10CM'
            ELSE NULL
        END AS vocabulary_id,
        CASE
            WHEN length(c.resource->'code'->'coding'->0->>'code') > 3
                THEN substr(c.resource->'code'->'coding'->0->>'code', 1, 3) || '.' ||
                     substr(c.resource->'code'->'coding'->0->>'code', 4)
            ELSE c.resource->'code'->'coding'->0->>'code'
        END AS fmt_code
    FROM staging.condition c
),
source_concepts AS (
    SELECT cc.resource_id, cc.subject_ref, cc.encounter_ref, cc.raw_code,
           src.concept_id AS source_concept_id
    FROM condition_codes cc
    LEFT JOIN cdm.concept src
        ON src.vocabulary_id = cc.vocabulary_id AND src.concept_code = cc.fmt_code
),
mapped_concepts AS (
    SELECT sc.resource_id, sc.subject_ref, sc.encounter_ref, sc.raw_code,
           sc.source_concept_id,
           cr.concept_id_2 AS standard_concept_id
    FROM source_concepts sc
    LEFT JOIN cdm.concept_relationship cr
        ON cr.concept_id_1 = sc.source_concept_id AND cr.relationship_id = 'Maps to'
)
INSERT INTO cdm.condition_occurrence (
    condition_occurrence_id,
    person_id,
    condition_concept_id,
    condition_start_date,
    condition_start_datetime,
    condition_type_concept_id,
    visit_occurrence_id,
    condition_source_value,
    condition_source_concept_id
)
SELECT
    im.condition_occurrence_id,
    pm.person_id,
    COALESCE(mc.standard_concept_id, 0) AS condition_concept_id,
    v.visit_start_date,
    v.visit_start_datetime,
    32827 AS condition_type_concept_id,
    vm.visit_occurrence_id,
    mc.raw_code AS condition_source_value,
    COALESCE(mc.source_concept_id, 0) AS condition_source_concept_id
FROM mapped_concepts mc
JOIN staging.condition_id_map im ON im.source_condition_id = mc.resource_id
JOIN staging.person_id_map pm ON pm.source_patient_id = split_part(mc.subject_ref, '/', 2)
JOIN staging.visit_id_map vm ON vm.source_encounter_id = split_part(mc.encounter_ref, '/', 2)
JOIN cdm.visit_occurrence v ON v.visit_occurrence_id = vm.visit_occurrence_id
ON CONFLICT (condition_occurrence_id) DO NOTHING;
