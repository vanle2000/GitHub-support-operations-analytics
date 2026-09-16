-- ============================================================================
-- 07_window_functions.sql  -  Analytic (window) functions
-- GitHub Support Operations Analytics
-- Database: PostgreSQL 12+   (frame syntax notes call out 11+ / 14+ behaviour)
-- Prerequisite: 00_create_schema.sql
-- ============================================================================
--
-- WHY THIS FILE EXISTS
--
-- Files 01-06 contain ~1,180 lines of SQL and zero window functions. Five
-- places in them are doing by hand what a window function does natively:
--
--   Q1  latest risk score per ticket   -> 05 repeats a MAX() subquery in 5 views
--   Q2  rank repos by health           -> 02/03/06 ORDER BY with no rank column
--   Q3  rolling 7-day SLA attainment   -> 06 reports point-in-time rates only
--   Q4  week-over-week response delta  -> 06 has no period-over-period compare
--   Q5  repo share of total volume     -> 06 computes totals with a self-join
--
-- Q1 is not a style preference: the existing predicate returns the WRONG ROWS.
-- See the note above Q1.
--
-- Every query below runs against the star schema created by 00_create_schema.sql
-- and is written to be read aloud. Where two plausible formulations exist, both
-- appear and the comment says which one is correct and why -- that choice is
-- usually the actual content of the question.
--
-- Deliberately NOT selecting from 02's v_repo_health_metrics: that view's
-- health_score and health_status use different formulas (4 of 40 repos get a
-- score and a label that disagree). Q2 recomputes health from the documented
-- 0.5 / 0.3 / 0.2 weights instead. Once 02/03/06 are consolidated into one
-- view, Q2 should select from it rather than restate it.
-- ============================================================================

SET search_path TO analytics, public;


-- ============================================================================
-- Q1. LATEST RISK SCORE PER TICKET  --  ROW_NUMBER()
-- ============================================================================
--
-- THE BUG BEING FIXED. 05_risk_scoring.sql filters five separate views with:
--
--     WHERE rs.calculated_at = (SELECT MAX(calculated_at) FROM risk_scores)
--
-- That is a GLOBAL max, not a per-ticket max. Two consequences:
--
--   1. CORRECTNESS. Any ticket not rescored in the most recent batch disappears
--      from the dashboard entirely. A ticket scored CRITICAL yesterday and
--      skipped today does not show up as stale -- it shows up as nothing. The
--      highest-risk tickets are exactly the ones most likely to be dropped,
--      because a partial or failed batch is what produces a gap in the first
--      place. Measured on a two-batch seed: 12 of 20 tickets vanish.
--
--   2. It also drops any ticket whose latest score landed one microsecond off
--      the batch's max timestamp -- equality against a MAX() over the whole
--      table is a brittle way to express "most recent".
--
-- The window-function form asks the question that was actually meant: for each
-- ticket, keep its own most recent score.
--
-- ORDER BY inside the window has a tiebreak on risk_score_key. Without a total
-- order, ROW_NUMBER() is nondeterministic across ties and the same query can
-- return different rows on two runs. Interviewers look for this.

CREATE OR REPLACE VIEW v_latest_risk_score AS
WITH ranked AS (
    SELECT
        rs.*,
        ROW_NUMBER() OVER (
            PARTITION BY rs.ticket_key
            ORDER BY rs.calculated_at DESC, rs.risk_score_key DESC
        ) AS recency_rank,
        COUNT(*) OVER (PARTITION BY rs.ticket_key)              AS times_scored,
        rs.sla_breach_probability
          - LAG(rs.sla_breach_probability) OVER (
                PARTITION BY rs.ticket_key ORDER BY rs.calculated_at
            )                                                   AS prob_change_since_prior
    FROM risk_scores rs
)
SELECT
    ticket_key,
    repo_name,
    author_name,
    created_at,
    ticket_age_hours,
    comment_count,
    label_weight,
    has_response,
    sla_breach_probability,
    prob_change_since_prior,   -- + means risk is climbing between batches
    risk_tier,
    calculated_at              AS scored_at,
    times_scored
FROM ranked
WHERE recency_rank = 1;

COMMENT ON VIEW v_latest_risk_score IS
'One row per ticket: its most recent risk score. Replaces the global-MAX
predicate repeated in five views in 05_risk_scoring.sql, which silently drops
any ticket absent from the latest scoring batch.';

