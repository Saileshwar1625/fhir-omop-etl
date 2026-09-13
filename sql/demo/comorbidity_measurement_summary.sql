-- Phase 4 demonstration query: "For each standard diagnosis, how many
-- patients have it, and how many measurements were typically recorded
-- during the visit where it was diagnosed?"
--
-- This is a genuine RWE-style first-pass question -- the kind you'd run to
-- sanity-check whether a diagnosis is well-instrumented with lab/vital data
-- before building a cohort definition or predictive model around it. It
-- only works because Phase 2's ID crosswalks and Phase 3's concept mapping
-- are both correct: it joins CONDITION_OCCURRENCE -> CONCEPT (for the
-- human-readable name) -> VISIT_OCCURRENCE -> MEASUREMENT, tables built
-- across three different phases of this project.
--
-- Restricted to condition_concept_id != 0 (mapped diagnoses only) -- an
-- unmapped code has no concept_name to report by definition (see Phase 3's
-- 96.5% condition-mapping coverage note in the README for what's excluded
-- here and why).
--
-- LEFT JOIN to MEASUREMENT (not INNER): a diagnosis whose visit happened to
-- have zero recorded measurements should show avg_measurements_per_visit
-- = 0, not silently vanish from the results.

SELECT
    co.condition_concept_id,
    c.concept_name AS condition_name,
    count(DISTINCT co.person_id) AS patient_count,
    count(DISTINCT co.condition_occurrence_id) AS diagnosis_count,
    round(
        count(m.measurement_id)::numeric / count(DISTINCT co.condition_occurrence_id),
        1
    ) AS avg_measurements_per_visit
FROM cdm.condition_occurrence co
JOIN cdm.concept c ON c.concept_id = co.condition_concept_id
LEFT JOIN cdm.measurement m ON m.visit_occurrence_id = co.visit_occurrence_id
WHERE co.condition_concept_id != 0
GROUP BY co.condition_concept_id, c.concept_name
ORDER BY patient_count DESC, diagnosis_count DESC
LIMIT 20;
