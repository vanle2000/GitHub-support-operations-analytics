-- ============================================================================
-- Executive Health Summary Views - PostgreSQL
-- GitHub Support Operations Analytics
-- Purpose: Data Modeling at Scale - Aggregated metrics for Tableau
-- Source: Star Schema aggregation across all fact & dimension tables
-- Database: PostgreSQL 12+
-- ============================================================================

-- ============================================================================
-- PRIMARY EXECUTIVE VIEW: Comprehensive Repository Summary
-- ============================================================================

CREATE OR REPLACE VIEW v_executive_health_summary AS
SELECT  
    r.repo_name,
    l.standardized_category,
    COUNT(f.ticket_key) as total_tickets,
    COUNT(DISTINCT f.author_key) as unique_contributors,
    
    -- Retention & Community Health
    SUM(CASE WHEN a.author_tier = 'Maintainer' THEN 1 ELSE 0 END) as power_user_interactions,
    SUM(CASE WHEN a.author_tier = 'Newbie' THEN 1 ELSE 0 END) as newbie_interactions,
    ROUND(
        CAST(SUM(CASE WHEN a.author_tier = 'Maintainer' THEN 1 ELSE 0 END) AS FLOAT8) 
        / NULLIF(COUNT(f.ticket_key), 0) * 100,
        2
    ) as power_user_percentage,
    
    -- Resolution Velocity
    ROUND(AVG(EXTRACT(EPOCH FROM (f.closed_at - f.created_at)) / 3600), 2) as avg_resolution_time_hrs,
    ROUND(AVG(EXTRACT(EPOCH FROM (f.closed_at - f.created_at)) / 86400), 2) as avg_resolution_time_days,
    
    -- SLA Achievement (24-hour response threshold)
    ROUND(
        SUM(CASE WHEN EXTRACT(EPOCH FROM (f.first_response_at - f.created_at)) / 3600 <= 24 THEN 1 ELSE 0 END) * 100.0 
        / NULLIF(COUNT(f.ticket_key), 0),
        2
    ) as sla_achievement_rate_pct,
    
    -- Golden Hour Impact (12-hour response threshold)
    ROUND(
        SUM(CASE WHEN EXTRACT(EPOCH FROM (f.first_response_at - f.created_at)) / 3600 <= 12 THEN 1 ELSE 0 END) * 100.0 
        / NULLIF(COUNT(f.ticket_key), 0),
        2
    ) as golden_hour_achievement_pct,
    
    -- Ticket Status Distribution
    SUM(CASE WHEN f.closed_at IS NOT NULL THEN 1 ELSE 0 END) as closed_tickets,
    SUM(CASE WHEN f.closed_at IS NULL THEN 1 ELSE 0 END) as open_tickets,
    
    -- Comment Activity
    ROUND(AVG(CAST(f.comment_count AS FLOAT8)), 2) as avg_comment_count,
    
    CURRENT_TIMESTAMP as last_calculated
FROM fact_tickets f
JOIN dim_repositories r ON f.repo_key = r.repo_key
JOIN dim_labels l ON f.label_key = l.label_key
JOIN dim_authors a ON f.author_key = a.author_key
WHERE f.created_at >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY r.repo_name, l.standardized_category
ORDER BY total_tickets DESC;

-- ============================================================================
-- ENHANCED EXECUTIVE VIEW: Integrated with Health Scores & Risk Metrics
-- ============================================================================

