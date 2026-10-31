"""
Per-patient concept-mapping coverage for the FHIR-to-OMOP pipeline.

Question this answers: the overall measurement coverage is 1.11% (9,042 of 813,540).
Is that spread evenly across the 100 patients, or concentrated in a few?

USAGE (same place and same way as verify_row_counts.py):
    cd fhir-omop-etl/scripts
    python per_patient_coverage.py

Needs the Postgres container running (docker compose up -d) and the pipeline already
loaded. Writes per_patient_coverage.csv next to where you run it.

Definitions (match the README, nothing new):
  measurement coverage = loaded measurement rows with measurement_concept_id <> 0
                         / source Observation resources for that patient
  condition coverage   = loaded condition rows with condition_concept_id <> 0
                         / source Condition resources for that patient
Source counts come from the staging tables, so rows dropped before loading
(missing dates, the documented condition limitation) show up as a gap between
"source" and "loaded".
"""
import csv
import statistics

import psycopg2

from load_staging import DB_CONFIG

SQL = """
WITH obs_src AS (
    SELECT split_part(resource->'subject'->>'reference', '/', 2) AS pid, count(*) AS n
    FROM staging.observation GROUP BY 1
),
cond_src AS (
    SELECT split_part(resource->'subject'->>'reference', '/', 2) AS pid, count(*) AS n
    FROM staging.condition GROUP BY 1
),
meas AS (
    SELECT person_id,
           count(*) AS loaded,
           count(*) FILTER (WHERE measurement_concept_id <> 0) AS mapped
    FROM cdm.measurement GROUP BY 1
),
cond AS (
    SELECT person_id,
           count(*) AS loaded,
           count(*) FILTER (WHERE condition_concept_id <> 0) AS mapped
    FROM cdm.condition_occurrence GROUP BY 1
)
SELECT pm.person_id,
       COALESCE(o.n, 0)       AS obs_source,
       COALESCE(m.loaded, 0)  AS meas_loaded,
       COALESCE(m.mapped, 0)  AS meas_mapped,
       COALESCE(cs.n, 0)      AS cond_source,
       COALESCE(c.loaded, 0)  AS cond_loaded,
       COALESCE(c.mapped, 0)  AS cond_mapped
FROM staging.person_id_map pm
LEFT JOIN obs_src  o  ON o.pid  = pm.source_patient_id
LEFT JOIN cond_src cs ON cs.pid = pm.source_patient_id
LEFT JOIN meas     m  ON m.person_id = pm.person_id
LEFT JOIN cond     c  ON c.person_id = pm.person_id
ORDER BY pm.person_id;
"""


def pct(a, b):
    return 100.0 * a / b if b else None


def describe(name, values):
    vals = sorted(v for v in values if v is not None)
    q = statistics.quantiles(vals, n=4) if len(vals) >= 4 else [None] * 3
    print(f"{name:<28} min {vals[0]:6.2f}  Q1 {q[0]:6.2f}  median {statistics.median(vals):6.2f}"
          f"  Q3 {q[2]:6.2f}  max {vals[-1]:6.2f}")


def main():
    conn = psycopg2.connect(**DB_CONFIG)
    cur = conn.cursor()
    cur.execute(SQL)
    rows = cur.fetchall()
    cur.close()
    conn.close()

    out = []
    for pid, obs_src, m_loaded, m_mapped, c_src, c_loaded, c_mapped in rows:
        out.append({
            "person_id": pid,
            "obs_source": obs_src, "meas_loaded": m_loaded, "meas_mapped": m_mapped,
            "meas_coverage_pct": pct(m_mapped, obs_src),
            "cond_source": c_src, "cond_loaded": c_loaded, "cond_mapped": c_mapped,
            "cond_coverage_pct": pct(c_mapped, c_src),
        })

    with open("per_patient_coverage.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(out[0].keys()))
        w.writeheader()
        w.writerows(out)

    # --- sanity checks: these must reproduce the README numbers before you trust anything else
    t_obs = sum(r["obs_source"] for r in out)
    t_mm = sum(r["meas_mapped"] for r in out)
    t_cs = sum(r["cond_source"] for r in out)
    t_cm = sum(r["cond_mapped"] for r in out)
    print(f"patients: {len(out)}  (README: 100)")
    print(f"measurements mapped / source: {t_mm:,} / {t_obs:,}  (README: 9,042 / 813,540)")
    print(f"conditions   mapped / source: {t_cm:,} / {t_cs:,}  (README: 4,872 / 5,051)")
    if (t_mm, t_obs, t_cm, t_cs) != (9042, 813540, 4872, 5051):
        print("!! TOTALS DO NOT MATCH THE README. Fix this before using any per-patient number.")
    print()

    describe("measurement coverage % (per pt)", [r["meas_coverage_pct"] for r in out])
    describe("condition coverage %   (per pt)", [r["cond_coverage_pct"] for r in out])
    print()

    zero_m = [r["person_id"] for r in out if r["meas_mapped"] == 0]
    print(f"patients with 0 mapped measurements: {len(zero_m)}")
    ranked = sorted(out, key=lambda r: r["meas_mapped"], reverse=True)
    for k in (5, 10, 20):
        share = 100.0 * sum(r["meas_mapped"] for r in ranked[:k]) / t_mm if t_mm else 0
        print(f"top {k:>2} patients hold {share:5.1f}% of all mapped measurements")
    lost_m = sum(r["obs_source"] - r["meas_loaded"] for r in out)
    lost_c = sum(r["cond_source"] - r["cond_loaded"] for r in out)
    print(f"source rows not loaded: measurements {lost_m:,}, conditions {lost_c:,}")
    print("\nPer-patient table written to per_patient_coverage.csv")


if __name__ == "__main__":
    main()
