"""Unit tests for synthetic data generator and sentiment logic."""

import pytest
import numpy as np
import pandas as pd
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))

from scripts.generate_synthetic_data import generate


@pytest.fixture(scope="module")
def df():
    return generate(n=500)


class TestSyntheticDataShape:
    def test_row_count(self, df):
        assert len(df) == 500

    def test_required_columns(self, df):
        required = {
            "ticket_id", "repo_name", "author_name", "Labels",
            "created_at", "ttfr_hours", "sla_met", "comment_count",
            "Issue_Question", "Last_Comment_Text", "Ticket_Key",
        }
        assert required.issubset(set(df.columns))

    def test_no_null_ticket_ids(self, df):
        assert df["ticket_id"].isna().sum() == 0

    def test_sla_met_is_binary(self, df):
        assert set(df["sla_met"].unique()).issubset({0, 1})

    def test_ttfr_non_negative(self, df):
        assert (df["ttfr_hours"] >= 0).all()

    def test_comment_count_non_negative(self, df):
        assert (df["comment_count"] >= 0).all()


class TestSLALogic:
    def test_sla_met_aligns_with_ttfr(self, df):
        """SLA = met if TTFR <= 24h."""
        expected = (df["ttfr_hours"] <= 24).astype(int)
        mismatches = (df["sla_met"] != expected).sum()
        assert mismatches == 0, f"{mismatches} rows have inconsistent sla_met vs ttfr_hours"

    def test_reasonable_sla_rate(self, df):
        """SLA met rate should be between 30% and 90% for a realistic distribution."""
        rate = df["sla_met"].mean()
        assert 0.30 <= rate <= 0.90, f"Unrealistic SLA rate: {rate:.1%}"


class TestRepoHealthDistribution:
    def test_multiple_repos(self, df):
        assert df["repo_name"].nunique() > 5

    def test_health_score_in_range(self, df):
        assert (df["repo_health_score"].between(0, 1)).all()

    def test_toxic_repos_exist(self, df):
        """Some repos should have low health scores (toxic tier)."""
        toxic = (df["repo_health_score"] < 0.3).any()
        assert toxic, "No toxic repos generated — check health score distribution"


class TestTextGeneration:
    def test_issue_text_is_string(self, df):
        assert df["Issue_Question"].dtype == object

    def test_no_empty_issue_text(self, df):
        assert (df["Issue_Question"].str.len() > 5).all()

    def test_last_comment_non_null(self, df):
        assert df["Last_Comment_Text"].isna().sum() == 0
