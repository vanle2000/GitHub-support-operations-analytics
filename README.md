# GitHub Support Operations Analytics

**A support-operations data warehouse built on synthetic data, then audited against its own published claims.**

> **Read this first — the data is synthetic.** Every number in this repository comes from
> `scripts/generate_synthetic_data.py`, which fabricates 2,000 tickets across 40 repositories
> using a seeded RNG. **No real GitHub data was used.** Nothing here is a finding about GitHub,
> about open-source communities, or about any real support organisation. The dataset exists so
> the modelling and SQL can be executed and verified end to end.
>
> An earlier version of this README reported five headline findings as if they were discovered.
> They were not. They were **artefacts of the generator**, and four of the five do not reproduce
> from the shipping data at all. The corrected numbers are in [Results](#results), and
> [What I got wrong and fixed](#what-i-got-wrong-and-fixed) explains each one. That section is
> the most useful part of this repository.

---

## What this project is

A dimensional warehouse and analytics layer for developer-support ticket data:

- a **star schema** (`SQL/00_create_schema.sql`) — 3 dimensions, 1 fact, surrogate keys minted
  from natural keys, referential integrity and timeline constraints enforced, with a 7-assertion
  verification block that must report `PASS` on every row
- **analytic SQL** (`SQL/07_window_functions.sql`) — ranking, rolling frames, period-over-period
  deltas and share-of-total, with the plan trade-offs written down
- a **claim-verification gate** (`scripts/recompute_findings.py`) — recomputes every published
  number from the data and **exits non-zero when the README and the data disagree**

The question it was built to answer: *which repositories are losing contributors, and why?*
The honest answer this dataset can support is narrower, and saying so is the point.

---

## Results

Recompute all of these yourself with `python scripts/recompute_findings.py`.

| Claim previously published | Recomputed from the data | Status |
|---|---|---|
| 12% of repositories are "Toxic" | **2.5%** under the shipped view; **100%** under the documented formula | does not reproduce |
| 12h first response → **3.5x** repeat contributors | **1.01x** — and not computable from this dataset at all | does not reproduce |
| >3 comment rounds → **40% increase** in negative sentiment | **+16.2 percentage points** | does not reproduce |
| **50+** raw label tags standardised | **10** | does not reproduce |
| Health Score on a 0–100 scale | ceiling is **80**, and ~**38** under the documented weights | does not reproduce |

What the data *does* support, measured and reproducible:

| Finding | Value | Where |
|---|---|---|
| Tickets breaching the 24h first-response SLA | 2,000-ticket population, per-repo rates 0–100% | `SQL/02`, `07` Q2 |
| Ticket volume is **near-uniform** across repositories | 29 of 40 repos needed to reach 80% of volume | `07` Q5 |
| Repo-grain contributor retention is **structurally near-zero** | 1.5%–15.4%, median 6.1% | `07` Q2 |
| Rolling SLA attainment is sensitive to how the rate is aggregated | up to **12.1pp** swing | `07` Q3 |
| A third of naive week-over-week deltas span a calendar gap | **467 of 1,276** rows | `07` Q4 |

The third row is the one that matters analytically: 500 authors filing 2,000 tickets across 40
repositories average 4 tickets each, so almost no author files twice in the *same* repository.
Repo-level retention therefore cannot carry the 50% weight the health score assigns it. **The
metric is mis-grained, not mis-weighted** — and no amount of reweighting fixes that.

---

## Architecture

```
scripts/generate_synthetic_data.py  (seeded RNG, 2,000 tickets)
         │
         ▼
   data/raw/helpdesk_tickets.csv
         │
         ▼
   stg_helpdesk_tickets            ← staging, one row per source record
         │
         ├─► dim_repositories      ← surrogate keys minted from natural keys
         ├─► dim_authors           ← lifetime_tickets + author_tier
         ├─► dim_labels            ← raw_label → standardized_category
         └─► fact_tickets          ← grain: one row per support ticket
                  │
                  ├─► fact_sentiment   (SQL/04)
                  └─► risk_scores      (SQL/05)
```

`fact_tickets` grain is **one row per support ticket**. `author_tier` (Newbie 1 / Regular 2–4 /
Maintainer 5+) is defined once, in the dimension, because three separate views were reading it
and none of them defined it.

### SQL files

| File | Purpose | Status |
|---|---|---|
| `00_create_schema.sql` | Star schema DDL, staging, load, constraints, indexes, verification | works; 7/7 checks pass |
| `01_repo_health_view.sql` | Earlier, **incompatible** schema (`fact_issues`, `dim_contributor`) | superseded — do not run |
| `02_repo_health_metrics_postgresql.sql` | Repo health aggregate | runs; **known defect**, see below |
| `03_repo_health_metrics.sql` | Near-duplicate of `02` | redundant — should be deleted |
| `04_sentiment_volatility.sql` | Sentiment shift per repo | runs |
| `05_risk_scoring.sql` | SLA breach risk scoring | runs; **latest-snapshot bug**, see below |
| `06_executive_health_summary.sql` | Executive rollup | runs but returns **0 rows**, see below |
| `07_window_functions.sql` | Ranking, rolling frames, LAG, share-of-total | works; all 5 queries measured |

---

## What I got wrong and fixed

Every item below was found by cloning this repository and **executing it**, not by reading it.

### 1. The findings were built into the data generator

`scripts/generate_synthetic_data.py:85-86` defines response time and contributor retention as
functions of the same latent `health` variable:

```python
"avg_ttfr_hours": max(1, RNG.exponential(12 / health if health > 0.1 else 120)),
"contributor_retention": health * 0.7 + RNG.uniform(0, 0.3),
```

So `corr(health, retention) = 0.819` **by construction**. Line 131 does the same for sentiment.
"Fast responses correlate with retention" was not a discovery — it was an assignment statement.
Any analysis run on this data confirms what the generator was told to encode. This is circular,
and the earlier README presented the circle as an insight.

### 2. The "Golden Hour" lift is not computable from this dataset

`contributor_retention_rate` has exactly **one distinct value per repository** — it is a
repo-level attribute broadcast onto every ticket row, not an author-level outcome. There is no
per-author retention variable to regress against response time. The published 3.5x could not
have come from this data. The closest computable proxy ("did the author file again after their
first ticket") gives **1.01x** — no effect.

The original text also claimed *"this is not a correlation."* It was not even a correlation.

### 3. Three different health scores shared one name

| Where | Formula | Scale | Tiers |
|---|---|---|---|
| `02`/`03` `health_score` | `retention*50 + sla*30 − LEAST(res*0.1, 20)` | ceiling 80 | 40 / 75 |
| `02`/`03` `health_status` | same, but the penalty is **uncapped** | — | 40 / 75 |
| `06` `weighted_health_score` | `ret_pct*0.5 + sla_pct*0.3 − (res/720*30)*0.2` | ~38 observed | 50 / 75 |

Only the third matches the 0.5 / 0.3 / 0.2 weights this README documents. Because the score and
the status use different penalties, **4 of 40 repositories get a number and a label that
disagree.** Three definitions of one metric is not a rounding problem; it means the dashboard
and the alert can contradict each other.

### 4. `retention_rate` measured something other than retention

`SQL/02` computes it **ticket-weighted**, off a global lifetime `author_tier`, while the comment
describes an author-weighted repo-level rate. Measured error against its own stated definition:
**92.6 percentage points** (mean), 98.5pp (max). It reported 90.5–100%; correctly grained it is
1.5–15.4%. `07` Q2 has the corrected two-stage version.

### 5. The entire executive layer returned zero rows

Every view in `06_executive_health_summary.sql` filters
`created_at >= CURRENT_DATE - INTERVAL '90 days'`. The generated data is entirely 2023. **0 of
2,000 rows qualify**, so all five executive views were empty — including the one fronted as the
C-suite deliverable. It would have failed the first time anyone ran it.

### 6. Nothing ran end to end

Files `02`–`06` query `fact_tickets`, `dim_repositories`, `dim_authors` and `dim_labels`. **No
file in the repository created any of them.** Every one of those files failed with *relation does
not exist*. `00_create_schema.sql` fixes this and is the file to run first.

### 7. The "latest risk score" filter returned the wrong rows

`05_risk_scoring.sql` repeats this predicate in five views:

```sql
WHERE rs.calculated_at = (SELECT MAX(calculated_at) FROM risk_scores)
```

That is a **global** max, not a per-ticket max. Any ticket absent from the most recent scoring
batch disappears from the dashboard entirely — and the tickets most likely to be missing are the
high-risk ones, because a partial or failed batch is what creates the gap. Measured on a
two-batch fixture: the shipped predicate returns **8 rows where the correct answer is 20**. It
silently hid 60% of scored tickets. `07` Q1 fixes it with `ROW_NUMBER()`.

### 8. The claimed ETL did not exist

`Notebooks/01_data_exploration.ipynb` reads a CSV, builds one pandas slice, and **never writes
anything**. The "ETL pipeline using Python (SQLAlchemy)" was one discarded DataFrame.
`Notebooks/02` opens with an unconfigured placeholder connection string
(`mssql+pyodbc://YourServer/YourDB`). No notebook has ever connected to a database.

### 9. Stack claims with no artefact behind them

The earlier README listed **SQL Server / Azure Data Studio** as the warehouse and **Power BI
(Advanced DAX, AI Key Influencer)** as the BI layer, and described three dashboards.
`Dashboard/` contains a single empty `.gitkeep`. `src/` contains nine empty `__init__.py` files
and no modules. The SQL is PostgreSQL. Those claims are removed rather than softened.

---

## Preventing the recurrence

The problem was not any single wrong number; it was that **no mechanism existed to notice**.
`scripts/recompute_findings.py` is that mechanism. Each published claim is registered with a
tolerance, recomputed from the shipping data, and the script **exits 1** when they diverge:

```bash
python scripts/recompute_findings.py            # report
python scripts/recompute_findings.py --check     # CI gate: exits 1 on drift
python scripts/recompute_findings.py --markdown  # regenerate the Results table
```

`--markdown` emits the first table in [Results](#results) directly, so the published claims are
copied from script output rather than retyped. Hand-maintained numbers are how the five original
claims survived as long as they did.

```
FINDING                                                PUBLISHED    RECOMPUTED  STATUS
Repositories classified Toxic                                12%         2.50%  FAIL
12h first response -> repeat-contributor lift               3.5x         1.01x  FAIL
>3 comments -> negative sentiment shift                     40pp       16.15pp  FAIL
Raw label tags standardized                                   50         10.00  FAIL
Health score scale ceiling                                   100         80.00  FAIL
```

**These still say FAIL on purpose.** `PUBLISHED` holds the original claims so the gate reproduces
the audit. Closing them means fixing the code or the claim, not editing the expected value.

---

## Tech stack

| Layer | Tools | Status |
|---|---|---|
| Warehouse | PostgreSQL 12+ (star schema, window functions, partial + covering indexes) | schema logic verified on SQLite; **not yet run on Postgres** |
| Data generation | Python, NumPy (seeded RNG) | works |
| Verification | Python, pandas, SQLite | works |
| NLP | NLTK / VADER | present in `Notebooks/02`, never executed against a database |
| Notebooks | Jupyter | run standalone; **do not** write to the warehouse |
| Dashboards | none | previously claimed, no artefact — removed |

---

## How to run

```bash
git clone https://github.com/vanle2000/GitHub-support-operations-analytics.git
cd GitHub-support-operations-analytics

make install   # pip install -r requirements.txt + VADER lexicon
make data      # generate 2,000 synthetic tickets -> data/raw/helpdesk_tickets.csv
make test      # unit tests

python scripts/recompute_findings.py              # verify every claim in this README
python tests/verify_window_functions_sqlite.py    # execute all 5 queries in SQL/07
```

Then, against PostgreSQL 12+:

```bash
psql -d your_db -f SQL/00_create_schema.sql   # run FIRST — creates the star schema
# \copy analytics.stg_helpdesk_tickets FROM 'data/raw/helpdesk_tickets.csv' WITH (FORMAT csv, HEADER true, NULL '')
psql -d your_db -f SQL/07_window_functions.sql
```

Every row of `00_create_schema.sql`'s verification block must report `PASS`.

---

## Known open items

Tracked honestly rather than closed silently:

- [ ] `00_create_schema.sql` and `07_window_functions.sql` are **logic-verified on SQLite, not
      yet executed against a real PostgreSQL instance.** Window-function and constraint semantics
      match; `BIGSERIAL`, `CREATE SCHEMA`, `INCLUDE`, partial indexes and `ANALYZE` were parsed
      but not run.
- [ ] Consolidate the three health-score formulas into **one** view and have the others select
      from it.
- [ ] Delete `SQL/03` (duplicate) and `SQL/01` (incompatible schema).
- [ ] Fix `06`'s 90-day window so the executive views return rows.
- [ ] Re-grain the retention metric, or replace it with one this data supports.
- [ ] Notebooks do not write to the warehouse. Either wire them up or stop calling it a pipeline.
- [ ] No dashboard exists. Build one or leave the claim out.

---

## What I would do differently

1. **Publish no number without a script that regenerates it.** Everything else here follows from
   getting this wrong.
2. **Never let a synthetic generator define the relationship the analysis claims to find.**
   Generate the mechanism, or generate the outcome — not both from the same latent variable.
3. **Run the code before writing the README.** Six of the nine defects above surface on the first
   execution attempt.
4. **State the grain of every metric in its definition.** Both retention bugs were grain errors,
   and both read as plausible until measured.
5. **Write the disclosure first.** "Synthetic" belongs in the opening lines, not in a footnote.
