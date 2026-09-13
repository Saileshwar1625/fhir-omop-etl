#!/bin/bash
# Load the minimal Athena vocabulary tables needed to satisfy OMOP's
# concept_id foreign keys: CONCEPT itself, plus the three tables it has a
# circular FK relationship with (DOMAIN, VOCABULARY, CONCEPT_CLASS).
#
# Deliberately NOT loaded here: CONCEPT_ANCESTOR, CONCEPT_RELATIONSHIP,
# CONCEPT_SYNONYM, DRUG_STRENGTH, RELATIONSHIP. Nothing PERSON/
# VISIT_OCCURRENCE inserts touches those tables -- they support concept
# hierarchy/mapping lookups, which is real Phase 3 work. Load them later
# if/when Phase 3 concept mapping actually needs CONCEPT_RELATIONSHIP for
# "Maps to" resolution.
#
# Why constraints get dropped and re-added: CONCEPT -> DOMAIN/VOCABULARY/
# CONCEPT_CLASS, but those three each reference CONCEPT right back (see
# sql/init/03_constraints.sql lines ~309-319). That's a circular FK chain --
# none of the four tables can be the "first" one loaded under strict FK
# enforcement, so the constraints have to come off, then the data loads in
# any order, then the constraints go back on (they'll now succeed, since
# the data they check is fully present).
#
# USAGE: ./scripts/load_vocab.sh
#        VOCAB_DIR=tests/fixtures/vocab PGPORT=5432 ./scripts/load_vocab.sh
#
# Connects with plain `psql`, using the standard PG* environment variables
# (with defaults matching this project's local docker-compose.yml) -- not
# `docker exec` into a named container. Originally this script did use
# `docker exec -i omop_postgres psql ...`, but that only works when Postgres
# is that specific named Docker container. A direct psql connection works
# identically whether Postgres is that container (via its host-side port
# mapping, 5433), a GitHub Actions Postgres service container (Phase 4 CI),
# or a bare local install -- and psql already knows how to read PGHOST/
# PGPORT/etc., so nothing extra is needed to support all three. See
# docs/phase4-plan.md.
#
# Safe to re-run even if cdm.concept/vocabulary/domain/concept_class already
# have data in them (e.g. you re-downloaded from Athena with more
# vocabularies added to your selection) -- this TRUNCATEs those 4 tables
# before reloading, rather than trying to append on top of what's there
# (plain COPY has no ON CONFLICT / upsert option, so appending would just
# fail on duplicate concept_ids for every row you already had).
#
# NOTE: TRUNCATE ... CASCADE is used below, which will also wipe any table
# that currently has a live FK pointing at cdm.concept (cdm.person today;
# cdm.visit_occurrence too, once Step 3 exists). Postgres blocks TRUNCATE
# based on whether the constraint exists, not on whether the referencing
# table actually has rows -- so CASCADE is needed even when e.g. cdm.person
# is already empty. Re-run sql/transform/01_person.sql (and, later,
# 02_visit_occurrence.sql) after this script finishes.
set -e

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5433}"
export PGDATABASE="${PGDATABASE:-omop_cdm}"
export PGUSER="${PGUSER:-omop_admin}"
export PGPASSWORD="${PGPASSWORD:-omop_admin_pw}"
VOCAB_DIR="${VOCAB_DIR:-data/vocab}"

echo "== Dropping the circular FK constraints =="
psql <<'SQL'
ALTER TABLE cdm.CONCEPT DROP CONSTRAINT IF EXISTS fpk_CONCEPT_domain_id;
ALTER TABLE cdm.CONCEPT DROP CONSTRAINT IF EXISTS fpk_CONCEPT_vocabulary_id;
ALTER TABLE cdm.CONCEPT DROP CONSTRAINT IF EXISTS fpk_CONCEPT_concept_class_id;
ALTER TABLE cdm.VOCABULARY DROP CONSTRAINT IF EXISTS fpk_VOCABULARY_vocabulary_concept_id;
ALTER TABLE cdm.DOMAIN DROP CONSTRAINT IF EXISTS fpk_DOMAIN_domain_concept_id;
ALTER TABLE cdm.CONCEPT_CLASS DROP CONSTRAINT IF EXISTS fpk_CONCEPT_CLASS_concept_class_concept_id;
SQL

