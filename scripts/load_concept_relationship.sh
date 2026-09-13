#!/bin/bash
# Phase 3 prerequisite: load RELATIONSHIP + a filtered CONCEPT_RELATIONSHIP.
#
# Why: mapping a source code (ICD9CM/ICD10CM condition codes, LOINC-adjacent
# observation codes) to a standard concept (SNOMED, LOINC) isn't a formula --
# it's a lookup in CONCEPT_RELATIONSHIP where relationship_id = 'Maps to'.
# CONCEPT_RELATIONSHIP.relationship_id has an FK to RELATIONSHIP, which
# Phase 2 never loaded (nothing needed it yet).
#
# CONCEPT_RELATIONSHIP.csv is 1.6GB and contains many relationship types you
# don't need (hierarchical, bidirectional, etc.) -- filtered down to just
# 'Maps to' rows with awk before loading, same "load only what's needed"
# principle as scripts/load_vocab.sh. The Phase 4 fixture CSV is already
# tiny and pre-filtered, so the awk step is a no-op there (NR==1 || $3=="Maps to"
# keeps everything if everything already qualifies).
#
# Connects with plain `psql` via the standard PG* environment variables, not
# `docker exec` -- same reasoning as scripts/load_vocab.sh, see there and
# docs/phase4-plan.md for why.
#
# USAGE: ./scripts/load_concept_relationship.sh
#        VOCAB_DIR=tests/fixtures/vocab PGPORT=5432 ./scripts/load_concept_relationship.sh
set -e

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5433}"
export PGDATABASE="${PGDATABASE:-omop_cdm}"
export PGUSER="${PGUSER:-omop_admin}"
export PGPASSWORD="${PGPASSWORD:-omop_admin_pw}"
VOCAB_DIR="${VOCAB_DIR:-data/vocab}"
COPY_OPTS="WITH (FORMAT csv, DELIMITER E'\t', HEADER true, QUOTE E'\b')"

echo "== Truncating (safe to re-run) =="
psql -c "TRUNCATE cdm.concept_relationship, cdm.relationship;"

echo "== Loading RELATIONSHIP =="
psql -c "\\COPY cdm.relationship FROM '$VOCAB_DIR/RELATIONSHIP.csv' $COPY_OPTS"

echo "== Filtering CONCEPT_RELATIONSHIP to 'Maps to' rows only =="
awk -F'\t' 'NR==1 || $3=="Maps to"' "$VOCAB_DIR/CONCEPT_RELATIONSHIP.csv" \
  > "$VOCAB_DIR/CONCEPT_RELATIONSHIP_maps_to.csv"
wc -l "$VOCAB_DIR/CONCEPT_RELATIONSHIP_maps_to.csv"

echo "== Loading CONCEPT_RELATIONSHIP (filtered) =="
psql -c "\\COPY cdm.concept_relationship FROM '$VOCAB_DIR/CONCEPT_RELATIONSHIP_maps_to.csv' $COPY_OPTS"

echo "== Row counts =="
psql -c "SELECT 'relationship' AS t, count(*) FROM cdm.relationship
   UNION ALL SELECT 'concept_relationship', count(*) FROM cdm.concept_relationship;"

echo "Done."