CREATE OR REPLACE VIEW v_executive_integrated_health AS
WITH base_summary AS (
    SELECT  
        r.repo_name,
        COUNT(f.ticket_key) as total_tickets_90d,
        COUNT(DISTINCT f.author_key) as unique_contributors,
        ROUND(AVG(EXTRACT(EPOCH FROM (f.closed_at - f.created_at)) / 3600), 2) as avg_resolution_hrs,
        ROUND(
            SUM(CASE WHEN EXTRACT(EPOCH FROM (f.first_response_at - f.created_at)) / 3600 <= 24 THEN 1 ELSE 0 END) * 100.0 
            / NULLIF(COUNT(f.ticket_key), 0),
            2
        ) as sla_achievement_pct,
        ROUND(
            SUM(CASE WHEN a.author_tier != 'Newbie' THEN 1 ELSE 0 END) * 100.0 
            / NULLIF(COUNT(f.ticket_key), 0),
            2
        ) as retention_rate_pct,
        ROUND(AVG(CAST(f.comment_count AS FLOAT8)), 2) as avg_comment_count,
        SUM(CASE WHEN f.closed_at IS NULL THEN 1 ELSE 0 END) as open_tickets_current
    FROM fact_tickets f
    JOIN dim_repositories r ON f.repo_key = r.repo_key
    JOIN dim_authors a ON f.author_key = a.author_key
    WHERE f.created_at >= CURRENT_DATE - INTERVAL '90 days'
    GROUP BY r.repo_name
),
sentiment_summary AS (
    SELECT
        r.repo_name,
        ROUND(AVG(s.initial_sentiment), 3) as avg_initial_sentiment,
        ROUND(AVG(s.final_sentiment), 3) as avg_final_sentiment,
        ROUND(AVG(s.sentiment_shift), 3) as avg_sentiment_shift,
        SUM(CASE WHEN s.is_frustrated_user = 1 THEN 1 ELSE 0 END) as frustrated_user_count
    FROM fact_sentiment s
    JOIN fact_tickets f ON s.ticket_key = f.ticket_key
    JOIN dim_repositories r ON f.repo_key = r.repo_key
    WHERE f.created_at >= CURRENT_DATE - INTERVAL '90 days'
    GROUP BY r.repo_name
),
risk_summary AS (
    SELECT
        rs.repo_name,
        ROUND(AVG(rs.sla_breach_probability), 2) as avg_breach_probability,
        SUM(CASE WHEN rs.risk_tier = 'CRITICAL - Immediate Action' THEN 1 ELSE 0 END) as critical_risk_count,
        SUM(CASE WHEN rs.risk_tier = 'HIGH - Monitor Closely' THEN 1 ELSE 0 END) as high_risk_count,
        SUM(CASE WHEN rs.risk_tier LIKE 'CRITICAL%' OR rs.risk_tier LIKE 'HIGH%' THEN 1 ELSE 0 END) as at_risk_ticket_count
    FROM risk_scores rs
    WHERE rs.calculated_at = (SELECT MAX(calculated_at) FROM risk_scores)
    GROUP BY rs.repo_name
)
SELECT
    b.repo_name,
    b.total_tickets_90d,
    b.unique_contributors,
    b.open_tickets_current,
    b.avg_resolution_hrs,
    b.sla_achievement_pct,
    b.retention_rate_pct,
    b.avg_comment_count,
    -- Health Score (calculated formula)
    ROUND(
        (b.retention_rate_pct * 0.5) + 
        (b.sla_achievement_pct * 0.3) - 
        (CASE WHEN b.avg_resolution_hrs > 720 THEN 30 ELSE (b.avg_resolution_hrs / 720 * 30) END * 0.2),
        2
    ) as weighted_health_score,
    -- Sentiment Metrics
    COALESCE(s.avg_initial_sentiment, 0) as avg_initial_sentiment,
    COALESCE(s.avg_final_sentiment, 0) as avg_final_sentiment,
    COALESCE(s.avg_sentiment_shift, 0) as avg_sentiment_shift,
    COALESCE(s.frustrated_user_count, 0) as frustrated_user_count,
    -- Risk Metrics
    COALESCE(r.avg_breach_probability, 0) as avg_sla_breach_probability,
    COALESCE(r.critical_risk_count, 0) as critical_risk_tickets,
    COALESCE(r.high_risk_count, 0) as high_risk_tickets,
    COALESCE(r.at_risk_ticket_count, 0) as total_at_risk_tickets,
    -- Classification
    CASE
        WHEN ROUND((b.retention_rate_pct * 0.5) + (b.sla_achievement_pct * 0.3) - (CASE WHEN b.avg_resolution_hrs > 720 THEN 30 ELSE (b.avg_resolution_hrs / 720 * 30) END * 0.2), 2) >= 75 THEN 'Healthy'
        WHEN ROUND((b.retention_rate_pct * 0.5) + (b.sla_achievement_pct * 0.3) - (CASE WHEN b.avg_resolution_hrs > 720 THEN 30 ELSE (b.avg_resolution_hrs / 720 * 30) END * 0.2), 2) >= 50 THEN 'At Risk'
        ELSE 'Toxic'
    END as health_status,
    CURRENT_TIMESTAMP as last_calculated
FROM base_summary b
LEFT JOIN sentiment_summary s ON b.repo_name = s.repo_name
LEFT JOIN risk_summary r ON b.repo_name = r.repo_name
ORDER BY weighted_health_score DESC;

-- ============================================================================
-- EXECUTIVE DASHBOARD VIEW: KPI Summary
-- ============================================================================

