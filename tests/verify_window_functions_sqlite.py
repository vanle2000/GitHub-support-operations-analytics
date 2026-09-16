"""Execute SQL/07_window_functions.sql against the 00_create_schema star schema.

SQLite stands in for Postgres: window-function semantics (ROW_NUMBER, RANK,
PERCENT_RANK, NTILE, LAG, named WINDOW clauses, ROWS/RANGE frames, FILTER) are
implemented the same way, so the query logic is genuinely exercised. Only
dialect surface is translated -- every substitution is printed below.
"""
import re, sqlite3, sys, pandas as pd

pd.set_option("display.width", 200)
print("sqlite3 library version:", sqlite3.sqlite_version)

con = sqlite3.connect(":memory:")

# ---------------------------------------------------------------- build schema
sql00 = re.sub(r'--[^\n]*', '', open("SQL/00_create_schema.sql").read())
stmts00 = [s.strip() for s in sql00.split(';') if s.strip()]
SKIP = re.compile(r'^\s*(CREATE SCHEMA|SET search_path|ALTER TABLE|ANALYZE)\b', re.I)

def ddl_to_sqlite(s):
    s = s.replace("analytics.", "")
    s = re.sub(r'BIGSERIAL PRIMARY KEY', 'INTEGER PRIMARY KEY AUTOINCREMENT', s, flags=re.I)
    s = re.sub(r'\s*INCLUDE\s*\([^)]*\)', '', s, flags=re.I)
    s = re.sub(r'\s+CASCADE\b', '', s, flags=re.I)
    return s

for st in stmts00:
    if SKIP.match(st) or st.upper().lstrip().startswith("WITH CHECKS"):
        continue
    try:
        con.execute(ddl_to_sqlite(st))
    except Exception as e:
        print(f"!! schema: {e}\n   {st[:120]}"); sys.exit(1)

df = pd.read_csv("data/raw/helpdesk_tickets.csv")
df.columns = ["ticket_id","repo_name","author_name","labels","created_at","first_response_at",
              "closed_at","ttfr_hours","sla_met","comment_count","is_closed","milestone",
              "repo_health_score","contributor_retention_rate","issue_question",
              "last_comment_text","ticket_key_src"]
df.to_sql("stg_helpdesk_tickets", con, if_exists="append", index=False)
for st in stmts00:
    if re.match(r'^\s*INSERT INTO', st, re.I):
        con.execute(ddl_to_sqlite(st))
con.commit()
n_fact = con.execute("SELECT COUNT(*) FROM fact_tickets").fetchone()[0]
n_open = con.execute("SELECT COUNT(*) FROM fact_tickets WHERE closed_at IS NULL").fetchone()[0]
print(f"schema loaded: fact_tickets={n_fact:,} rows ({n_open:,} open)\n")

# ------------------------------------------------------- risk_scores from 05
sql05 = re.sub(r'--[^\n]*', '', open("SQL/05_risk_scoring.sql").read())
m = re.search(r'(CREATE TABLE IF NOT EXISTS risk_scores\s*\(.*?\n\);)', sql05, re.S | re.I)
ddl = ddl_to_sqlite(m.group(1)).rstrip(';')
con.execute(ddl)
print("created risk_scores from 05_risk_scoring.sql DDL\n")

# ----------------------------------------------------------- translate 07
raw07 = open("SQL/07_window_functions.sql").read()

SUBS = [
    (r'EXTRACT\(EPOCH FROM \(([\w.]+) - ([\w.]+)\)\)\s*/\s*3600',
     r'(julianday(\1)-julianday(\2))*24',                 "EXTRACT(EPOCH..)/3600 -> julianday()*24"),
    (r"DATE_TRUNC\('week',\s*([\w.]+)\)::date",
     r"date(\1, 'weekday 0', '-6 days')",                 "DATE_TRUNC('week',x)::date -> ISO Monday via date()"),
    (r"DATE_TRUNC\('week',\s*([\w.]+)\)",
     r"date(\1, 'weekday 0', '-6 days')",                 "DATE_TRUNC('week',x) in GROUP BY"),
    (r'\bMIN\((created_at)\)::date',  r'date(MIN(\1))',   "MIN(x)::date -> date(MIN(x))"),
    (r'\bMAX\((created_at)\)::date',  r'date(MAX(\1))',   "MAX(x)::date -> date(MAX(x))"),
    (r'([\w.]+)::date',              r'date(\1)',         "x::date -> date(x)"),
    (r'::numeric',                    '',                 "::numeric cast stripped (SQLite ROUND takes REAL)"),
    (r'\bLEAST\(',                    'MIN(',             "LEAST() -> scalar MIN()"),
    (r'\bTIMESTAMP\s+(?=\')',         '',                 "TIMESTAMP 'lit' -> 'lit'"),
    (r'CREATE OR REPLACE VIEW',       'CREATE VIEW',       "CREATE OR REPLACE VIEW -> CREATE VIEW"),
    (r'week_start - \(LAG\(week_start\) OVER w\) = 7',
     'julianday(week_start) - julianday(LAG(week_start) OVER w) = 7',
                                                          "date subtraction -> julianday difference"),
]
SPINE_PG = re.compile(r"SELECT generate_series\(d0, d1, INTERVAL '1 day'\)::date AS d FROM bounds")
SPINE_LITE = ("SELECT d0 AS d FROM bounds UNION ALL "
              "SELECT date(d, '+1 day') FROM spine, bounds WHERE d < d1")