echo "== Truncating existing vocab tables (CASCADE also clears any table referencing cdm.concept, e.g. cdm.person) =="
psql -c "TRUNCATE cdm.concept, cdm.vocabulary, cdm.domain, cdm.concept_class CASCADE;"

# Athena CSVs are tab-delimited despite the .csv extension, and aren't
# meaningfully quoted -- QUOTE is set to a byte (backspace) that will never
# appear in the data, so a literal " inside a concept_name doesn't get
# misread as a CSV quote character and break the parser. The tiny fixture
# CSVs under tests/fixtures/vocab use the identical format for the same
# reason: this script shouldn't care, or need to know, which one it's fed.
COPY_OPTS="WITH (FORMAT csv, DELIMITER E'\t', HEADER true, QUOTE E'\b')"

echo "== Loading DOMAIN =="
psql -c "\\COPY cdm.domain FROM '$VOCAB_DIR/DOMAIN.csv' $COPY_OPTS"

echo "== Loading VOCABULARY =="
psql -c "\\COPY cdm.vocabulary FROM '$VOCAB_DIR/VOCABULARY.csv' $COPY_OPTS"

echo "== Loading CONCEPT_CLASS =="
psql -c "\\COPY cdm.concept_class FROM '$VOCAB_DIR/CONCEPT_CLASS.csv' $COPY_OPTS"

echo "== Loading CONCEPT (full Athena download is ~540MB -- give it a few minutes; the Phase 4 fixture is a few KB) =="
psql -c "\\COPY cdm.concept FROM '$VOCAB_DIR/CONCEPT.csv' $COPY_OPTS"

echo "== Re-adding the FK constraints =="
psql <<'SQL'
ALTER TABLE cdm.CONCEPT ADD CONSTRAINT fpk_CONCEPT_domain_id FOREIGN KEY (domain_id) REFERENCES cdm.DOMAIN (DOMAIN_ID);
ALTER TABLE cdm.CONCEPT ADD CONSTRAINT fpk_CONCEPT_vocabulary_id FOREIGN KEY (vocabulary_id) REFERENCES cdm.VOCABULARY (VOCABULARY_ID);
ALTER TABLE cdm.CONCEPT ADD CONSTRAINT fpk_CONCEPT_concept_class_id FOREIGN KEY (concept_class_id) REFERENCES cdm.CONCEPT_CLASS (CONCEPT_CLASS_ID);
ALTER TABLE cdm.VOCABULARY ADD CONSTRAINT fpk_VOCABULARY_vocabulary_concept_id FOREIGN KEY (vocabulary_concept_id) REFERENCES cdm.CONCEPT (CONCEPT_ID);
ALTER TABLE cdm.DOMAIN ADD CONSTRAINT fpk_DOMAIN_domain_concept_id FOREIGN KEY (domain_concept_id) REFERENCES cdm.CONCEPT (CONCEPT_ID);
ALTER TABLE cdm.CONCEPT_CLASS ADD CONSTRAINT fpk_CONCEPT_CLASS_concept_class_concept_id FOREIGN KEY (concept_class_concept_id) REFERENCES cdm.CONCEPT (CONCEPT_ID);
SQL

echo "== Row counts =="
psql -c "SELECT 'domain' AS t, count(*) FROM cdm.domain
   UNION ALL SELECT 'vocabulary', count(*) FROM cdm.vocabulary
   UNION ALL SELECT 'concept_class', count(*) FROM cdm.concept_class
   UNION ALL SELECT 'concept', count(*) FROM cdm.concept;"

echo "Done."
