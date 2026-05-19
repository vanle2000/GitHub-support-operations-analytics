
-- Create schema if it doesn't exist
CREATE SCHEMA IF NOT EXISTS analytics;

-- ============================================================================
-- 1. DIMENSIONS TABLES (Base Tables)
-- ============================================================================

-- Repository dimension table
CREATE TABLE IF NOT EXISTS analytics.dim_repository (
    repo_id SERIAL PRIMARY KEY,
    repo_name VARCHAR(255) NOT NULL UNIQUE,
    owner_name VARCHAR(255) NOT NULL,
    url TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Contributors dimension table
CREATE TABLE IF NOT EXISTS analytics.dim_contributor (
    contributor_id SERIAL PRIMARY KEY,
    github_username VARCHAR(255) NOT NULL UNIQUE,
    email VARCHAR(255),
    first_contribution_date DATE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Issues fact table
CREATE TABLE IF NOT EXISTS analytics.fact_issues (
    issue_id BIGINT PRIMARY KEY,
    repo_id INT NOT NULL REFERENCES analytics.dim_repository(repo_id),
    contributor_id INT REFERENCES analytics.dim_contributor(contributor_id),
    title VARCHAR(512),
    created_at TIMESTAMP NOT NULL,
    first_response_at TIMESTAMP,
    resolved_at TIMESTAMP,
    initial_sentiment NUMERIC(3,2),
    final_sentiment NUMERIC(3,2),
    comment_count INT DEFAULT 0,
    is_resolved BOOLEAN DEFAULT FALSE,
    FOREIGN KEY (repo_id) REFERENCES analytics.dim_repository(repo_id),
    FOREIGN KEY (contributor_id) REFERENCES analytics.dim_contributor(contributor_id)
);

-- Create indexes for optimal query performance
CREATE INDEX IF NOT EXISTS idx_issues_repo ON analytics.fact_issues(repo_id);
CREATE INDEX IF NOT EXISTS idx_issues_contributor ON analytics.fact_issues(contributor_id);
CREATE INDEX IF NOT EXISTS idx_issues_created ON analytics.fact_issues(created_at);
CREATE INDEX IF NOT EXISTS idx_issues_resolved ON analytics.fact_issues(is_resolved);

-- ============================================================================
-- 2. METRIC CALCULATION VIEW: SLA Compliance
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_sla_metrics AS
SELECT 
    repo_id,
    COUNT(*) FILTER (WHERE first_response_at IS NOT NULL) as issues_with_response,
    COUNT(*) FILTER (WHERE first_response_at IS NOT NULL 
                      AND EXTRACT(EPOCH FROM (first_response_at - created_at)) / 3600 <= 24) as sla_met_count,
    COUNT(*) as total_issues,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE first_response_at IS NOT NULL 
                                  AND EXTRACT(EPOCH FROM (first_response_at - created_at)) / 3600 <= 24) 
        / NULLIF(COUNT(*) FILTER (WHERE first_response_at IS NOT NULL), 0),
        2
    ) as sla_compliance_pct,
    ROUND(
        AVG(EXTRACT(EPOCH FROM (first_response_at - created_at)) / 3600) 
        FILTER (WHERE first_response_at IS NOT NULL),
        2
    ) as avg_time_to_first_response_hrs
FROM analytics.fact_issues
WHERE created_at >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY repo_id;

-- ============================================================================
-- 3. METRIC CALCULATION VIEW: Contributor Retention
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_retention_metrics AS
WITH contributor_activity AS (
    SELECT 
        repo_id,
        contributor_id,
        COUNT(*) as total_contributions,
        MAX(created_at) as last_activity_date,
        MIN(created_at) as first_activity_date,
        COUNT(DISTINCT DATE_TRUNC('month', created_at)) as active_months
    FROM analytics.fact_issues
    WHERE created_at >= CURRENT_DATE - INTERVAL '90 days'
    GROUP BY repo_id, contributor_id
),
repeat_contributors AS (
    SELECT 
        repo_id,
        COUNT(*) FILTER (WHERE total_contributions > 1) as repeat_contributor_count,
        COUNT(*) as unique_contributor_count,
        ROUND(
            100.0 * COUNT(*) FILTER (WHERE total_contributions > 1) 
            / NULLIF(COUNT(*), 0),
            2
        ) as repeat_contributor_pct
    FROM contributor_activity
    GROUP BY repo_id
)
SELECT 
    repo_id,
    unique_contributor_count,
    repeat_contributor_count,
    repeat_contributor_pct as contributor_retention_pct
