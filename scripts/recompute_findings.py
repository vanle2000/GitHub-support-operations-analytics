"""
Recompute every published finding from the shipping data.

Every number in README.md must be produced by this script. If a published claim
does not reproduce within tolerance, `--check` exits 1.

    python scripts/recompute_findings.py            # report
    python scripts/recompute_findings.py --check     # CI gate, exits 1 on drift
    python scripts/recompute_findings.py --markdown  # emit README-ready table

Run from the repo root, after `make data`.
"""

import argparse
import pathlib
import sqlite3
import sys

import numpy as np
import pandas as pd

DATA = pathlib.Path("data/raw/helpdesk_tickets.csv")

# Claims as currently published in README.md. Update these ONLY by rerunning
# this script -- never by hand.
PUBLISHED = {
    "toxic_repo_pct":        {"claim": 12.0, "tol": 3.0,  "unit": "%",  "label": "Repositories classified Toxic"},
    "golden_hour_lift":      {"claim": 3.5,  "tol": 0.5,  "unit": "x",  "label": "12h first response -> repeat-contributor lift"},
    "sentiment_increase_pp": {"claim": 40.0, "tol": 10.0, "unit": "pp", "label": ">3 comments -> negative sentiment shift"},
    "raw_label_count":       {"claim": 50.0, "tol": 5.0,  "unit": "",   "label": "Raw label tags standardized"},
    "health_score_ceiling":  {"claim": 100.0,"tol": 5.0,  "unit": "",   "label": "Health score scale ceiling"},
}


def load():
    if not DATA.exists():
        sys.exit(f"{DATA} not found. Run: make data")
    return pd.read_csv(DATA, parse_dates=["created_at", "first_response_at", "closed_at"])


def build_star_schema(df):
    """Materialize the tables SQL/02-06 query, in-process.

    SQL/00_create_schema.sql is the canonical DDL and load. This function is an
    in-memory SQLite stand-in so the recompute can run in CI without a Postgres
    instance -- it is NOT a second source of truth. The author_tier thresholds
    below must stay identical to section 3b of 00_create_schema.sql; if they
    diverge, this script and the warehouse will report different numbers, which
    is the exact class of defect it exists to catch.
    """
    df = df.drop(columns=[c for c in ("Ticket_Key",) if c in df.columns])
    df = df.assign(repo_key=df.repo_name, author_key=df.author_name, ticket_key=df.ticket_id)

    # Mirrors 00_create_schema.sql section 3b: Newbie 1, Regular 2-4, Maintainer 5+.
    per_author = df.groupby("author_name").ticket_id.size()
    dim_authors = pd.DataFrame({
        "author_key": per_author.index,
        "author_tier": np.select(
            [per_author >= 5, per_author >= 2], ["Maintainer", "Regular"], default="Newbie"),
    })
    repos = df.repo_name.unique()
    dim_repositories = pd.DataFrame({"repo_key": repos, "repo_name": repos})

    con = sqlite3.connect(":memory:")
    df.to_sql("fact_tickets", con, index=False)
    dim_authors.to_sql("dim_authors", con, index=False)
    dim_repositories.to_sql("dim_repositories", con, index=False)
    return con, df


# SQL/02 v_repo_health_metrics, verbatim except EXTRACT(EPOCH...)/3600 -> julianday()*24.
# status_score_uncapped is added to expose the score/status formula split.
HEALTH_VIEW = """
WITH repo_stats AS (
  SELECT r.repo_name,
    CAST(SUM(CASE WHEN a.author_tier != 'Newbie' THEN 1 ELSE 0 END) AS REAL) / COUNT(*) AS retention_rate,
    CAST(SUM(CASE WHEN (julianday(f.first_response_at) - julianday(f.created_at)) * 24 <= 24
             THEN 1 ELSE 0 END) AS REAL) / COUNT(*) AS sla_met_rate,
    AVG((julianday(f.closed_at) - julianday(f.created_at)) * 24) AS avg_resolution_hrs,
    COUNT(*) AS ticket_volume
  FROM fact_tickets f
  JOIN dim_repositories r ON f.repo_key = r.repo_key
  JOIN dim_authors a ON f.author_key = a.author_key
  GROUP BY r.repo_name)
SELECT repo_name, ticket_volume,
  ROUND(retention_rate * 100, 2) AS retention_rate_pct,
  ROUND(sla_met_rate * 100, 2)   AS sla_met_rate_pct,
  ROUND(avg_resolution_hrs, 2)   AS avg_resolution_hrs,
  ROUND((retention_rate * 50) + (sla_met_rate * 30)
        - (CASE WHEN avg_resolution_hrs > 100 THEN 20 ELSE avg_resolution_hrs * 0.1 END), 2) AS health_score,
  CASE WHEN (retention_rate * 50) + (sla_met_rate * 30) - (avg_resolution_hrs * 0.1) < 40
            THEN 'Toxic / At Risk'
       WHEN (retention_rate * 50) + (sla_met_rate * 30) - (avg_resolution_hrs * 0.1) BETWEEN 40 AND 75
            THEN 'Stable'
       ELSE 'Healthy / Elite' END AS health_status,
  ROUND((retention_rate * 50) + (sla_met_rate * 30) - (avg_resolution_hrs * 0.1), 2) AS status_score_uncapped
FROM repo_stats
"""

NEGATIVE_OPENERS = ("Still broken", "It has been", "The workaround", "I've lost hours")