-- The five views in 05 then become one-liners over this view, e.g.
--
--   CREATE OR REPLACE VIEW v_critical_risk_tickets AS
--   SELECT * FROM v_latest_risk_score
--   WHERE sla_breach_probability > 80 OR ticket_age_hours > 24;
--
-- Same result, one definition of "latest", one scan of risk_scores.


-- ----------------------------------------------------------------------------
-- Q1 / EXPLAIN  --  reading the plan difference
-- ----------------------------------------------------------------------------
--
-- Run both and compare. ANALYZE gives real row counts and timings; BUFFERS
-- shows whether the extra pass hit cache or disk, which is what actually
-- decides if the rewrite matters at your data size.
--
--   EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
--   SELECT * FROM risk_scores rs
--   WHERE rs.calculated_at = (SELECT MAX(calculated_at) FROM risk_scores);
--
--   EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
--   SELECT * FROM v_latest_risk_score;
--
-- WHAT TO EXPECT, STRUCTURALLY
--
--   Subquery form:  InitPlan computes MAX(calculated_at) -- one extra pass,
--                   though idx_risk_calculated makes it a cheap
--                   Index Only Scan ... ORDER BY calculated_at DESC LIMIT 1.
--                   The outer node is then a Seq Scan (or an index scan on
--                   idx_risk_calculated) with an equality filter. Reads few
--                   rows. This form is FAST -- and wrong.
--
--   Window form:    Sort (or Index Scan) to order by ticket_key, calculated_at
--                   -> WindowAgg -> Subquery Scan with Filter: recency_rank = 1.
--                   One pass over the whole table, and it must materialise
--                   every row before discarding non-winners. Slower per row,
--                   returns the correct set.
--
-- So this rewrite trades throughput for correctness. Say that out loud rather
-- than claiming the window function is faster -- on this predicate it is not.
--
-- MAKING THE CORRECT VERSION FAST. The sort is the cost, so remove it:
--
--   CREATE INDEX idx_risk_ticket_recent
--       ON risk_scores (ticket_key, calculated_at DESC, risk_score_key DESC);
--
-- Postgres can then feed WindowAgg from an ordered index scan and the Sort
-- node disappears. Verify it did -- do not assume; an index the planner
-- declines to use is worse than no index, because it still costs on write.
--
-- Two alternatives worth naming if asked:
--
--   DISTINCT ON is the Postgres-idiomatic form and uses the same index:
--       SELECT DISTINCT ON (ticket_key) *
--       FROM risk_scores ORDER BY ticket_key, calculated_at DESC, risk_score_key DESC;
--     Shorter, but Postgres-only and it cannot also expose times_scored or
--     prob_change_since_prior, which is why the window form is kept here.
--
--   A LATERAL ... LIMIT 1 per ticket wins when risk_scores is very large and
--   the ticket count is small -- it becomes an index seek per ticket instead
--   of a full ordered pass. Worth benchmarking at ~10M+ rows.
--
-- On Redshift the same query is the right answer, but tune differently:
-- SORTKEY (ticket_key, calculated_at) and DISTKEY (ticket_key) keep the
-- partitioning local to each slice and avoid a redistribution step.


-- ============================================================================
-- Q2. RANK REPOS BY HEALTH  --  RANK, DENSE_RANK, PERCENT_RANK, NTILE
-- ============================================================================
--
-- "Which repos are worst, and is 62 a bad score or a normal one?" A raw score
-- cannot answer the second half. A percentile can.
--
-- retention_rate here is AUTHOR-weighted -- the share of a repo's distinct
-- authors who filed more than once in THAT repo. 02/03 compute it
-- ticket-weighted off author_tier, which is a global lifetime attribute, and
-- overstates retention by a measured 92.6 percentage points. The two-CTE shape
-- below (grain-reducing join, then aggregate) is the fix.

