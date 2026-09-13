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
# principle as scripts/load_vocab.sh.
#
# USAGE: ./scripts/load_concept_relationship.sh
set -e

VOCAB_DIR="data/vocab"
CONTAINER="omop_postgres"
DB="omop_cdm"
DBUSER="omop_admin"
COPY_OPTS="WITH (FORMAT csv, DELIMITER E'\t', HEADER true, QUOTE E'\b')"

echo "== Truncating (safe to re-run) =="
docker exec -i "$CONTAINER" psql -U "$DBUSER" -d "$DB" -c \
  "TRUNCATE cdm.concept_relationship, cdm.relationship;"

echo "== Loading RELATIONSHIP =="
docker exec -i "$CONTAINER" psql -U "$DBUSER" -d "$DB" \
  -c "\\COPY cdm.relationship FROM STDIN $COPY_OPTS" \
  < "$VOCAB_DIR/RELATIONSHIP.csv"

echo "== Filtering CONCEPT_RELATIONSHIP to 'Maps to' rows only =="
awk -F'\t' 'NR==1 || $3=="Maps to"' "$VOCAB_DIR/CONCEPT_RELATIONSHIP.csv" \
  > "$VOCAB_DIR/CONCEPT_RELATIONSHIP_maps_to.csv"
wc -l "$VOCAB_DIR/CONCEPT_RELATIONSHIP_maps_to.csv"

echo "== Loading CONCEPT_RELATIONSHIP (filtered) =="
docker exec -i "$CONTAINER" psql -U "$DBUSER" -d "$DB" \
  -c "\\COPY cdm.concept_relationship FROM STDIN $COPY_OPTS" \
  < "$VOCAB_DIR/CONCEPT_RELATIONSHIP_maps_to.csv"

echo "== Row counts =="
docker exec -i "$CONTAINER" psql -U "$DBUSER" -d "$DB" -c \
  "SELECT 'relationship' AS t, count(*) FROM cdm.relationship
   UNION ALL SELECT 'concept_relationship', count(*) FROM cdm.concept_relationship;"

echo "Done."