def recompute():
    df = load()
    con, df = build_star_schema(df)
    health = pd.read_sql(HEALTH_VIEW, con)
    m, notes = {}, []

    m["raw_label_count"] = float(df.Labels.nunique())

    m["toxic_repo_pct"] = float((health.health_status == "Toxic / At Risk").mean() * 100)

    # Golden Hour. There is no author-level retention outcome in the dataset:
    # contributor_retention_rate is a repo-level constant broadcast onto every row.
    # The closest computable proxy is "did the author file again after their first ticket".
    per_repo_distinct = df.groupby("repo_name").contributor_retention_rate.nunique()
    if set(per_repo_distinct.unique()) == {1}:
        notes.append(
            "contributor_retention_rate has exactly 1 distinct value per repo -- it is a "
            "repo-level attribute, not an author-level outcome. A repeat-contributor lift "
            "is NOT computable from this dataset; the value below is a proxy."
        )
    repeat = df.groupby("author_name").ticket_id.size() > 1
    first = df.sort_values("created_at").groupby("author_name").first()
    first["repeat"] = repeat.reindex(first.index).values
    fast = first.loc[first.ttfr_hours <= 12, "repeat"].mean()
    slow = first.loc[first.ttfr_hours > 12, "repeat"].mean()
    m["golden_hour_lift"] = float(fast / slow) if slow else float("nan")
    notes.append(f"repeat rate <=12h: {fast:.1%} | >12h: {slow:.1%} | all authors with >1 ticket: {repeat.mean():.1%}")

    # Sentiment. Reported in percentage POINTS: the generator gives tickets with
    # <=3 comments a 0% chance of a negative closer, so a relative % increase is
    # a division by zero, not 40%.
    neg = df.Last_Comment_Text.str.startswith(NEGATIVE_OPENERS)
    lo = neg[df.comment_count <= 3].mean() * 100
    hi = neg[df.comment_count > 3].mean() * 100
    m["sentiment_increase_pp"] = float(hi - lo)
    notes.append(f"negative closer rate: {lo:.1f}% (<=3 comments) vs {hi:.1f}% (>3) -- relative increase undefined, baseline is 0")

    m["health_score_ceiling"] = 50.0 + 30.0  # retention*50 + sla*30, before penalty
    notes.append(f"observed health_score range: {health.health_score.min():.2f} to {health.health_score.max():.2f}")

    # Defects that are not "claims" but must not silently regress.
    split = health[(health.health_score - health.status_score_uncapped).abs() > 0.01]
    per_pair = df.groupby(["repo_name", "author_name"]).size().reset_index(name="n")
    per_pair["is_repeat"] = per_pair.n > 1
    author_weighted = per_pair.groupby("repo_name").is_repeat.mean() * 100
    err = (health.set_index("repo_name").retention_rate_pct - author_weighted).abs()

    defects = {
        "score_status_formula_split": (len(split), len(health)),
        "retention_definition_error_pp": (err.mean(), err.max()),
        "window_functions_in_sql": count_window_functions(),
    }
    return m, defects, notes, health


def count_window_functions():
    import re
    pat = re.compile(r"\bover\s*\(|\brow_number\b|\bdense_rank\b|\bpercent_rank\b|\blag\s*\(|\blead\s*\(|\bntile\b", re.I)
    total = 0
    for f in sorted(pathlib.Path("SQL").glob("*.sql")):
        body = re.sub(r"--[^\n]*|/\*.*?\*/", "", f.read_text(), flags=re.S)
        total += len(pat.findall(body))
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="exit 1 if a published claim does not reproduce")
    ap.add_argument("--markdown", action="store_true", help="emit a README-ready table")
    args = ap.parse_args()

    measured, defects, notes, health = recompute()
    rows, failed = [], []
    for key, spec in PUBLISHED.items():
        got, claim = measured[key], spec["claim"]
        ok = abs(got - claim) <= spec["tol"]
        if not ok:
            failed.append((key, claim, got, spec["unit"]))
        rows.append((spec["label"], f"{claim:g}{spec['unit']}", f"{got:.2f}{spec['unit']}", "PASS" if ok else "FAIL"))

    if args.markdown:
        print("| Finding | Published | Recomputed | |")
        print("|---|---|---|---|")
        for label, c, g, s in rows:
            print(f"| {label} | {c} | **{g}** | {'ok' if s == 'PASS' else 'does not reproduce'} |")
    else:
        w = max(len(r[0]) for r in rows)
        print(f"{'FINDING'.ljust(w)}  {'PUBLISHED':>10}  {'RECOMPUTED':>12}  STATUS")
        for label, c, g, s in rows:
            print(f"{label.ljust(w)}  {c:>10}  {g:>12}  {s}")
        n, tot = defects["score_status_formula_split"]
        mean_e, max_e = defects["retention_definition_error_pp"]
        print(f"\nOpen defects")
        print(f"  health_score vs health_status formula split : {n}/{tot} repos disagree")
        print(f"  retention_rate vs documented definition     : {mean_e:.1f}pp mean, {max_e:.1f}pp max")
        print(f"  window functions across SQL/*.sql           : {defects['window_functions_in_sql']}")
        print("\nNotes")
        for nt in notes:
            print(f"  - {nt}")

    if args.check and failed:
        print(f"\nFAIL: {len(failed)} published claim(s) do not reproduce from the shipping data:", file=sys.stderr)
        for key, claim, got, unit in failed:
            print(f"  {key}: README says {claim:g}{unit}, data says {got:.2f}{unit}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