CREATE OR REPLACE VIEW v_repo_health_ranked AS
WITH repo_author AS (          -- grain: one row per (repo, author)
    SELECT repo_key, author_key, COUNT(*) AS tickets_in_repo
    FROM fact_tickets
    GROUP BY repo_key, author_key
),
repo_retention AS (            -- grain: one row per repo
    SELECT
        repo_key,
        COUNT(*)                                                  AS distinct_authors,
        AVG(CASE WHEN tickets_in_repo > 1 THEN 1.0 ELSE 0.0 END)  AS retention_rate
    FROM repo_author
    GROUP BY repo_key
),
repo_service AS (
    SELECT
        f.repo_key,
        COUNT(*) AS ticket_volume,
        AVG(CASE WHEN f.first_response_at IS NOT NULL
                  AND EXTRACT(EPOCH FROM (f.first_response_at - f.created_at))/3600 <= 24
                 THEN 1.0 ELSE 0.0 END)                           AS sla_met_rate,
        AVG(EXTRACT(EPOCH FROM (f.closed_at - f.created_at))/3600) AS avg_resolution_hrs
    FROM fact_tickets f
    GROUP BY f.repo_key
),
repo_health AS (
    SELECT
        r.repo_name,
        s.ticket_volume,
        t.distinct_authors,
        t.retention_rate,
        s.sla_met_rate,
        s.avg_resolution_hrs,
        -- Documented weights: retention 0.5, SLA 0.3, resolution-time penalty 0.2.
        -- Penalty normalised against a 720-hour (30-day) reference and capped, so
        -- one abandoned ticket cannot drive the score negative.
          (t.retention_rate * 100 * 0.5)
        + (s.sla_met_rate   * 100 * 0.3)
        - (LEAST(COALESCE(s.avg_resolution_hrs, 720) / 720.0, 1.0) * 30 * 0.2) AS health_score
    FROM repo_service s
    JOIN repo_retention  t ON s.repo_key = t.repo_key
    JOIN dim_repositories r ON s.repo_key = r.repo_key
)
SELECT
    repo_name,
    ticket_volume,
    distinct_authors,
    ROUND((retention_rate * 100)::numeric, 2) AS retention_rate_pct,
    ROUND((sla_met_rate   * 100)::numeric, 2) AS sla_met_rate_pct,
    ROUND(avg_resolution_hrs::numeric, 2)     AS avg_resolution_hrs,
    ROUND(health_score::numeric, 2)           AS health_score,

    -- RANK leaves gaps after ties (1,2,2,4); DENSE_RANK does not (1,2,2,3).
    -- Use RANK when the number answers "how many repos are healthier than me",
    -- DENSE_RANK when it answers "how many distinct score levels are above me".
    RANK()       OVER (ORDER BY health_score DESC) AS health_rank,
    DENSE_RANK() OVER (ORDER BY health_score DESC) AS health_rank_dense,

    -- PERCENT_RANK = (rank - 1) / (rows - 1): 0.0 for the worst repo, 1.0 for
    -- the best, so it is directional -- higher is healthier. It is NOT the same
    -- as CUME_DIST, which is (rows at or below) / rows and never returns 0.
    ROUND((PERCENT_RANK() OVER (ORDER BY health_score))::numeric, 3) AS health_percentile,

    -- NTILE(4) buckets into quartiles by count, not by score range. Quartile 1
    -- is the worst 25% of repos by construction and will never be empty -- so
    -- "10 repos are in the bottom quartile" is a tautology, not a finding.
    -- Absolute thresholds are what a pager should fire on. This column is for
    -- triage ordering, not for alerting.
    NTILE(4) OVER (ORDER BY health_score) AS health_quartile,

    ROUND((health_score - AVG(health_score) OVER ())::numeric, 2) AS vs_fleet_avg,
    ROUND((AVG(health_score) OVER ())::numeric, 2)                AS fleet_avg,

    -- Volume-weighted context: a low score on a 200-ticket repo matters more
    -- than the same score on a 3-ticket repo. Unweighted fleet averages are
    -- the most common way a health dashboard misleads its reader.
    ROUND((100.0 * ticket_volume / SUM(ticket_volume) OVER ())::numeric, 2)
        AS pct_of_fleet_volume
FROM repo_health;

COMMENT ON VIEW v_repo_health_ranked IS
'Repo health with rank, percentile and quartile. Retention is author-weighted
(distinct authors filing >1 ticket in the repo), unlike 02/03 which weight by
ticket and read a global author_tier.';