def to_sqlite(s):
    for pat, rep, _ in SUBS:
        s = re.sub(pat, rep, s, flags=re.I)
    if SPINE_PG.search(s) or "generate_series" in s:
        s = SPINE_PG.sub(SPINE_LITE, s)
        s = re.sub(r'^(\s*)WITH bounds AS', r'\1WITH RECURSIVE bounds AS', s, flags=re.I | re.M)
    return s

print("dialect substitutions applied:")
for _, _, why in SUBS: print("   -", why)
print("   - generate_series() date spine -> recursive CTE")
print("   - COMMENT ON VIEW / SET search_path skipped\n")

body = re.sub(r'--[^\n]*', '', raw07)
stmts07 = [s.strip() for s in body.split(';') if s.strip()]

views = []
for st in stmts07:
    if re.match(r'^\s*(SET search_path|COMMENT ON)\b', st, re.I):
        continue
    lite = to_sqlite(st)
    name = re.search(r'CREATE VIEW\s+(\w+)', lite, re.I)
    try:
        con.execute(lite)
    except Exception as e:
        print(f"!! {type(e).__name__}: {e}\n{lite[:600]}\n"); sys.exit(1)
    if name:
        views.append(name.group(1))
print(f"views created: {len(views)} -> {', '.join(views)}\n")

# --------------------------------------------- seed risk_scores (07 demo block)
seed = re.search(r'-- INSERT INTO risk_scores.*?JOIN batches b ON s\.rn <= b\.covers_first_n;',
                 raw07, re.S)
seed_sql = to_sqlite(re.sub(r'^-- ?', '', seed.group(0), flags=re.M))
con.execute(seed_sql)
con.commit()
print("demo seed applied (07's commented block, run verbatim after uncommenting)")

# ============================== Q1 ==========================================
print("\n" + "=" * 78)
print("Q1  ROW_NUMBER latest-snapshot -- does the rewrite change the ANSWER?")
print("=" * 78)
bug = pd.read_sql("""
SELECT (SELECT COUNT(*) FROM risk_scores
         WHERE calculated_at = (SELECT MAX(calculated_at) FROM risk_scores)) AS old_predicate_rows,
       (SELECT COUNT(*) FROM v_latest_risk_score)                            AS window_form_rows,
       (SELECT COUNT(DISTINCT ticket_key) FROM risk_scores)                  AS tickets_scored,
       (SELECT COUNT(*) FROM risk_scores)                                    AS score_rows_total
""", con)
print(bug.to_string(index=False))
o, w, t = int(bug.old_predicate_rows[0]), int(bug.window_form_rows[0]), int(bug.tickets_scored[0])
print(f"\n  --> 05's global-MAX predicate hides {t - o} of {t} scored tickets. "
      f"Window form returns all {w}.")
print("\nv_latest_risk_score sample (prob_change_since_prior = drift between batches):")
print(pd.read_sql("""SELECT ticket_key, risk_tier, sla_breach_probability,
                            prob_change_since_prior, times_scored, scored_at
                     FROM v_latest_risk_score
                     ORDER BY times_scored DESC, sla_breach_probability DESC LIMIT 6""",
                  con).to_string(index=False))
resc = pd.read_sql("SELECT * FROM v_latest_risk_score WHERE times_scored > 1", con)
print(f"  rescored tickets: {len(resc)}; prob_change_since_prior "
      f"{resc.prob_change_since_prior.min():+.0f} .. {resc.prob_change_since_prior.max():+.0f} "
      f"-- LAG picks up the climb the old predicate could not show at all")

print("\nEXPLAIN QUERY PLAN (SQLite; structural shape only, not Postgres costs)")
for label, q in [("global-MAX predicate",
                  "SELECT * FROM risk_scores WHERE calculated_at ="
                  " (SELECT MAX(calculated_at) FROM risk_scores)"),
                 ("v_latest_risk_score", "SELECT * FROM v_latest_risk_score")]:
    print(f"  {label}:")
    for row in con.execute("EXPLAIN QUERY PLAN " + q):
        print("     ", row[-1])

