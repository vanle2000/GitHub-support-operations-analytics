-- ============================================================================
-- 00_create_schema.sql  -  Star schema DDL + load
-- GitHub Support Operations Analytics
-- Database: PostgreSQL 12+
-- ============================================================================
--
-- Run FIRST. Files 02-06 query fact_tickets, dim_repositories, dim_authors and
-- dim_labels; before this file existed, no file in the repo created any of them,
-- so 02-06 failed with "relation does not exist" and nothing ran end to end.
--
-- 01_repo_health_view.sql defines a DIFFERENT, incompatible schema
-- (analytics.fact_issues / dim_repository / dim_contributor, keyed repo_id /
-- contributor_id / issue_id). That file is superseded and should be deleted or
-- rewritten against this schema. Do not run both.
--
-- Grain of fact_tickets: one row per support ticket. Surrogate integer keys are
-- minted here from the natural business keys in the source extract.
--
-- Order:
--   1. schema + dimensions + fact
--   2. staging table
--   3. load (staging -> dims -> fact)
--   4. constraints + indexes
--   5. verification
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS analytics;
SET search_path TO analytics, public;

-- ============================================================================
-- 1. DIMENSIONS
-- ============================================================================

DROP TABLE IF EXISTS fact_tickets CASCADE;
DROP TABLE IF EXISTS dim_repositories CASCADE;
DROP TABLE IF EXISTS dim_authors CASCADE;
DROP TABLE IF EXISTS dim_labels CASCADE;

CREATE TABLE dim_repositories (
    repo_key     BIGSERIAL PRIMARY KEY,
    repo_name    VARCHAR(255) NOT NULL UNIQUE
);

-- author_tier is read by 02, 03 and 06 but was never defined anywhere in the
-- repo. Defined here as a materialized behavioural attribute so the tier logic
-- lives in one place instead of being assumed by each view.
--   Newbie     : 1 ticket lifetime
--   Regular    : 2-4 tickets
--   Maintainer : 5+ tickets
CREATE TABLE dim_authors (
    author_key      BIGSERIAL PRIMARY KEY,
    author_name     VARCHAR(255) NOT NULL UNIQUE,
    lifetime_tickets INTEGER NOT NULL,
    author_tier     VARCHAR(20) NOT NULL
        CHECK (author_tier IN ('Newbie', 'Regular', 'Maintainer'))
);

-- Label standardization. Mirrors the label_map in Notebooks/01_data_exploration.ipynb
-- so the notebook and the warehouse cannot drift.
CREATE TABLE dim_labels (
    label_key             BIGSERIAL PRIMARY KEY,
    raw_label             VARCHAR(100) NOT NULL UNIQUE,
    standardized_category VARCHAR(50)  NOT NULL
        CHECK (standardized_category IN
               ('High Priority - Bug', 'Feature Request', 'User Inquiry', 'Other / General'))
);

-- ============================================================================
-- 2. FACT
-- ============================================================================

CREATE TABLE fact_tickets (
    ticket_key        BIGSERIAL PRIMARY KEY,
    ticket_id         VARCHAR(50)  NOT NULL UNIQUE,   -- natural key from source
    repo_key          BIGINT       NOT NULL,
    author_key        BIGINT       NOT NULL,
    label_key         BIGINT       NOT NULL,
    created_at        TIMESTAMP    NOT NULL,
    first_response_at TIMESTAMP,                      -- NULL = never answered
    closed_at         TIMESTAMP,                      -- NULL = still open
    comment_count     INTEGER      NOT NULL DEFAULT 0,
    milestone         VARCHAR(50)
);

-- NOTE: 02_repo_health_metrics_postgresql.sql opens with a standalone SELECT
-- referencing fact_tickets.is_retained and fact_tickets.response_time_hrs.
-- Neither column is created here, deliberately: is_retained is an author-grain
-- attribute (it belongs on dim_authors, and duplicating it per ticket is what
-- produces the ticket-weighted retention bug), and response_time_hrs is
-- derivable from first_response_at - created_at, so persisting it would let the
-- two disagree. That standalone SELECT should be deleted.

-- ============================================================================
-- 3. STAGING + LOAD
-- ============================================================================
-- Load path:
--   make data                     -> data/raw/helpdesk_tickets.csv
--   \copy into stg_helpdesk_tickets
--   run the INSERTs below

