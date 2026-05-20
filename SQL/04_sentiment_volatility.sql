CREATE TABLE IF NOT EXISTS fact_sentiment (
    sentiment_key BIGSERIAL PRIMARY KEY,
    ticket_key BIGINT NOT NULL,
    initial_sentiment NUMERIC(3,2),
    final_sentiment NUMERIC(3,2),
    sentiment_shift NUMERIC(4,3),
    is_frustrated_user SMALLINT DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (ticket_key) REFERENCES fact_tickets(ticket_key)
);

CREATE INDEX IF NOT EXISTS idx_ticket_sentiment ON fact_sentiment(ticket_key);
CREATE INDEX IF NOT EXISTS idx_frustrated_users ON fact_sentiment(is_frustrated_user);

-- ============================================================================
-- VIEW: Sentiment Volatility by Repository
-- ============================================================================

CREATE OR REPLACE VIEW v_sentiment_volatility_by_repo AS
WITH sentiment_stats AS (
    SELECT
        r.repo_name,
        COUNT(*) as total_tickets,
        COUNT(CASE WHEN s.is_frustrated_user = 1 THEN 1 END) as frustrated_user_count,
        ROUND(
            CAST(COUNT(CASE WHEN s.is_frustrated_user = 1 THEN 1 END) AS FLOAT8) 
            / NULLIF(COUNT(*), 0) * 100,
            2
        ) as frustrated_user_pct,
        ROUND(AVG(s.initial_sentiment), 3) as avg_initial_sentiment,
        ROUND(AVG(s.final_sentiment), 3) as avg_final_sentiment,
        ROUND(AVG(s.sentiment_shift), 3) as avg_sentiment_shift,
        ROUND(STDDEV(s.sentiment_shift), 3) as sentiment_shift_stdev,
        COUNT(CASE WHEN s.sentiment_shift > 0.1 THEN 1 END) as positive_shift_count,
        COUNT(CASE WHEN s.sentiment_shift < -0.1 THEN 1 END) as negative_shift_count,
        COUNT(CASE WHEN s.sentiment_shift BETWEEN -0.1 AND 0.1 THEN 1 END) as stable_count
    FROM fact_sentiment s
    JOIN fact_tickets f ON s.ticket_key = f.ticket_key
    JOIN dim_repositories r ON f.repo_key = r.repo_key
    GROUP BY r.repo_name
)
SELECT
    repo_name,
    total_tickets,
    frustrated_user_count,
    frustrated_user_pct,
    avg_initial_sentiment,
    avg_final_sentiment,
    avg_sentiment_shift,
    sentiment_shift_stdev,
    positive_shift_count,
    negative_shift_count,
    stable_count,
    CASE
        WHEN avg_sentiment_shift < -0.1 THEN 'High Frustration Risk'
        WHEN avg_sentiment_shift BETWEEN -0.1 AND 0.05 THEN 'Moderate Volatility'
        WHEN avg_sentiment_shift > 0.05 THEN 'Positive Trajectory'
        ELSE 'Stable'
    END as sentiment_health_status
FROM sentiment_stats
ORDER BY avg_sentiment_shift ASC;

-- ============================================================================
-- VIEW: Frustrated User Analysis
-- ============================================================================
-- Discovery: Users who start neutral/positive but end negative (Support Problem)

CREATE OR REPLACE VIEW v_frustrated_users AS
SELECT
    f.ticket_key,
    r.repo_name,
    a.author_name,
    f.created_at,
    f.closed_at,
    s.initial_sentiment,
    s.final_sentiment,
    s.sentiment_shift,
    EXTRACT(EPOCH FROM (f.first_response_at - f.created_at)) / 3600 as response_time_hrs,
    EXTRACT(EPOCH FROM (f.closed_at - f.created_at)) / 3600 as resolution_time_hrs,
    f.comment_count,
    CASE
        WHEN s.sentiment_shift <= -0.5 THEN 'Very Frustrated'
        WHEN s.sentiment_shift BETWEEN -0.5 AND -0.2 THEN 'Frustrated'
        WHEN s.sentiment_shift BETWEEN -0.2 AND 0 THEN 'Slightly Disappointed'
        ELSE 'Neutral to Positive'
    END as frustration_level
FROM fact_sentiment s
JOIN fact_tickets f ON s.ticket_key = f.ticket_key
JOIN dim_repositories r ON f.repo_key = r.repo_key
JOIN dim_authors a ON f.author_key = a.author_key
WHERE s.is_frustrated_user = 1
ORDER BY s.sentiment_shift ASC;

-- ============================================================================
-- VIEW: Sentiment vs SLA Correlation
-- ============================================================================
-- Hypothesis: Poor SLA performance → Higher sentiment volatility

CREATE OR REPLACE VIEW v_sentiment_sla_correlation AS
SELECT
    r.repo_name,
    CASE
        WHEN EXTRACT(EPOCH FROM (f.first_response_at - f.created_at)) / 3600 <= 12 THEN 'Golden Hour (0-12h)'
        WHEN EXTRACT(EPOCH FROM (f.first_response_at - f.created_at)) / 3600 <= 24 THEN 'SLA Met (12-24h)'
        ELSE 'SLA Missed (>24h)'
    END as response_tier,
    COUNT(*) as ticket_count,
    ROUND(AVG(s.initial_sentiment), 3) as avg_initial_sentiment,
    ROUND(AVG(s.final_sentiment), 3) as avg_final_sentiment,
    ROUND(AVG(s.sentiment_shift), 3) as avg_sentiment_shift,
    COUNT(CASE WHEN s.is_frustrated_user = 1 THEN 1 END) as frustrated_user_count,
    ROUND(
        CAST(COUNT(CASE WHEN s.is_frustrated_user = 1 THEN 1 END) AS FLOAT8) 
        / NULLIF(COUNT(*), 0) * 100,
        2
    ) as frustrated_user_pct
FROM fact_sentiment s
JOIN fact_tickets f ON s.ticket_key = f.ticket_key
JOIN dim_repositories r ON f.repo_key = r.repo_key
WHERE f.first_response_at IS NOT NULL
GROUP BY r.repo_name, 
    CASE
        WHEN EXTRACT(EPOCH FROM (f.first_response_at - f.created_at)) / 3600 <= 12 THEN 'Golden Hour (0-12h)'
        WHEN EXTRACT(EPOCH FROM (f.first_response_at - f.created_at)) / 3600 <= 24 THEN 'SLA Met (12-24h)'
        ELSE 'SLA Missed (>24h)'
    END
ORDER BY r.repo_name, frustrated_user_pct DESC;

-- ============================================================================
-- QUERY EXAMPLES FOR TABLEAU DASHBOARDS
-- ============================================================================

/*
-- Example 1: Find repositories with highest frustration metrics
SELECT * FROM v_sentiment_volatility_by_repo
WHERE frustrated_user_pct > 20
ORDER BY frustrated_user_pct DESC;

-- Example 2: Most frustrated users (case studies)
SELECT * FROM v_frustrated_users
WHERE frustration_level = 'Very Frustrated'
ORDER BY sentiment_shift ASC
LIMIT 20;

-- Example 3: SLA Impact on Sentiment (Does faster response reduce frustration?)
SELECT * FROM v_sentiment_sla_correlation
ORDER BY response_tier, frustrated_user_pct DESC;
*/
