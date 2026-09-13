-- Phase 3, Step 2: MEASUREMENT mapping (staging.observation -> cdm.measurement)
-- Requires: 01_person.sql, 02_visit_occurrence.sql, load_concept_relationship.sh
-- already run. Safe to re-run: idempotent (ON CONFLICT DO NOTHING).

CREATE TABLE IF NOT EXISTS staging.observation_id_map (
    source_observation_id TEXT PRIMARY KEY,
    measurement_id INTEGER GENERATED ALWAYS AS IDENTITY
);

INSERT INTO staging.observation_id_map (source_observation_id)
SELECT resource_id FROM staging.observation
ON CONFLICT (source_observation_id) DO NOTHING;

-- ---------------------------------------------------------------------
-- SCOPE, checked and confirmed, not assumed: only 9,042 of 813,540
-- observations (1.1%) use real LOINC codes (system = http://loinc.org).
-- The other 98.9% use MIMIC's own local item dictionaries
-- (mimic-chartevents-d-items, mimic-d-labitems, mimic-d-items,
-- mimic-microbiology-*) -- confirmed via both the FHIR export AND the
-- base (non-FHIR) MIMIC-IV Clinical Database Demo that neither carries a
-- loinc_code crosswalk for these. measurement_concept_id is only
-- resolvable for the LOINC subset; the rest honestly get 0, not a
-- fabricated or text-matched guess. This is a real, documented limitation
-- of the source data, not a gap in this pipeline -- see README.
--
-- All 813,540 rows still get loaded regardless of concept mapping
-- success -- measurement_source_value/value_source_value preserve the
-- raw data either way. Concept mapping and row loading are separate
-- concerns.
--
-- value handling: value_as_number/unit_source_value come from
-- valueQuantity when present (labs, vitals); value_source_value falls
-- back to valueString, then valueCodeableConcept's display text, for
-- rows without a numeric value (exam findings, some microbiology
-- results) -- covers the 3 value shapes actually seen in this dataset.
-- range_low/range_high come from referenceRange when present (mainly lab
-- results) -- NULL otherwise, not fabricated.
--
-- value_source_value is LEFT(..., 50) -- cdm.measurement.value_source_value
-- is varchar(50) in the DDL (confirmed against sql/init/01_ddl.sql, not
-- guessed). Free-text findings (valueString / valueCodeableConcept display,
-- e.g. some microbiology and exam-finding rows) can run well past 50 chars
-- and the unmodified INSERT failed on this ("value too long for type
-- character varying(50)") on the first run. Truncating is a deliberate,
-- documented lossy step -- OMOP's schema treats this field as a short
-- label/code slot, not narrative text; the full original text isn't stored
-- anywhere else in this pipeline. Flag as a limitation in the README.
--
-- measurement_date/datetime come directly from effectiveDateTime --
-- Observation carries its own date, unlike Condition. Rows missing it
-- are excluded (see WHERE clause) rather than risk a NOT NULL insert
-- failure -- check the row-count diagnostic after running for how many.
--
-- measurement_type_concept_id = 32817 "EHR" -- generic, since this table
-- spans labs/vitals/exam findings with no single more specific Type
-- Concept fitting all of them.
--
-- visit_occurrence_id resolution: joins through staging.visit_id_map AND
-- THEN to cdm.visit_occurrence itself, not just the crosswalk. Found via
-- Phase 4 fixture testing, not assumed: staging.visit_id_map assigns an id
-- to every encounter unconditionally (Phase 2's crosswalk pattern), but
-- 02_visit_occurrence.sql's WHERE clause can exclude an encounter missing
-- period.start/end from ever landing in cdm.visit_occurrence. Resolving
-- visit_occurrence_id from the crosswalk alone (as an earlier version of
-- this file did) hands the INSERT a visit_occurrence_id that the crosswalk
-- promises exists but cdm.visit_occurrence doesn't actually have -- which
-- violates the FK constraint and aborts the ENTIRE INSERT (all 813,540
-- rows, one statement) over a single bad reference. In production this
-- never triggered (0/637 encounters were excluded), so it was invisible
-- until a synthetic fixture deliberately included one. Fix: LEFT JOIN
-- cdm.visit_occurrence and use ITS visit_occurrence_id (NULL if the visit
-- never actually loaded) -- safe because visit_occurrence_id is nullable
-- in MEASUREMENT, unlike CONDITION_OCCURRENCE's condition_start_date
-- (see docs/phase4-plan.md for why that one can't be fixed the same way).
-- ---------------------------------------------------------------------
WITH obs_codes AS (
    SELECT
        o.resource_id,
        o.resource->'subject'->>'reference' AS subject_ref,
        o.resource->'encounter'->>'reference' AS encounter_ref,
        o.resource->>'effectiveDateTime' AS effective_dt,
        o.resource->'code'->'coding'->0->>'code' AS raw_code,
        o.resource->'code'->'coding'->0->>'system' AS code_system,
        (o.resource->'valueQuantity'->>'value')::numeric AS value_as_number,
        o.resource->'valueQuantity'->>'unit' AS unit_source_value,
        (o.resource->'referenceRange'->0->'low'->>'value')::numeric AS range_low,
        (o.resource->'referenceRange'->0->'high'->>'value')::numeric AS range_high,
        LEFT(
            COALESCE(
                o.resource->>'valueString',
                o.resource->'valueCodeableConcept'->'coding'->0->>'display'
            ),
            50
        ) AS value_source_value
    FROM staging.observation o
    WHERE o.resource->>'effectiveDateTime' IS NOT NULL
),
source_concepts AS (
    SELECT oc.*, src.concept_id AS source_concept_id
    FROM obs_codes oc
    LEFT JOIN cdm.concept src
        ON oc.code_system = 'http://loinc.org'
        AND src.vocabulary_id = 'LOINC'
        AND src.concept_code = oc.raw_code
),
mapped_concepts AS (
    SELECT sc.*, cr.concept_id_2 AS standard_concept_id
    FROM source_concepts sc
    LEFT JOIN cdm.concept_relationship cr
        ON cr.concept_id_1 = sc.source_concept_id AND cr.relationship_id = 'Maps to'
)
INSERT INTO cdm.measurement (
    measurement_id,
    person_id,
    measurement_concept_id,
    measurement_date,
    measurement_datetime,
    measurement_type_concept_id,
    value_as_number,
    unit_source_value,
    range_low,
    range_high,
    visit_occurrence_id,
    measurement_source_value,
    measurement_source_concept_id,
    value_source_value
)
SELECT
    im.measurement_id,
    pm.person_id,
    COALESCE(mc.standard_concept_id, 0) AS measurement_concept_id,
    mc.effective_dt::date AS measurement_date,
    mc.effective_dt::timestamp AS measurement_datetime,
    32817 AS measurement_type_concept_id,
    mc.value_as_number,
    mc.unit_source_value,
    mc.range_low,
    mc.range_high,
    vo.visit_occurrence_id,
    mc.raw_code AS measurement_source_value,
    COALESCE(mc.source_concept_id, 0) AS measurement_source_concept_id,
    mc.value_source_value
FROM mapped_concepts mc
JOIN staging.observation_id_map im ON im.source_observation_id = mc.resource_id
JOIN staging.person_id_map pm ON pm.source_patient_id = split_part(mc.subject_ref, '/', 2)
LEFT JOIN staging.visit_id_map vm ON vm.source_encounter_id = split_part(mc.encounter_ref, '/', 2)
LEFT JOIN cdm.visit_occurrence vo ON vo.visit_occurrence_id = vm.visit_occurrence_id
ON CONFLICT (measurement_id) DO NOTHING;