DROP TABLE IF EXISTS stg_helpdesk_tickets;
CREATE TABLE stg_helpdesk_tickets (
    ticket_id                 VARCHAR(50),
    repo_name                 VARCHAR(255),
    author_name               VARCHAR(255),
    labels                    VARCHAR(100),
    created_at                TIMESTAMP,
    first_response_at         TIMESTAMP,
    closed_at                 TIMESTAMP,
    ttfr_hours                NUMERIC(10,2),
    sla_met                   SMALLINT,
    comment_count             INTEGER,
    is_closed                 SMALLINT,
    milestone                 VARCHAR(50),
    repo_health_score         NUMERIC(5,3),
    contributor_retention_rate NUMERIC(5,3),
    issue_question            TEXT,
    last_comment_text         TEXT,
    ticket_key_src            VARCHAR(50)
);

-- \copy analytics.stg_helpdesk_tickets FROM 'data/raw/helpdesk_tickets.csv' WITH (FORMAT csv, HEADER true, NULL '')

-- 3a. Repositories
INSERT INTO dim_repositories (repo_name)
SELECT DISTINCT repo_name
FROM stg_helpdesk_tickets
WHERE repo_name IS NOT NULL
ON CONFLICT (repo_name) DO NOTHING;

-- 3b. Authors, with tier derived from lifetime volume
INSERT INTO dim_authors (author_name, lifetime_tickets, author_tier)
SELECT
    author_name,
    COUNT(*) AS lifetime_tickets,
    CASE
        WHEN COUNT(*) >= 5 THEN 'Maintainer'
        WHEN COUNT(*) >= 2 THEN 'Regular'
        ELSE 'Newbie'
    END AS author_tier
FROM stg_helpdesk_tickets
WHERE author_name IS NOT NULL
GROUP BY author_name
ON CONFLICT (author_name) DO NOTHING;

-- 3c. Labels
INSERT INTO dim_labels (raw_label, standardized_category)
SELECT DISTINCT
    labels,
    CASE LOWER(labels)
        WHEN 'bug'           THEN 'High Priority - Bug'
        WHEN 'critical-bug'  THEN 'High Priority - Bug'
        WHEN 'vulnerability' THEN 'High Priority - Bug'
        WHEN 'security'      THEN 'High Priority - Bug'
        WHEN 'enhancement'   THEN 'Feature Request'
        WHEN 'feature'       THEN 'Feature Request'
        WHEN 'question'      THEN 'User Inquiry'
        WHEN 'help wanted'   THEN 'User Inquiry'
        ELSE 'Other / General'
    END
FROM stg_helpdesk_tickets
WHERE labels IS NOT NULL
ON CONFLICT (raw_label) DO NOTHING;

-- 3d. Fact. INNER JOINs are correct here because all three dimension rows are
-- guaranteed by 3a-3c; any row that fails to join is a load defect and is
-- caught by the verification block in section 5.
INSERT INTO fact_tickets
    (ticket_id, repo_key, author_key, label_key,
     created_at, first_response_at, closed_at, comment_count, milestone)
SELECT
    s.ticket_id,
    r.repo_key,
    a.author_key,
    l.label_key,
    s.created_at,
    s.first_response_at,
    s.closed_at,
    COALESCE(s.comment_count, 0),
    s.milestone
FROM stg_helpdesk_tickets s
JOIN dim_repositories r ON s.repo_name  = r.repo_name
JOIN dim_authors      a ON s.author_name = a.author_name
JOIN dim_labels       l ON s.labels      = l.raw_label
ON CONFLICT (ticket_id) DO NOTHING;

-- ============================================================================
-- 4. CONSTRAINTS + INDEXES
-- ============================================================================
-- Referential integrity added after load so the bulk insert is not row-checked.

ALTER TABLE fact_tickets
    ADD CONSTRAINT fk_tickets_repo   FOREIGN KEY (repo_key)   REFERENCES dim_repositories(repo_key),
    ADD CONSTRAINT fk_tickets_author FOREIGN KEY (author_key) REFERENCES dim_authors(author_key),
    ADD CONSTRAINT fk_tickets_label  FOREIGN KEY (label_key)  REFERENCES dim_labels(label_key);

-- Timeline sanity. These are the data-quality guarantees every downstream view
-- silently assumes; enforcing them here is cheaper than debugging a negative
-- resolution time in a dashboard.
ALTER TABLE fact_tickets
    ADD CONSTRAINT ck_response_after_create
        CHECK (first_response_at IS NULL OR first_response_at >= created_at),
    ADD CONSTRAINT ck_closed_after_create
        CHECK (closed_at IS NULL OR closed_at >= created_at),
    ADD CONSTRAINT ck_comment_count_nonneg
        CHECK (comment_count >= 0);