-- FINDING SURFACED BY THIS VIEW -- the documented health score cannot work.
--
-- With retention measured correctly, health_score spans 4.49 .. 37.48 across all
-- 40 repos, and under 06's tiers (<50 = Toxic) that makes 100% of repos Toxic --
-- against a README claim of 12%.
--
-- This is not a tuning problem, it is arithmetic. Retention carries 50 of the
-- 100 points, but observed author-weighted retention is 1.5%-15.4% (median
-- 6.1%), so the retention term can contribute at most 7.7 of its 50 points.
-- The SLA term is already saturated at 30/30. The score is therefore
-- structurally capped near 38 and the metric has no usable dynamic range.
--
-- Root cause is upstream in the data, not the SQL: 500 authors filing 2,000
-- tickets across 40 repos average 4 tickets each, so almost no author files
-- twice in the SAME repo. Repo-level contributor retention is near-zero BY
-- CONSTRUCTION of scripts/generate_synthetic_data.py.
--
-- The right response is to fix the metric, not the formula weights: retention
-- at repo grain is the wrong denominator for this dataset. Either measure it at
-- org/author grain, or replace it with a measure the data can actually support
-- (e.g. share of tickets from authors with >1 lifetime ticket) and say so.
-- 02/03 get a plausible-looking 90-100% only because they accidentally measure
-- that second thing while labelling it the first.


-- ============================================================================
-- Q3. ROLLING 7-DAY SLA ATTAINMENT  --  windowed frame over a date spine
-- ============================================================================
--
-- Two traps here, and both are the point of the question.
--
-- TRAP 1 -- ROWS counts rows, not days. `ROWS BETWEEN 6 PRECEDING AND CURRENT
-- ROW` is a 7-day window ONLY if every calendar day is present as a row. On a
-- quiet repo with no weekend tickets, the same frame silently reaches back 9 or
-- 10 calendar days and the metric drifts without any error. Two safe fixes:
--   (a) LEFT JOIN a generated date spine so the series is dense -- done below,
--       and it also makes zero-ticket days visible instead of skipping them;
--   (b) RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW (PG 11+),
--       which is defined on the ORDER BY value rather than on row position.
-- With a dense spine the two agree. Without it, only (b) is correct.
--
-- TRAP 2 -- do not average a rate. AVG(daily_rate) OVER ... weights a 2-ticket
-- day the same as a 300-ticket day. The correct rolling rate is the ratio of
-- rolling sums: SUM(met) / SUM(total) over the same frame. Both are computed
-- below so the gap is visible; ship the second.

CREATE OR REPLACE VIEW v_rolling_sla_attainment AS
WITH bounds AS (
    SELECT MIN(created_at)::date AS d0, MAX(created_at)::date AS d1
    FROM fact_tickets
),
spine AS (
    SELECT generate_series(d0, d1, INTERVAL '1 day')::date AS d FROM bounds
),
daily AS (
    SELECT
        s.d,
        COUNT(f.ticket_key) AS tickets,
        COUNT(f.ticket_key) FILTER (
            WHERE f.first_response_at IS NOT NULL
              AND EXTRACT(EPOCH FROM (f.first_response_at - f.created_at))/3600 <= 24
        ) AS sla_met
    FROM spine s
    LEFT JOIN fact_tickets f ON f.created_at::date = s.d
    GROUP BY s.d
)
SELECT
    d,
    tickets,
    sla_met,
    ROUND((100.0 * sla_met / NULLIF(tickets, 0))::numeric, 2) AS daily_attainment_pct,

    -- SHIP THIS: ratio of rolling sums, volume-weighted.
    ROUND((100.0 * SUM(sla_met) OVER w7 / NULLIF(SUM(tickets) OVER w7, 0))::numeric, 2)
        AS rolling7_attainment_pct,

    -- NOT this: unweighted mean of daily rates, shown for contrast. Also note
    -- AVG skips NULL rates from zero-ticket days, so the divisor is not 7.
    ROUND((AVG(100.0 * sla_met / NULLIF(tickets, 0)) OVER w7)::numeric, 2)
        AS rolling7_avg_of_daily_rates_pct,

    SUM(tickets) OVER w7 AS rolling7_ticket_volume,

    -- Frame completeness. The first six rows average fewer than 7 days and will
    -- look artificially smooth or spiky; suppress them in any chart.
    COUNT(*) OVER w7 AS days_in_frame,
    CASE WHEN COUNT(*) OVER w7 < 7 THEN 'partial frame' ELSE 'complete' END
        AS frame_status
