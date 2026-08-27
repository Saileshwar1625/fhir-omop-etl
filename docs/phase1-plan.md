# Phase 1 Plan — Ingestion

Goal (from the project brief): parse the FHIR NDJSON files into raw/staging tables,
one per resource type, and profile the data. That's it — no OMOP mapping yet, no
concept mapping yet. Those are Phases 2–3.

## Definition of done for Phase 1

- [ ] `staging` schema exists with a table each for `patient`, `encounter`,
      `condition`, `observation`.
- [ ] `scripts/load_staging.py` runs end-to-end for all four resource types
      without crashing.
- [ ] Row counts in each staging table match the source files' line counts
      (verification query below).
- [ ] A short profiling write-up exists (missingness, reference format,
      row counts) — doesn't need to be fancy, a markdown file or a few saved
      SQL queries with their output is enough.
- [ ] README's "In Progress"/"Planned" sections updated to reflect reality.

Not required for Phase 1 done: anything about `DRUG_EXPOSURE`/medications,
anything about OMOP tables being populated, anything about concept mapping.

## Step 0 — Prerequisites (should already be true)

- Docker container running, `cdm` schema verified (Phase 0 — `./scripts/verify_setup.sh`).
- FHIR NDJSON files present at
  `data/raw/mimic-iv-clinical-database-demo-on-fhir-2.1.0/fhir/` (confirmed).
- Athena vocab CSVs present in `data/vocab/` (confirmed — not used until Phase 3,
  fine to leave alone).
- Python environment: if you haven't yet, `python -m venv venv`, activate it,
  `pip install -r requirements.txt`.

## Step 1 — Add the staging schema

Already written for you: `sql/init/05_staging_schema.sql`. It creates a `staging`
schema with four tables (`patient`, `encounter`, `condition`, `observation`),
each shaped as `resource_id TEXT PRIMARY KEY, resource JSONB, loaded_at TIMESTAMP`.

Why this shape, briefly (full reasoning in the concepts glossary under
"staging table"): FHIR resources are irregular — flattening them into fixed
columns before you've looked at real data means guessing your schema too early.
Storing the raw resource as JSONB lets you land the data as-is and query into
specific fields with `->>`/`->` once you know what you need. `resource_id` as
primary key gives you idempotent reruns for free via `ON CONFLICT DO NOTHING`.

Since `docker-entrypoint-initdb.d` scripts only auto-run on a *fresh* volume,
and you have no real data loaded into `cdm` yet, apply this by recreating the
container:

```
docker compose down -v
docker compose up -d
./scripts/verify_setup.sh
```

Then confirm the staging schema landed:
```
docker exec -it omop_postgres psql -U omop_admin -d omop_cdm -c "\dt staging.*"
```
You should see 4 tables listed.

## Step 2 — (Optional, deferred) Medication resourceType check

Skip this for now — it's only needed if/when you get to `DRUG_EXPOSURE`. Noting
it here so it's not forgotten: the medication files (8 of them) almost certainly
map to more than the two FHIR resourceTypes (`MedicationRequest`,
`MedicationAdministration`) the original brief assumed — `MedicationDispense`
and `MedicationStatement` are distinct real FHIR resources, and
`MimicMedicationMix` is likely a `Medication` (drug catalog entity), not an
event. Before writing any medication staging tables, verify with:
```
python -c "import gzip,json; print(json.loads(gzip.open(r'data\raw\mimic-iv-clinical-database-demo-on-fhir-2.1.0\fhir\MimicMedicationMix.ndjson.gz','rt',encoding='utf-8').readline())['resourceType'])"
```
(swap the filename for each ambiguous one). Come back to this after Step 6.

## Step 3 — Implement the loader

Already scaffolded for you: `scripts/load_staging.py`. CLI args, DB connection,
the file mapping, and the gzip/NDJSON reader are all done. The one thing left is
`load_resource_type()` — the actual read-and-upsert loop. Its docstring in the
file is the full spec (upsert pattern, batching, error handling, what to return).
That's the real Phase 1 coding work — everything around it is plumbing you'd
otherwise just look up.

## Step 4 — Run it, smallest file first

```
python scripts/load_staging.py --resource patient
```
`MimicPatient.ndjson.gz` is 6KB — fastest feedback loop for finding bugs in
your loop logic. Once that works cleanly:
```
python scripts/load_staging.py --resource encounter
python scripts/load_staging.py --resource condition
python scripts/load_staging.py --resource observation
```
Save `observation` for last — `MimicObservationChartevents.ndjson.gz` alone is
35MB compressed, by far your largest file. If your loader has a bug that only
shows up at scale (e.g. a memory leak from not committing in batches), you want
to find that on a small file first, not after waiting on the big one.

## Step 5 — Verify row counts against source

Don't assume the load worked — check it. For each resource type, compare the
staging table's row count to the sum of source file line counts:
```
python -c "import gzip; print(sum(1 for _ in gzip.open(r'data\raw\mimic-iv-clinical-database-demo-on-fhir-2.1.0\fhir\MimicPatient.ndjson.gz','rt',encoding='utf-8')))"
```
```sql
SELECT count(*) FROM staging.patient;
```
These should match (for `encounter`/`condition`/`observation`, sum the line
counts across all their source files first). If they don't match exactly,
that's not automatically a bug — check whether any resources share an `id`
across files (unlikely but possible) or whether your loader's skip-and-warn
logic dropped anything, and look at what it printed.

## Step 6 — Profile the data

A few SQL queries to actually run, not just read:

**Missingness** — how often is a given field populated:
```sql
SELECT
    count(*) AS total,
    count(*) FILTER (WHERE resource->>'birthDate' IS NULL) AS missing_birthdate,
    count(*) FILTER (WHERE resource->>'gender' IS NULL) AS missing_gender
FROM staging.patient;
```
Adapt for other resource types/fields you care about.

**How resources reference each other** — first check the actual reference
format before writing an integrity check (don't assume — this is the same
lesson as the medication resourceType check above):
```sql
SELECT resource->'subject'->>'reference' AS subject_ref
FROM staging.encounter
LIMIT 5;
```
This tells you whether it's `"Patient/abc123"`, a bare id, or something else.
Once you know the format, check for orphans (encounters referencing a patient
that doesn't exist in your loaded data) — example assuming the `"Patient/<id>"`
format:
```sql
SELECT count(*) AS orphaned_encounters
FROM staging.encounter e
WHERE NOT EXISTS (
    SELECT 1 FROM staging.patient p
    WHERE 'Patient/' || p.resource_id = e.resource->'subject'->>'reference'
);
```
Run the equivalent for `condition` and `observation` (both also reference a
patient via `subject`; `observation` may also reference an `encounter`).

Save these queries somewhere in the repo (e.g. `sql/profiling/` or a notes file)
along with what you found — this is what "profile the data" in the brief
actually means as a deliverable, not just something you did once and forgot.

## Step 7 — Update the README

Move Phase 1 from "Planned" to either "Completed" (if all four staging tables
are loaded, verified, and profiled) or "In Progress" (if partially done) —
per your own ground rules, don't round up.