CREATE INDEX idx_tickets_repo        ON fact_tickets(repo_key);
CREATE INDEX idx_tickets_author      ON fact_tickets(author_key);
CREATE INDEX idx_tickets_label       ON fact_tickets(label_key);
CREATE INDEX idx_tickets_created     ON fact_tickets(created_at);
-- Partial index: the risk and open-ticket views all filter closed_at IS NULL,
-- which is ~25% of rows.
CREATE INDEX idx_tickets_open        ON fact_tickets(created_at) WHERE closed_at IS NULL;
-- Covering index for the repo x month rollups in 06.
CREATE INDEX idx_tickets_repo_created ON fact_tickets(repo_key, created_at)
    INCLUDE (first_response_at, closed_at, comment_count);

ANALYZE dim_repositories;
ANALYZE dim_authors;
ANALYZE dim_labels;
ANALYZE fact_tickets;

-- ============================================================================
-- 5. VERIFICATION  -  every row must report PASS
-- ============================================================================

WITH checks AS (
    SELECT 'fact row count matches staging' AS check_name,
           (SELECT COUNT(*) FROM fact_tickets) AS actual,
           (SELECT COUNT(*) FROM stg_helpdesk_tickets) AS expected
    UNION ALL
    SELECT 'no orphan repo_key',
           (SELECT COUNT(*) FROM fact_tickets f
             LEFT JOIN dim_repositories r ON f.repo_key = r.repo_key
             WHERE r.repo_key IS NULL), 0
    UNION ALL
    SELECT 'no orphan author_key',
           (SELECT COUNT(*) FROM fact_tickets f
             LEFT JOIN dim_authors a ON f.author_key = a.author_key
             WHERE a.author_key IS NULL), 0
    UNION ALL
    SELECT 'no orphan label_key',
           (SELECT COUNT(*) FROM fact_tickets f
             LEFT JOIN dim_labels l ON f.label_key = l.label_key
             WHERE l.label_key IS NULL), 0
    UNION ALL
    SELECT 'no duplicate ticket_id',
           (SELECT COUNT(*) FROM (
                SELECT ticket_id FROM fact_tickets
                GROUP BY ticket_id HAVING COUNT(*) > 1) d), 0
    UNION ALL
    SELECT 'no negative resolution time',
           (SELECT COUNT(*) FROM fact_tickets
             WHERE closed_at IS NOT NULL AND closed_at < created_at), 0
    UNION ALL
    SELECT 'every author has a tier',
           (SELECT COUNT(*) FROM dim_authors WHERE author_tier IS NULL), 0
)
SELECT check_name, expected, actual,
       CASE WHEN actual = expected THEN 'PASS' ELSE 'FAIL' END AS status
FROM checks
ORDER BY status, check_name;

-- ============================================================================
-- 6. KNOWN DEFECTS IN DOWNSTREAM FILES  -  this schema does not fix these
-- ============================================================================
--
-- Creating these tables makes 02-06 executable. It does not make them correct.
-- Open, tracked in HANDOFF.md:
--
--   a) THREE different health_status definitions across the repo:
--        02/03 health_score  : retention*50 + sla*30 - LEAST(resolution*0.1, 20)
--                              scale ceiling 80, tiers 40/75,
--                              labels Toxic / Stable / Healthy-Elite
--        02/03 health_status : same but the resolution penalty is UNCAPPED,
--                              so 4 of 40 repos get a score and a label that
--                              disagree
--        06    weighted_health_score :
--                              retention_pct*0.5 + sla_pct*0.3
--                              - ((resolution/720*30) * 0.2)
--                              tiers 50/75, labels Toxic / At Risk / Healthy
--      Only 06 matches the 0.5/0.3/0.2 weights documented in the README.
--      Pick one, put it in ONE view, and have the others select from it.
--
--   b) retention_rate in 02/03 is ticket-weighted, not author-weighted, and
--      keys off author_tier instead of "author has >1 ticket in THIS repo".
--      Measured error vs its own documented definition: 92.6 percentage points.
--      With dim_authors.lifetime_tickets now available, the author-weighted
--      version is a COUNT(DISTINCT author_key) away.
--
--   c) Every view in 06 filters created_at >= CURRENT_DATE - INTERVAL '90 days'.
--      The generated data is entirely 2023, so all five executive views return
--      ZERO ROWS. Either make the generator emit recent dates or parameterize
--      the window.
--
--   d) Zero window functions across SQL/*.sql. The latest-snapshot predicate
--      WHERE calculated_at = (SELECT MAX(calculated_at) FROM risk_scores)
--      is repeated in five views in 05 and is a ROW_NUMBER() away. See
--      07_window_functions.sql.
--
--   e) 02 and 03 are near-duplicate copies of the same buggy formula. Delete 03.
-- ============================================================================