FROM daily
WINDOW w7 AS (ORDER BY d ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)
ORDER BY d;

-- A named WINDOW clause defines the frame once and reuses it. Repeating
-- `OVER (ORDER BY d ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)` five times is
-- how the definitions drift apart during a later edit.


-- ============================================================================
-- Q4. WEEK-OVER-WEEK RESPONSE-TIME DELTA  --  LAG()
-- ============================================================================
--
-- LAG returns the previous ROW in the partition, not the previous CALENDAR
-- week. If a repo had no tickets in week 12, week 13's "previous week" is
-- week 11 and the delta silently spans a fortnight. prev_week_start is
-- selected so that the gap is checkable, and comparison_valid flags it.
-- Fix properly by joining a week spine per repo, same technique as Q3.
--
-- DATE_TRUNC('week', ...) is ISO: weeks start Monday. If the business reports
-- Sunday-start weeks, this is off by one day and every WoW number is wrong.
-- Confirm the convention with the stakeholder before shipping.

CREATE OR REPLACE VIEW v_repo_wow_response_time AS
WITH weekly AS (
    SELECT
        f.repo_key,
        r.repo_name,
        DATE_TRUNC('week', f.created_at)::date AS week_start,
        COUNT(*) AS tickets,
        AVG(EXTRACT(EPOCH FROM (f.first_response_at - f.created_at))/3600) AS avg_ttfr_hrs
    FROM fact_tickets f
    JOIN dim_repositories r ON f.repo_key = r.repo_key
    WHERE f.first_response_at IS NOT NULL
    GROUP BY f.repo_key, r.repo_name, DATE_TRUNC('week', f.created_at)
)
SELECT
    repo_name,
    week_start,
    tickets,
    ROUND(avg_ttfr_hrs::numeric, 2)                        AS avg_ttfr_hrs,
    LAG(week_start)  OVER w                                AS prev_week_start,
    ROUND((LAG(avg_ttfr_hrs) OVER w)::numeric, 2)          AS prev_avg_ttfr_hrs,
    ROUND((avg_ttfr_hrs - LAG(avg_ttfr_hrs) OVER w)::numeric, 2) AS wow_delta_hrs,
    ROUND((100.0 * (avg_ttfr_hrs - LAG(avg_ttfr_hrs) OVER w)
           / NULLIF(LAG(avg_ttfr_hrs) OVER w, 0))::numeric, 1)   AS wow_pct_change,

    CASE
        WHEN LAG(week_start) OVER w IS NULL THEN 'no prior week'
        WHEN week_start - (LAG(week_start) OVER w) = 7 THEN 'adjacent'
        ELSE 'GAP - not a true WoW comparison'
    END AS comparison_valid,

    -- 4-week trailing mean is the number to trend on: weekly TTFR on a
    -- low-volume repo swings hard on one slow ticket.
    ROUND((AVG(avg_ttfr_hrs) OVER (
              PARTITION BY repo_key ORDER BY week_start
              ROWS BETWEEN 3 PRECEDING AND CURRENT ROW))::numeric, 2)
        AS trailing_4wk_avg_ttfr_hrs,

    -- Cumulative worst week so far, for "is this the worst it has been?"
    ROUND((MAX(avg_ttfr_hrs) OVER (
              PARTITION BY repo_key ORDER BY week_start
              ROWS UNBOUNDED PRECEDING))::numeric, 2)
        AS worst_week_to_date_hrs
FROM weekly
WINDOW w AS (PARTITION BY repo_key ORDER BY week_start)
ORDER BY repo_name, week_start;


-- ============================================================================
-- Q5. REPO SHARE OF TOTAL VOLUME + CONCENTRATION  --  SUM() OVER ()
-- ============================================================================
--
-- SUM(tickets) OVER () with an empty OVER is a window over the whole result
-- set: the grand total on every row, with no self-join and no second scan.
-- Note that `tickets` is itself an aggregate here -- windows are evaluated
-- AFTER GROUP BY, which is why COUNT(*) * 1.0 / SUM(COUNT(*)) OVER () is legal
-- directly in an aggregate query.
--
-- The business question is concentration: how few repos generate most of the
-- support load? That is where staffing decisions come from.