FROM repeat_contributors;

-- ============================================================================
-- 4. METRIC CALCULATION VIEW: Resolution Time
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_resolution_metrics AS
SELECT 
    repo_id,
    COUNT(*) as total_issues,
    COUNT(*) FILTER (WHERE is_resolved = TRUE) as resolved_issues,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_resolved = TRUE) 
        / NULLIF(COUNT(*), 0),
        2
    ) as resolution_rate_pct,
    ROUND(
        AVG(EXTRACT(EPOCH FROM (resolved_at - created_at)) / 86400)
        FILTER (WHERE is_resolved = TRUE),
        2
    ) as avg_resolution_days,
    ROUND(
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (resolved_at - created_at)) / 86400)
        FILTER (WHERE is_resolved = TRUE),
        2
    ) as median_resolution_days
FROM analytics.fact_issues
WHERE created_at >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY repo_id;

-- ============================================================================
-- 5. SENTIMENT VOLATILITY VIEW
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_sentiment_volatility AS
SELECT 
    repo_id,
    COUNT(*) as total_issues_analyzed,
    COUNT(*) FILTER (WHERE comment_count >= 3) as volatile_issues_count,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE comment_count >= 3) 
        / NULLIF(COUNT(*), 0),
        2
    ) as sentiment_volatility_pct,
    ROUND(
        AVG(ABS(final_sentiment - initial_sentiment))
        FILTER (WHERE comment_count >= 3),
        3
    ) as avg_sentiment_shift
FROM analytics.fact_issues
WHERE created_at >= CURRENT_DATE - INTERVAL '90 days'
  AND initial_sentiment IS NOT NULL 
  AND final_sentiment IS NOT NULL
GROUP BY repo_id;

-- ============================================================================
-- 6. GOLDEN HOUR ANALYSIS (12-hour threshold)
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_golden_hour_impact AS
WITH contributor_response_timing AS (
    SELECT 
        i.repo_id,
        i.contributor_id,
        i.issue_id,
        EXTRACT(EPOCH FROM (i.first_response_at - i.created_at)) / 3600 as response_time_hrs,
        CASE 
            WHEN EXTRACT(EPOCH FROM (i.first_response_at - i.created_at)) / 3600 <= 12 THEN 'golden_hour'
            WHEN EXTRACT(EPOCH FROM (i.first_response_at - i.created_at)) / 3600 <= 24 THEN 'sla_met'
            ELSE 'sla_missed'
        END as response_tier
    FROM analytics.fact_issues i
    WHERE i.first_response_at IS NOT NULL
      AND i.created_at >= CURRENT_DATE - INTERVAL '90 days'
)
SELECT 
    repo_id,
    COUNT(*) FILTER (WHERE response_tier = 'golden_hour') as golden_hour_count,
    COUNT(*) FILTER (WHERE response_tier = 'sla_met') as sla_met_count,
    COUNT(*) FILTER (WHERE response_tier = 'sla_missed') as sla_missed_count,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE response_tier = 'golden_hour') 
        / NULLIF(COUNT(*), 0),
        2
    ) as golden_hour_pct
FROM contributor_response_timing
GROUP BY repo_id;

