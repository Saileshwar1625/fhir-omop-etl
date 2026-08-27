et -e
 
VOCAB_DIR="data/vocab"
CONTAINER="omop_postgres"
DB="omop_cdm"
DBUSER="omop_admin"
 
echo "== Dropping the circular FK constraints =="
docker exec -i "$CONTAINER" psql -U "$DBUSER" -d "$DB" <<'SQL'
ALTER TABLE cdm.CONCEPT DROP CONSTRAINT IF EXISTS fpk_CONCEPT_domain_id;
ALTER TABLE cdm.CONCEPT DROP CONSTRAINT IF EXISTS fpk_CONCEPT_vocabulary_id;
ALTER TABLE cdm.CONCEPT DROP CONSTRAINT IF EXISTS fpk_CONCEPT_concept_class_id;
ALTER TABLE cdm.VOCABULARY DROP CONSTRAINT IF EXISTS fpk_VOCABULARY_vocabulary_concept_id;
ALTER TABLE cdm.DOMAIN DROP CONSTRAINT IF EXISTS fpk_DOMAIN_domain_concept_id;
ALTER TABLE cdm.CONCEPT_CLASS DROP CONSTRAINT IF EXISTS fpk_CONCEPT_CLASS_concept_class_concept_id;
SQL
 
echo "== Truncating existing vocab tables (CASCADE also clears any table referencing cdm.concept, e.g. cdm.person) =="
docker exec -i "$CONTAINER" psql -U "$DBUSER" -d "$DB" -c \
  "TRUNCATE cdm.concept, cdm.vocabulary, cdm.domain, cdm.concept_class CASCADE;"
 
# Athena CSVs are tab-delimited despite the .csv extension, and aren't
# meaningfully quoted -- QUOTE is set to a byte (backspace) that will never
# appear in the data, so a literal " inside a concept_name doesn't get
# misread as a CSV quote character and break the parser.
COPY_OPTS="WITH (FORMAT csv, DELIMITER E'\t', HEADER true, QUOTE E'\b')"
 
echo "== Loading DOMAIN =="
docker exec -i "$CONTAINER" psql -U "$DBUSER" -d "$DB" \
  -c "\\COPY cdm.domain FROM STDIN $COPY_OPTS" \
  < "$VOCAB_DIR/DOMAIN.csv"
 
echo "== Loading VOCABULARY =="
docker exec -i "$CONTAINER" psql -U "$DBUSER" -d "$DB" \
  -c "\\COPY cdm.vocabulary FROM STDIN $COPY_OPTS" \
  < "$VOCAB_DIR/VOCABULARY.csv"
 
echo "== Loading CONCEPT_CLASS =="
docker exec -i "$CONTAINER" psql -U "$DBUSER" -d "$DB" \
  -c "\\COPY cdm.concept_class FROM STDIN $COPY_OPTS" \
  < "$VOCAB_DIR/CONCEPT_CLASS.csv"
 
echo "== Loading CONCEPT (540MB -- this is the slow one, give it a few minutes) =="
docker exec -i "$CONTAINER" psql -U "$DBUSER" -d "$DB" \
  -c "\\COPY cdm.concept FROM STDIN $COPY_OPTS" \
  < "$VOCAB_DIR/CONCEPT.csv"
 
echo "== Re-adding the FK constraints =="
docker exec -i "$CONTAINER" psql -U "$DBUSER" -d "$DB" <<'SQL'
ALTER TABLE cdm.CONCEPT ADD CONSTRAINT fpk_CONCEPT_domain_id FOREIGN KEY (domain_id) REFERENCES cdm.DOMAIN (DOMAIN_ID);
ALTER TABLE cdm.CONCEPT ADD CONSTRAINT fpk_CONCEPT_vocabulary_id FOREIGN KEY (vocabulary_id) REFERENCES cdm.VOCABULARY (VOCABULARY_ID);
ALTER TABLE cdm.CONCEPT ADD CONSTRAINT fpk_CONCEPT_concept_class_id FOREIGN KEY (concept_class_id) REFERENCES cdm.CONCEPT_CLASS (CONCEPT_CLASS_ID);
ALTER TABLE cdm.VOCABULARY ADD CONSTRAINT fpk_VOCABULARY_vocabulary_concept_id FOREIGN KEY (vocabulary_concept_id) REFERENCES cdm.CONCEPT (CONCEPT_ID);
ALTER TABLE cdm.DOMAIN ADD CONSTRAINT fpk_DOMAIN_domain_concept_id FOREIGN KEY (domain_concept_id) REFERENCES cdm.CONCEPT (CONCEPT_ID);
ALTER TABLE cdm.CONCEPT_CLASS ADD CONSTRAINT fpk_CONCEPT_CLASS_concept_class_concept_id FOREIGN KEY (concept_class_concept_id) REFERENCES cdm.CONCEPT (CONCEPT_ID);
SQL
 
echo "== Row counts =="
docker exec -i "$CONTAINER" psql -U "$DBUSER" -d "$DB" -c \
  "SELECT 'domain' AS t, count(*) FROM cdm.domain
   UNION ALL SELECT 'vocabulary', count(*) FROM cdm.vocabulary
   UNION ALL SELECT 'concept_class', count(*) FROM cdm.concept_class
   UNION ALL SELECT 'concept', count(*) FROM cdm.concept;"
 
echo "Done."