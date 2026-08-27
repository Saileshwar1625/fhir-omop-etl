-- Phase 2, Step 1: PERSON mapping (staging.patient -> cdm.person)
-- Read alongside docs/phase2-plan.md for the reasoning behind each field.
-- Safe to re-run: both inserts are idempotent (ON CONFLICT DO NOTHING).

-- ---------------------------------------------------------------------
-- ID crosswalk: FHIR Patient.id (string) -> OMOP person_id (integer).
-- Every table that later needs to resolve a "Patient/xxx" reference into
-- a person_id FK (VISIT_OCCURRENCE next, CONDITION_OCCURRENCE/MEASUREMENT/
-- DRUG_EXPOSURE later) joins through this table.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.person_id_map (
    source_patient_id TEXT PRIMARY KEY,
    person_id INTEGER GENERATED ALWAYS AS IDENTITY
);

INSERT INTO staging.person_id_map (source_patient_id)
SELECT resource_id FROM staging.patient
ON CONFLICT (source_patient_id) DO NOTHING;

-- ---------------------------------------------------------------------
-- Pull race/ethnicity out of the US Core extension array before the main
-- insert. FHIR's base Patient resource has no race/ethnicity field --
-- MIMIC-FHIR carries both via the us-core-race / us-core-ethnicity
-- extensions, each shaped as:
--   {"url": ".../us-core-race", "extension": [{"url": "ombCategory",
--     "valueCoding": {"code": "2106-3", "display": "White", ...}}, ...]}
-- i.e. an extension *inside* an extension. jsonb_array_elements() unnests
-- the outer array, then the inner one; the WHERE clauses pick out the
-- specific entries we want. A patient with no such extension just
-- produces zero rows here (not an error) -- handled below with LEFT JOIN.
-- ---------------------------------------------------------------------
WITH race_ext AS (
    SELECT p.resource_id, inner_ext->'valueCoding'->>'code' AS race_code
    FROM staging.patient p,
         jsonb_array_elements(p.resource->'extension') AS outer_ext,
         jsonb_array_elements(outer_ext->'extension') AS inner_ext
    WHERE outer_ext->>'url' = 'http://hl7.org/fhir/us/core/StructureDefinition/us-core-race'
      AND inner_ext->>'url' = 'ombCategory'
),
ethnicity_ext AS (
    SELECT p.resource_id, inner_ext->'valueCoding'->>'code' AS ethnicity_code
    FROM staging.patient p,
         jsonb_array_elements(p.resource->'extension') AS outer_ext,
         jsonb_array_elements(outer_ext->'extension') AS inner_ext
    WHERE outer_ext->>'url' = 'http://hl7.org/fhir/us/core/StructureDefinition/us-core-ethnicity'
      AND inner_ext->>'url' = 'ombCategory'
)
-- ---------------------------------------------------------------------
-- cdm.person
-- ---------------------------------------------------------------------
INSERT INTO cdm.person (
    person_id,
    gender_concept_id,
    year_of_birth,
    month_of_birth,
    day_of_birth,
    birth_datetime,
    race_concept_id,
    ethnicity_concept_id,
    person_source_value,
    gender_source_value,
    race_source_value,
    ethnicity_source_value
)
SELECT
    m.person_id,
    -- Confirmed against your actually-loaded cdm.concept, not hardcoded from
    -- memory: SELECT concept_id, concept_name, concept_code FROM cdm.concept
    -- WHERE vocabulary_id = 'Gender' -- returned exactly these five.
    CASE p.resource->>'gender'
        WHEN 'male'    THEN 8507   -- MALE
        WHEN 'female'  THEN 8532   -- FEMALE
        WHEN 'other'   THEN 8521   -- OTHER
        WHEN 'unknown' THEN 8551   -- UNKNOWN
        ELSE 0                     -- "No matching concept" -- honest default
    END AS gender_concept_id,
    EXTRACT(YEAR  FROM (p.resource->>'birthDate')::date)::int AS year_of_birth,
    EXTRACT(MONTH FROM (p.resource->>'birthDate')::date)::int AS month_of_birth,
    EXTRACT(DAY   FROM (p.resource->>'birthDate')::date)::int AS day_of_birth,
    (p.resource->>'birthDate')::date AS birth_datetime,
    -- race_concept_id/ethnicity_concept_id start at 0 here and get resolved
    -- by the UPDATE statements below, once cdm.concept is loaded -- see
    -- those for why this is a JOIN on concept_code, not a hardcoded CASE.
    0 AS race_concept_id,
    0 AS ethnicity_concept_id,
    p.resource_id AS person_source_value,
    p.resource->>'gender' AS gender_source_value,
    r.race_code AS race_source_value,
    e.ethnicity_code AS ethnicity_source_value
FROM staging.patient p
JOIN staging.person_id_map m ON m.source_patient_id = p.resource_id
LEFT JOIN race_ext r ON r.resource_id = p.resource_id
LEFT JOIN ethnicity_ext e ON e.resource_id = p.resource_id
ON CONFLICT (person_id) DO NOTHING;

-- ---------------------------------------------------------------------
-- Backfill race_concept_id / ethnicity_concept_id.
--
-- ORIGINALLY this was a dynamic JOIN on concept_code (see git history) --
-- the idea being "match whatever OMB code the source has against whatever
-- concept_code is in the loaded vocab." That failed for everything except
-- 'UNK': querying cdm.concept directly showed WHITE's concept_code is '5',
-- not '2106-3' -- OMOP's Race/Ethnicity vocabularies use their own short
-- internal codes, not the raw CDC/OMB code FHIR's us-core extensions
-- carry. There's no formula from one to the other, so this is now an
-- explicit CASE built from concept_ids confirmed by directly querying
-- cdm.concept for each code that actually appears in this dataset (see
-- docs/phase2-plan.md for the query results):
--   race_source_value:      '2106-3' White (72), 'UNK' Unknown (17),
--                            '2054-5' Black or African American (10),
--                            'ASKU' Asked-but-unknown (1)
--   ethnicity_source_value: '2186-5' Not Hispanic (77), '2135-2' Hispanic (5),
--                            NULL -- no extension present (18)
--
-- 'ASKU' has no matching concept anywhere in the loaded vocabulary --
-- confirmed empty result querying for it directly. That one patient's
-- race_concept_id honestly stays 0. Not a bug; a real, small, documented
-- gap (1/100 patients) -- see README limitations.
-- ---------------------------------------------------------------------
UPDATE cdm.person
SET race_concept_id = CASE race_source_value
    WHEN '2106-3' THEN 8527   -- White
    WHEN '2054-5' THEN 8516   -- Black or African American
    WHEN 'UNK'    THEN 8552   -- Unknown
    ELSE race_concept_id      -- e.g. 'ASKU' -- no matching concept, stays 0
END
WHERE race_source_value IS NOT NULL;

UPDATE cdm.person
SET ethnicity_concept_id = CASE ethnicity_source_value
    WHEN '2186-5' THEN 38003564   -- Not Hispanic or Latino
    WHEN '2135-2' THEN 38003563   -- Hispanic or Latino
    ELSE ethnicity_concept_id
END
WHERE ethnicity_source_value IS NOT NULL;