-- ============================================================================
-- 7. PRIMARY VIEW: REPOSITORY HEALTH SCORE (Weighted Composite)
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_repository_health_score AS
SELECT 
    r.repo_id,
    r.repo_name,
    r.owner_name,
    -- Component Metrics
    COALESCE(sla.sla_compliance_pct, 0) as sla_compliance_pct,
    COALESCE(ret.contributor_retention_pct, 0) as contributor_retention_pct,
    COALESCE(res.resolution_rate_pct, 0) as resolution_rate_pct,
    COALESCE(res.avg_resolution_days, 0) as avg_resolution_days,
    COALESCE(sent.sentiment_volatility_pct, 0) as sentiment_volatility_pct,
    COALESCE(gh.golden_hour_pct, 0) as golden_hour_response_pct,
    -- Weighted Health Score Calculation
    -- Score = (Retention * 0.5) + (SLAMet * 0.3) - (ResolutionTime * 0.2)
    -- Normalized to 0-100 scale
    ROUND(
        (COALESCE(ret.contributor_retention_pct, 0) * 0.5) +
        (COALESCE(sla.sla_compliance_pct, 0) * 0.3) -
        (CASE 
            WHEN COALESCE(res.avg_resolution_days, 0) > 30 THEN 30
            ELSE COALESCE(res.avg_resolution_days, 0)
         END * 0.2 / 30 * 100),
        2
    ) as weighted_health_score,
    -- Health Classification
    CASE 
        WHEN ROUND(
            (COALESCE(ret.contributor_retention_pct, 0) * 0.5) +
            (COALESCE(sla.sla_compliance_pct, 0) * 0.3) -
            (CASE 
                WHEN COALESCE(res.avg_resolution_days, 0) > 30 THEN 30
                ELSE COALESCE(res.avg_resolution_days, 0)
             END * 0.2 / 30 * 100),
            2
        ) >= 75 THEN 'Healthy'
        WHEN ROUND(
            (COALESCE(ret.contributor_retention_pct, 0) * 0.5) +
            (COALESCE(sla.sla_compliance_pct, 0) * 0.3) -
            (CASE 
                WHEN COALESCE(res.avg_resolution_days, 0) > 30 THEN 30
                ELSE COALESCE(res.avg_resolution_days, 0)
             END * 0.2 / 30 * 100),
            2
        ) >= 50 THEN 'At Risk'
        ELSE 'Toxic'
    END as health_status,
    -- Activity metrics
    COALESCE(sla.total_issues, 0) as total_issues_90d,
    COALESCE(sla.avg_time_to_first_response_hrs, 0) as avg_ttfr_hrs,
    CURRENT_TIMESTAMP as last_calculated_at
FROM analytics.dim_repository r
LEFT JOIN analytics.v_sla_metrics sla ON r.repo_id = sla.repo_id
LEFT JOIN analytics.v_retention_metrics ret ON r.repo_id = ret.repo_id
LEFT JOIN analytics.v_resolution_metrics res ON r.repo_id = res.repo_id
LEFT JOIN analytics.v_sentiment_volatility sent ON r.repo_id = sent.repo_id
LEFT JOIN analytics.v_golden_hour_impact gh ON r.repo_id = gh.repo_id
ORDER BY weighted_health_score DESC;

-- ============================================================================
-- 8. MATERIALIZED VIEW FOR PERFORMANCE (Optional - for high-volume queries)
-- ============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_repository_health_score AS
SELECT * FROM analytics.v_repository_health_score;

-- Create index on materialized view for faster lookups
CREATE INDEX IF NOT EXISTS idx_mv_health_score_repo_id 
ON analytics.mv_repository_health_score(repo_id);

CREATE INDEX IF NOT EXISTS idx_mv_health_status 
ON analytics.mv_repository_health_score(health_status);

-- ============================================================================
-- REFRESH SCHEDULE (PostgreSQL requires manual refresh)
-- Usage: SELECT analytics.refresh_health_metrics();
-- Recommended: Run every 6 hours via cron or scheduled task
-- ============================================================================

CREATE OR REPLACE FUNCTION analytics.refresh_health_metrics()
RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_repository_health_score;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- QUERY EXAMPLES
-- ============================================================================

/*
-- Example 1: Find all "Toxic" repositories
SELECT repo_name, owner_name, weighted_health_score, health_status
FROM analytics.v_repository_health_score
WHERE health_status = 'Toxic'
ORDER BY weighted_health_score ASC;

-- Example 2: Identify Golden Hour wins
SELECT repo_name, golden_hour_response_pct, contributor_retention_pct
FROM analytics.v_repository_health_score
WHERE golden_hour_response_pct > 70
ORDER BY golden_hour_response_pct DESC;

-- Example 3: SLA Performance dashboard
SELECT 
    health_status,
    COUNT(*) as repo_count,
    ROUND(AVG(weighted_health_score), 2) as avg_score,
    ROUND(AVG(sla_compliance_pct), 2) as avg_sla_pct,
    ROUND(AVG(contributor_retention_pct), 2) as avg_retention_pct
FROM analytics.v_repository_health_score
GROUP BY health_status;
*/