CREATE OR REPLACE VIEW v_executive_kpi_summary AS
SELECT
    'Overall Portfolio' as metric_category,
    COUNT(*) as repo_count,
    SUM(total_tickets_90d) as total_tickets_90d,
    SUM(unique_contributors) as total_contributors,
    SUM(open_tickets_current) as total_open_tickets,
    ROUND(AVG(sla_achievement_pct), 2) as portfolio_avg_sla_pct,
    ROUND(AVG(retention_rate_pct), 2) as portfolio_avg_retention_pct,
    ROUND(AVG(weighted_health_score), 2) as portfolio_avg_health_score,
    COUNT(CASE WHEN health_status = 'Healthy' THEN 1 END) as healthy_repos,
    COUNT(CASE WHEN health_status = 'At Risk' THEN 1 END) as at_risk_repos,
    COUNT(CASE WHEN health_status = 'Toxic' THEN 1 END) as toxic_repos
FROM v_executive_integrated_health;

-- ============================================================================
-- LABEL-LEVEL SUMMARY (Helps identify problem categories)
-- ============================================================================

CREATE OR REPLACE VIEW v_health_by_label_category AS
SELECT
    l.standardized_category,
    COUNT(f.ticket_key) as total_tickets,
    COUNT(DISTINCT r.repo_name) as repos_affected,
    ROUND(
        SUM(CASE WHEN EXTRACT(EPOCH FROM (f.first_response_at - f.created_at)) / 3600 <= 24 THEN 1 ELSE 0 END) * 100.0 
        / NULLIF(COUNT(f.ticket_key), 0),
        2
    ) as sla_achievement_pct,
    ROUND(AVG(EXTRACT(EPOCH FROM (f.closed_at - f.created_at)) / 3600), 2) as avg_resolution_hrs,
    ROUND(AVG(CAST(f.comment_count AS FLOAT8)), 2) as avg_comment_count,
    SUM(CASE WHEN f.closed_at IS NULL THEN 1 ELSE 0 END) as open_tickets
FROM fact_tickets f
JOIN dim_labels l ON f.label_key = l.label_key
JOIN dim_repositories r ON f.repo_key = r.repo_key
WHERE f.created_at >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY l.standardized_category
ORDER BY total_tickets DESC;

-- ============================================================================
-- TIME-SERIES VIEW (For trend analysis in Tableau)
-- ============================================================================

CREATE OR REPLACE VIEW v_health_trends_daily AS
SELECT
    CAST(f.created_at AS DATE) as date,
    r.repo_name,
    COUNT(f.ticket_key) as tickets_created,
    SUM(CASE WHEN EXTRACT(EPOCH FROM (f.first_response_at - f.created_at)) / 3600 <= 24 THEN 1 ELSE 0 END) as sla_met_count,
    SUM(CASE WHEN f.closed_at IS NOT NULL THEN 1 ELSE 0 END) as tickets_closed,
    ROUND(AVG(CAST(f.comment_count AS FLOAT8)), 2) as avg_comments
FROM fact_tickets f
JOIN dim_repositories r ON f.repo_key = r.repo_key
WHERE f.created_at >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY CAST(f.created_at AS DATE), r.repo_name
ORDER BY date DESC, r.repo_name;

-- ============================================================================
-- QUERY EXAMPLES FOR TABLEAU CONNECTION
-- ============================================================================

/*
-- Example 1: Get current executive summary
SELECT * FROM v_executive_integrated_health
ORDER BY weighted_health_score DESC;

-- Example 2: KPI Overview
SELECT * FROM v_executive_kpi_summary;

-- Example 3: Drill-down by label category
SELECT * FROM v_health_by_label_category
WHERE total_tickets > 10
ORDER BY sla_achievement_pct ASC;

-- Example 4: Identify high-risk repositories
SELECT
    repo_name,
    health_status,
    weighted_health_score,
    sla_achievement_pct,
    open_tickets_current,
    critical_risk_tickets,
    high_risk_tickets,
    frustrated_user_count
FROM v_executive_integrated_health
WHERE health_status IN ('At Risk', 'Toxic')
   OR critical_risk_tickets > 5
ORDER BY weighted_health_score ASC;

-- Example 5: Trend analysis (last 30 days)
SELECT
    date,
    SUM(tickets_created) as daily_tickets_created,
    SUM(sla_met_count) as daily_sla_met,
    SUM(tickets_closed) as daily_tickets_closed,
    ROUND(AVG(avg_comments), 2) as portfolio_avg_comments
FROM v_health_trends_daily
WHERE date >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY date
ORDER BY date DESC;
*/
