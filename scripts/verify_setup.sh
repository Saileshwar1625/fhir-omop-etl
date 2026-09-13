#!/usr/bin/env bash
# Verifies the Postgres container came up correctly and the full OMOP CDM v5.4
# schema was applied. Run this after `docker compose up -d` to confirm Phase 0
# actually worked, rather than assuming it did.
#
# Usage: ./scripts/verify_setup.sh

set -euo pipefail

CONTAINER=omop_postgres
DB=omop_cdm
USER=omop_admin

echo "== Waiting for Postgres to report healthy =="
for i in $(seq 1 30); do
  status=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")
  if [ "$status" = "healthy" ]; then
    echo "Postgres is healthy."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: Postgres did not become healthy in time. Run 'docker compose logs postgres' to see why." >&2
    exit 1
  fi
  sleep 2
done

echo
echo "== Table count in cdm schema (expect 39 for OMOP CDM v5.4) =="
count=$(docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='cdm';")
echo "cdm schema table count: $count"
if [ "$count" -ne 39 ]; then
  echo "ERROR: expected 39 tables, found $count. DDL init scripts likely failed partway — check 'docker compose logs postgres'." >&2
  exit 1
fi

echo
echo "== Confirming the 5 in-scope v1 tables exist =="
docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -c \
  "SELECT table_name FROM information_schema.tables WHERE table_schema='cdm' AND table_name IN ('person','visit_occurrence','measurement','condition_occurrence','drug_exposure') ORDER BY table_name;"

echo
echo "== Confirming primary keys and foreign key constraints were applied =="
pk_count=$(docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -tAc \
  "SELECT count(*) FROM information_schema.table_constraints WHERE constraint_schema='cdm' AND constraint_type='PRIMARY KEY';")
fk_count=$(docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -tAc \
  "SELECT count(*) FROM information_schema.table_constraints WHERE constraint_schema='cdm' AND constraint_type='FOREIGN KEY';")
echo "primary keys: $pk_count"
echo "foreign keys: $fk_count"

echo
echo "Phase 0 verification passed."
