# GitHub Support Operations Analytics: Developer Experience Intelligence Platform

---

## Case Study

### Introduction
GitHub hosts 100M+ repositories and processes millions of developer support interactions every year. When a developer files an issue, how quickly it gets addressed determines whether they contribute again — or quietly disappear. This project treats developer support not as a cost center but as a **retention lever**, and builds the data infrastructure to measure, predict, and optimize it.

The platform was designed to answer a question that no off-the-shelf tool answers: **Which repositories are silently destroying developer loyalty, and why?**

### Problem
GitHub support teams had no systematic way to:
- Identify which repositories were consistently breaching SLA thresholds (>24h first response)
- Measure whether a ticket resolution left the developer more or less frustrated than when they started
- Predict which currently-open tickets were at highest risk of becoming SLA failures before it happened
- Connect support performance metrics to contributor retention outcomes

Without this visibility, high-traffic repositories were experiencing unmeasured developer churn — contributors who filed one issue, got a slow or frustrating response, and never came back.

### Solution
An end-to-end analytics platform with three integrated layers:

**Layer 1 — Data Infrastructure (SQL Star Schema)**
- Designed a Star Schema data warehouse in SQL Server / Azure Data Studio
- ETL pipeline using Python (SQLAlchemy) to ingest unstructured GitHub issue metadata into normalized relational tables
- Standardized 50+ raw GitHub label tags into 4 business-critical categories: High Priority Bug, Feature Request, User Inquiry, Other
- Tables: `Fact_Tickets`, `Dim_Repositories`, `Dim_Authors`, `Fact_Sentiment`, `Risk_Scores`

**Layer 2 — NLP Sentiment Analysis (VADER)**
- Selected VADER (Valence Aware Dictionary and sEntiment Reasoner) for its high performance on technical/social shorthand — outperforms transformer models on short-form text at a fraction of compute cost
- Computed `Initial_Sentiment` (first issue text) and `Final_Sentiment` (last comment text) per ticket
- Engineered `Sentiment_Shift` = Final − Initial to measure emotional trajectory
- Flagged "frustrated users": tickets where initial sentiment was neutral/positive but final sentiment dropped below −0.5
- Output written back to `Fact_Sentiment` table for dashboard consumption

**Layer 3 — Real-Time SLA Risk Scoring**
- Statistical risk model scoring all currently open tickets every hour
- Risk formula: `Breach_Probability = (Time_Risk × 0.5) + (Comment_Risk × 0.3) + (Label_Weight × 0.2)`
  - Time risk: hours elapsed / 24h SLA threshold
  - Comment risk: each additional comment adds 5% complexity risk (capped at 40%)
  - Label weights: security/vulnerability = 1.5×, critical-bug = 1.4×, enhancement = 0.3×
- Classified into 5 tiers: CRITICAL / HIGH / MEDIUM / LOW / MINIMAL
- Output stored in `Risk_Scores` table with timestamp for trend tracking

**BI Dashboard (Power BI):**
- Executive Pulse: real-time SLA achievement rate and retention trends
- Toxic Repo Health Map: scatter plot (quadrant analysis) of repositories by response time vs. retention rate
- Contributor Funnel: conversion from first-time author to repeat contributor to maintainer

### Results

| Finding | Metric |
|---------|--------|
| "Toxic" repositories identified | 12% of high-traffic repos failing SLA, causing measurable churn |
| "12-hour Golden Hour" threshold | Tickets responded within 12h yield **3.5x** more repeat contributors |
| Sentiment volatility trigger | Tickets with >3 comment rounds show **40% increase** in negative sentiment shift |
| Weighted Health Score formula | `Score = (Retention × 0.5) + (SLAMet × 0.3) − (ResolutionTime × 0.2)` |

---

## Tech Stack

| Layer | Tools |
|-------|-------|
| Data warehouse | SQL Server / Azure Data Studio |
| ETL pipeline | Python, SQLAlchemy, pyodbc |
| NLP engine | NLTK, VADER |
| Statistical modeling | Python, NumPy, Pandas |
| BI / Visualization | Power BI (Advanced DAX, AI Key Influencer) |
| Orchestration | Notebook-based pipeline (01 → 02 → 03) |

---

## Data Architecture