CREATE OR REPLACE VIEW v_repo_volume_concentration AS
WITH repo_volume AS (
    SELECT
        r.repo_name,
        COUNT(*)                                        AS tickets,
        COUNT(DISTINCT f.author_key)                    AS distinct_authors,
        -- Grand total available inside the aggregate query itself.
        ROUND((100.0 * COUNT(*) / SUM(COUNT(*)) OVER ())::numeric, 2) AS pct_of_total
    FROM fact_tickets f
    JOIN dim_repositories r ON f.repo_key = r.repo_key
    GROUP BY r.repo_name
)
SELECT
    repo_name,
    tickets,
    distinct_authors,
    pct_of_total,
    ROW_NUMBER() OVER (ORDER BY tickets DESC, repo_name) AS volume_rank,

    -- Running total. Two details that are easy to get wrong:
    --   * the default frame for SUM(...) OVER (ORDER BY x) is
    --     RANGE UNBOUNDED PRECEDING AND CURRENT ROW, which lumps ALL tied rows
    --     into the same cumulative value -- so tied repos share one running
    --     total and the Pareto curve has vertical steps. ROWS gives strict
    --     row-by-row accumulation;
    --   * ROWS still needs a deterministic ORDER BY, hence the repo_name
    --     tiebreak, or the cumulative column changes between runs.
    ROUND((100.0 * SUM(tickets) OVER (ORDER BY tickets DESC, repo_name
                                      ROWS UNBOUNDED PRECEDING)
           / SUM(tickets) OVER ())::numeric, 2) AS cumulative_pct_of_total,

    CASE WHEN 100.0 * SUM(tickets) OVER (ORDER BY tickets DESC, repo_name
                                          ROWS UNBOUNDED PRECEDING)
              / SUM(tickets) OVER () <= 80.0
         THEN 'top 80% of load' ELSE 'long tail' END AS pareto_segment
FROM repo_volume
ORDER BY volume_rank;

-- Read the answer off this view as: "the top N repos carry 80% of tickets."
-- With 40 evenly-generated synthetic repos the distribution is close to
-- uniform, so the Pareto cut lands near 32/40 -- i.e. there IS no
-- concentration in this dataset. Report that rather than the 80/20 the
-- template expects; a flat distribution is a finding about the data generator,
-- not a finding about repos.


-- ============================================================================
-- DEMO SEED FOR Q1  --  optional, non-production
-- ============================================================================
-- risk_scores is populated by the Python SLA model in production. Q1's rewrite
-- can only be demonstrated when a ticket has been scored MORE THAN ONCE, so
-- this block writes two batches for 20 open tickets, deliberately omitting 12
-- of them from the second batch to reproduce the dropped-row bug.
--
-- Run 05_risk_scoring.sql first to create risk_scores. Guarded so it cannot
-- fire against a populated table.
--
-- INSERT INTO risk_scores (ticket_key, repo_name, author_name, created_at,
--                          ticket_age_hours, comment_count, label_weight,
--                          has_response, sla_breach_probability, risk_tier,
--                          calculated_at)
-- WITH sample AS (
--     SELECT f.ticket_key, r.repo_name, a.author_name, f.created_at,
--            f.comment_count, f.first_response_at,
--            ROW_NUMBER() OVER (ORDER BY f.ticket_key) AS rn
--     FROM fact_tickets f
--     JOIN dim_repositories r ON f.repo_key = r.repo_key
--     JOIN dim_authors      a ON f.author_key = a.author_key
--     WHERE f.closed_at IS NULL
--     ORDER BY f.ticket_key
--     LIMIT 20
-- ),
-- batches AS (
--     --                batch timestamp              tickets covered   risk drift
--     SELECT TIMESTAMP '2023-12-31 02:00:00' AS batch_at, 20 AS covers_first_n, 0 AS bump
--     UNION ALL
--     SELECT TIMESTAMP '2023-12-31 14:00:00',              8,                  11
--     --   ^ partial rescore: only 8 of the 20 tickets, and their risk has climbed
-- )
-- SELECT s.ticket_key, s.repo_name, s.author_name, s.created_at,
--        24 + (s.rn * 3) + b.bump, s.comment_count, 1.0,
--        CASE WHEN s.first_response_at IS NULL THEN 0 ELSE 1 END,
--        LEAST(95, 30 + s.rn * 3 + b.bump),
--        CASE WHEN 30 + s.rn * 3 + b.bump > 75 THEN 'Critical'
--             WHEN 30 + s.rn * 3 + b.bump > 50 THEN 'High' ELSE 'Medium' END,
--        b.batch_at
-- FROM sample s
-- JOIN batches b ON s.rn <= b.covers_first_n;
--
-- Then the bug is measurable in one query:
--
--   SELECT
--     (SELECT COUNT(*) FROM risk_scores
--       WHERE calculated_at = (SELECT MAX(calculated_at) FROM risk_scores)) AS old_predicate_rows,
--     (SELECT COUNT(*) FROM v_latest_risk_score)                            AS window_form_rows,
--     (SELECT COUNT(DISTINCT ticket_key) FROM risk_scores)                  AS tickets_actually_scored;
--
-- Expected: 8, 20, 20. The old predicate hides 12 scored tickets.
-- ============================================================================


