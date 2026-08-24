-- Phase 1: staging schema.
-- Raw FHIR resources land here largely as-is (as JSONB), one table per FHIR
-- resourceType. This is deliberately NOT the final OMOP shape -- see
-- docs/phase1-plan.md for why (ELT-style: land raw, transform later in SQL).
--
-- Only the four core v1 resource types are defined here (Patient, Encounter,
-- Condition, Observation). Medication-family staging tables are intentionally
-- NOT included yet -- DRUG_EXPOSURE is a stretch table, and the medication
-- files map to more than the two FHIR resourceTypes the original brief assumed
-- (see docs/phase1-plan.md, "Medication resourceType check"). Add them once
-- verified, don't guess table names now.

CREATE SCHEMA IF NOT EXISTS staging;

CREATE TABLE staging.patient (
    resource_id TEXT PRIMARY KEY,
    resource    JSONB NOT NULL,
    loaded_at   TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE staging.encounter (
    resource_id TEXT PRIMARY KEY,
    resource    JSONB NOT NULL,
    loaded_at   TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE staging.condition (
    resource_id TEXT PRIMARY KEY,
    resource    JSONB NOT NULL,
    loaded_at   TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE staging.observation (
    resource_id TEXT PRIMARY KEY,
    resource    JSONB NOT NULL,
    loaded_at   TIMESTAMP NOT NULL DEFAULT now()
);
