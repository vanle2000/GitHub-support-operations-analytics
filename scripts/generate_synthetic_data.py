"""
Generate synthetic GitHub helpdesk ticket data so notebooks run without
a live database connection.

Run: python scripts/generate_synthetic_data.py
Output: data/raw/helpdesk_tickets.csv
"""

import pathlib
import numpy as np
import pandas as pd
from datetime import datetime, timedelta

OUTPUT_DIR = pathlib.Path(__file__).parent.parent / "data" / "raw"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

RNG = np.random.default_rng(42)

# ── Config ──────────────────────────────────────────────────────────────
N_TICKETS = 2_000
N_REPOS = 40
N_AUTHORS = 500

REPOS = [f"repo-{i:03d}" for i in range(N_REPOS)]
AUTHORS = [f"user-{i:04d}" for i in range(N_AUTHORS)]

LABELS = ["bug", "critical-bug", "vulnerability", "security",
          "enhancement", "feature", "question", "help wanted",
          "documentation", "other"]

LABEL_WEIGHTS = [0.18, 0.08, 0.04, 0.05, 0.20, 0.15, 0.14, 0.08, 0.05, 0.03]

ISSUE_TEMPLATES = [
    "Getting {error} when trying to {action}. Reproduction steps: ...",
    "Feature request: would love to see {feature} in the next release.",
    "How do I configure {thing}? The docs are unclear.",
    "Critical: {vulnerability} allows unauthorized access to {resource}.",
    "Build fails after upgrading to v{version} with error: {error}",
    "Performance degradation in {module} — latency increased by {pct}%",
    "Documentation for {api} is outdated and missing {feature}.",
]

COMMENT_TEMPLATES = [
    "Thanks for the report! We'll look into this.",
    "Can you provide a minimal reproduction case?",
    "This is a known issue, tracking in #{n}.",
    "Fixed in v{version}, please upgrade.",
    "Working on a fix, ETA {days} days.",
    "Unfortunately this is by design. Closing.",
    "Merged PR #{pr}. This should be resolved.",
]

NEGATIVE_TEMPLATES = [
    "Still broken after the supposed fix. This is unacceptable.",
    "It has been {days} days with no response. Is anyone looking at this?",
    "The workaround doesn't work either. Very frustrated.",
    "I've lost hours on this. Please escalate.",
]


def _random_text(templates: list, **kwargs) -> str:
    t = RNG.choice(templates)
    defaults = dict(
        error="TypeError: undefined", action="submit a form",
        feature="dark mode", thing="OAuth2", resource="admin panel",
        version=str(RNG.integers(1, 5)) + "." + str(RNG.integers(0, 10)),
        module="query engine", pct=str(RNG.integers(20, 300)),
        api="REST API", n=str(RNG.integers(100, 999)),
        days=str(RNG.integers(2, 14)), pr=str(RNG.integers(1000, 9999)),
        vulnerability="SSRF vulnerability",
    )
    defaults.update(kwargs)
    try:
        return t.format(**defaults)
    except KeyError:
        return t


def _make_repo_health_profile():
    """Assign each repo a latent 'health score' driving its SLA behaviour."""
    profiles = {}
    for repo in REPOS:
        health = RNG.beta(2, 2)   # 0=toxic, 1=excellent
        profiles[repo] = {
            "health": health,
            "avg_ttfr_hours": max(1, RNG.exponential(12 / health if health > 0.1 else 120)),
            "contributor_retention": health * 0.7 + RNG.uniform(0, 0.3),
        }
    return profiles


def generate(n: int = N_TICKETS) -> pd.DataFrame:
    repo_profiles = _make_repo_health_profile()
    rows = []

    start_date = datetime(2023, 1, 1)

    for i in range(n):
        repo = RNG.choice(REPOS)
        profile = repo_profiles[repo]
        author = RNG.choice(AUTHORS)
        label = RNG.choice(LABELS, p=LABEL_WEIGHTS)

        created_at = start_date + timedelta(
            days=int(RNG.integers(0, 365)),
            hours=int(RNG.integers(0, 24)),
        )

        # Time to first response — driven by repo health
        ttfr_hours = max(0.5, RNG.exponential(profile["avg_ttfr_hours"]))
        first_response_at = created_at + timedelta(hours=ttfr_hours)

        # Closed at (some tickets still open)
        is_closed = RNG.random() < 0.75
        resolution_hours = ttfr_hours + RNG.exponential(24)
        closed_at = (created_at + timedelta(hours=resolution_hours)) if is_closed else None

        # SLA: first response within 24h?
        sla_met = ttfr_hours <= 24

        # Comment count — more comments = more complex
        base_comments = int(RNG.exponential(3))
        comment_count = max(0, base_comments)

        # Milestone
        milestone = RNG.choice(["v1.0", "v1.1", "v2.0", "backlog", None], p=[0.1, 0.15, 0.1, 0.25, 0.4])

        # Issue text
        issue_question = _random_text(ISSUE_TEMPLATES)

        # Final comment — more negative if frustrated (long wait + high comments)
        frustrated = (not sla_met) and (comment_count > 3)
        final_template = NEGATIVE_TEMPLATES if frustrated and RNG.random() < 0.6 \
            else COMMENT_TEMPLATES
        last_comment_text = _random_text(final_template)

        rows.append({
            "ticket_id": f"T-{i+1:05d}",
            "repo_name": repo,
            "author_name": author,
            "Labels": label,
            "created_at": created_at.isoformat(),
            "first_response_at": first_response_at.isoformat(),
            "closed_at": closed_at.isoformat() if closed_at else None,
            "ttfr_hours": round(ttfr_hours, 2),
            "sla_met": int(sla_met),
            "comment_count": comment_count,
            "is_closed": int(is_closed),
            "milestone": milestone,
            "repo_health_score": round(profile["health"], 3),
            "contributor_retention_rate": round(profile["contributor_retention"], 3),
            "Issue_Question": issue_question,
            "Last_Comment_Text": last_comment_text,
        })

    df = pd.DataFrame(rows)

    # Add a Ticket_Key for SQL join compatibility
    df["Ticket_Key"] = df["ticket_id"]

    print(f"Generated {len(df):,} tickets across {df['repo_name'].nunique()} repos")
    print(f"SLA met rate: {df['sla_met'].mean():.1%}")
    print(f"Closed rate:  {df['is_closed'].mean():.1%}")
    print(f"Avg TTFR:     {df['ttfr_hours'].mean():.1f} hours")
    print(f"\nLabel distribution:")
    print(df["Labels"].value_counts().head(8).to_string())

    return df


def main():
    df = generate()
    out = OUTPUT_DIR / "helpdesk_tickets.csv"
    df.to_csv(out, index=False)
    print(f"\nSaved to {out}")


if __name__ == "__main__":
    main()