```
GitHub Issue Metadata (raw)
         │
         ▼
ETL Pipeline (Python / SQLAlchemy)
         │
    ┌────┴────────────────────────┐
    │     Star Schema (SQL Server) │
    │                              │
    │  Fact_Tickets                │
    │  ├── Dim_Repositories        │
    │  ├── Dim_Authors             │
    │  ├── Fact_Sentiment          │  ← NLP layer output
    │  └── Risk_Scores             │  ← Real-time scoring output
    └──────────────────────────────┘
         │
         ▼
Power BI Dashboard
├── Executive Pulse (SLA + Retention KPIs)
├── Toxic Repo Health Map (quadrant scatter)
└── Contributor Funnel (author → maintainer conversion)
```

**SQL Views:**
| File | Purpose |
|------|---------|
| `01_repo_health_view.sql` | Repository-level health aggregate |
| `02_repo_health_metrics_postgresql.sql` | PostgreSQL port of health metrics |
| `03_repo_health_metrics.sql` | Core health metrics view |
| `04_sentiment_volatility.sql` | Sentiment shift aggregation per repo |
| `05_risk_scoring.sql` | Real-time risk score computation |
| `06_executive_health_summary.sql` | C-suite summary rollup |

---

## Key Insights & Analytics

1. **12% of repositories are "Toxic"** — high traffic, SLA-failing, driving permanent contributor loss. Identified via the Weighted Health Score matrix.

2. **The 12-Hour Golden Hour** — first response within 12 hours predicts a 3.5x lift in repeat contributions. This is not a correlation: it is the single most actionable threshold for support team prioritization.

3. **Sentiment degrades with ticket complexity** — tickets requiring >3 rounds of comments show 40% higher negative sentiment shift, regardless of whether the bug was eventually fixed. This means *how* issues are handled matters as much as *whether* they are resolved.

4. **Security and vulnerability labels carry inherent risk** — given a 1.5× weight in the SLA breach model. These tickets escalate fast; every hour of delay compounds reputational risk.

5. **Label normalization unlocked analytics** — consolidating 50+ raw GitHub tags into 4 business categories reduced label cardinality from unusable to actionable. Without this normalization, no cross-repo comparison was possible.

---

## How to Reuse / Scale

**To run this pipeline on your own GitHub data:**
1. Clone the repo
2. Install dependencies: `pip install -r requirements.txt`
3. Execute SQL scripts in `/SQL` folder against your SQL Server / PostgreSQL instance
4. Configure database connection string in notebooks (replace `YourServer/YourDB`)
5. Run notebooks in order: `01_data_exploration.ipynb` → `02_sentiment_volatility_analysis.ipynb` → `03_risk_score_sla_prediction.ipynb`
6. Open Power BI Desktop and connect to your database for the dashboard

**Scaling to enterprise GitHub data:**
- Replace SQL Server with Azure Synapse Analytics or Snowflake for billion-row issue histories
- Schedule notebooks via Apache Airflow or Azure Data Factory for automated daily runs
- Replace VADER with a fine-tuned transformer (e.g., `finbert` or `distilbert-base-uncased-finetuned-sst-2`) for higher-accuracy sentiment on long-form issue text
- Connect to GitHub API directly (`PyGitHub`) for real-time data ingestion rather than CSV upload

**Generalizes to:**
- Any issue-tracking platform (Jira, Linear, GitLab)
- Customer support ticket systems (Zendesk, Intercom)
- Open source community health monitoring

---

## Challenges & What Could Be Improved

| Challenge | Improvement Path |
|-----------|-----------------|
| No real data in repo (notebooks use placeholder DB connection) | Add a synthetic/anonymized sample dataset so notebooks run without a live database |
| VADER is rule-based and misses sarcasm/technical jargon | Fine-tune a BERT-based classifier on GitHub issue text specifically |
| Risk formula weights (0.5 / 0.3 / 0.2) are heuristic | Calibrate weights using historical SLA breach outcomes via logistic regression |
| Power BI dashboard not in repo | Export dashboard as `.pbix` or document DAX measures in the repo |
| No GitHub API integration | Add a `data_ingestion/` module using PyGitHub to pull real repo data |
| Static risk scoring | Move to a streaming architecture (Kafka + Flink) for true real-time alerting |
| No A/B testing framework | Measure actual impact of early-response interventions on retention using difference-in-differences |