# ============================== Q2 ==========================================
print("\n" + "=" * 78)
print("Q2  RANK / DENSE_RANK / PERCENT_RANK / NTILE")
print("=" * 78)
q2 = pd.read_sql("SELECT * FROM v_repo_health_ranked ORDER BY health_rank", con)
print(f"rows: {len(q2)}")
print(q2[["repo_name","ticket_volume","retention_rate_pct","sla_met_rate_pct",
          "health_score","health_rank","health_percentile","health_quartile",
          "vs_fleet_avg"]].head(5).to_string(index=False))
print("  ...")
print(q2[["repo_name","ticket_volume","retention_rate_pct","health_score",
          "health_rank","health_percentile","health_quartile",
          "vs_fleet_avg"]].tail(3).to_string(index=False))
print(f"\n  health_score range {q2.health_score.min():.2f} .. {q2.health_score.max():.2f}")
print(f"  percentile range   {q2.health_percentile.min():.3f} .. {q2.health_percentile.max():.3f}"
      "   (PERCENT_RANK must span exactly 0..1)")
print("  quartile sizes:", q2.health_quartile.value_counts().sort_index().to_dict())
print(f"  rank is contiguous 1..N: {list(q2.health_rank) == list(range(1, len(q2)+1))}")
print(f"\n  author-weighted retention {q2.retention_rate_pct.min():.1f}..{q2.retention_rate_pct.max():.1f}"
      f"  (02/03 ticket-weighted version: 90.5..100.0)")

# ============================== Q3 ==========================================
print("\n" + "=" * 78)
print("Q3  rolling 7-day frame -- ratio-of-sums vs mean-of-rates")
print("=" * 78)
q3 = pd.read_sql("SELECT * FROM v_rolling_sla_attainment", con)
print(f"rows: {len(q3)}   date spine {q3.d.min()} .. {q3.d.max()}")
print(f"  days with zero tickets: {(q3.tickets == 0).sum()}  "
      f"(these are the rows a spine-less ROWS frame would skip)")
print(f"  partial frames flagged: {(q3.frame_status == 'partial frame').sum()} (expect 6)")
comp = q3[q3.frame_status == "complete"].copy()
comp["gap_pp"] = (comp.rolling7_attainment_pct - comp.rolling7_avg_of_daily_rates_pct).abs()
print(f"  ratio-of-sums vs mean-of-rates: mean gap {comp.gap_pp.mean():.3f}pp, "
      f"max {comp.gap_pp.max():.3f}pp  ({(comp.gap_pp > 0.01).sum()}/{len(comp)} days differ)")
print(q3[["d","tickets","sla_met","daily_attainment_pct","rolling7_attainment_pct",
          "rolling7_avg_of_daily_rates_pct","days_in_frame","frame_status"]]
      .iloc[[0,1,5,6,7,120]].to_string(index=False))

# ============================== Q4 ==========================================
print("\n" + "=" * 78)
print("Q4  LAG week-over-week, with gap detection")
print("=" * 78)
q4 = pd.read_sql("SELECT * FROM v_repo_wow_response_time", con)
print(f"rows: {len(q4)}")
print("  comparison_valid:", q4.comparison_valid.value_counts().to_dict())
gaps = q4[q4.comparison_valid.str.startswith("GAP")]
print(f"  --> {len(gaps)} of {len(q4)} rows are NOT adjacent weeks. Without the guard column "
      f"every one of those wow_delta_hrs values would be reported as week-over-week.")
one = q4[q4.repo_name == q4.repo_name.iloc[0]]
print(f"\n  {q4.repo_name.iloc[0]} first 6 weeks:")
print(one[["week_start","tickets","avg_ttfr_hrs","prev_week_start","wow_delta_hrs",
           "wow_pct_change","trailing_4wk_avg_ttfr_hrs","worst_week_to_date_hrs",
           "comparison_valid"]].head(6).to_string(index=False))

# ============================== Q5 ==========================================
print("\n" + "=" * 78)
print("Q5  SUM() OVER () share + Pareto concentration")
print("=" * 78)
q5 = pd.read_sql("SELECT * FROM v_repo_volume_concentration", con)
print(f"rows: {len(q5)}   pct_of_total sums to {q5.pct_of_total.sum():.2f} (must be ~100)")
print(f"  final cumulative_pct_of_total = {q5.cumulative_pct_of_total.iloc[-1]:.2f} (must be 100.00)")
top80 = (q5.pareto_segment == "top 80% of load").sum()
print(f"  repos carrying the top 80% of load: {top80}/{len(q5)} = {100*top80/len(q5):.0f}% of repos")
print(f"  --> {'NOT a Pareto distribution; load is near-uniform' if top80 > len(q5)*0.5 else 'concentrated'}")
print(q5.head(5).to_string(index=False))

print("\n" + "=" * 78)
print("ALL 5 QUERIES EXECUTED. Window-function count in 07:")
pat = re.compile(r'\bOVER\s*[\(\w]', re.I)
print("  OVER clauses:", len(pat.findall(re.sub(r'--[^\n]*', '', raw07))))
print("=" * 78)