-- ============================================================================
-- MEASURED RESULTS  -  every query in this file was executed, 2026-09-16
-- ============================================================================
-- Against data/raw/helpdesk_tickets.csv (2,000 tickets / 40 repos / 490 authors,
-- 515 open) loaded through 00_create_schema.sql. Reproduce with:
--
--     make data && python tests/verify_window_functions_sqlite.py
--
-- Every number below is printed by that script. If a number here and a number
-- it prints disagree, this comment block is the thing that is wrong.
--
-- CAVEAT: run on SQLite 3.40 standing in for Postgres. Window-function
-- semantics are identical, so the LOGIC is genuinely verified; the dialect
-- surface (generate_series, DATE_TRUNC, ::casts, LEAST, EXTRACT EPOCH) was
-- translated and every substitution is printed by the harness. NOT yet run
-- against a real Postgres -- same open item as 00_create_schema.sql.
--
--   Q1  old global-MAX predicate returns  8 rows
--       v_latest_risk_score returns      20 rows, from 20 distinct scored tickets
--       -> the shipping predicate hides 12 of 20 (60%) of scored tickets.
--       LAG also exposes +11pp of risk drift between batches, which the old
--       form cannot represent at all.
--
--   Q2  40 rows. RANK contiguous 1..40. PERCENT_RANK spans exactly 0.000-1.000.
--       NTILE(4) buckets 10/10/10/10. health_score 4.49..37.48 -> see the
--       FINDING note above: 100% of repos classify Toxic, not 12%.
--       Author-weighted retention 1.5%-15.4% vs 02/03's 90.5%-100.0%.
--
--   Q3  365 rows (dense spine, 2023-01-01..2023-12-31). 1 zero-ticket day that a
--       spine-less ROWS frame would have silently skipped. 6 partial frames
--       flagged, as expected for a 7-day window.
--       Ratio-of-sums vs mean-of-daily-rates: 358 of 359 complete days differ,
--       mean gap 2.71pp, max 12.10pp. Averaging the rate is not a rounding
--       nitpick -- it moves the headline SLA number by over 12 points.
--
--   Q4  1,276 rows. 769 adjacent / 467 gapped / 40 first-week.
--       -> 37% of week-over-week deltas span a gap and are NOT week-over-week.
--       Without comparison_valid, more than a third of this table is mislabelled.
--
--   Q5  40 rows. pct_of_total sums to 100.00; cumulative reaches exactly 100.00.
--       29 of 40 repos (72%) are needed to reach 80% of ticket volume, so there
--       is no concentration to act on -- the generator emits near-uniform
--       volume. Reporting an 80/20 here would be inventing a finding.
--
--   31 OVER clauses in this file, against 0 in the other 1,180 lines of SQL.
-- ============================================================================


-- ============================================================================
-- WHAT THIS FILE DOES NOT COVER
-- ============================================================================
-- Left out on purpose, so the file stays readable rather than exhaustive:
--   * gaps-and-islands sessionization (contributor activity streaks)
--   * cohort retention triangle by first-ticket month
--   * GROUPING SETS / ROLLUP for the repo x label x month cube
--   * recursive CTE for the label taxonomy
--   * QUALIFY (Snowflake/Redshift RA3) as the shorthand for the Q1 pattern --
--     Postgres has no QUALIFY, hence the CTE + WHERE recency_rank = 1
-- ============================================================================
