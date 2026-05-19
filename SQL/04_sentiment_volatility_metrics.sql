-- ============================================================================
-- Sentiment Volatility Analysis - SQL Integration
-- GitHub Support Operations Analytics
-- Purpose: Store sentiment metrics and integrate with Star Schema
-- Source: Python NLP Pipeline (02_sentiment_volatility_nlp.ipynb)
-- ============================================================================

-- ============================================================================
-- TABLE: Fact_Sentiment (Populated by Python NLP Pipeline)
-- ============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID('Fact_Sentiment'))
BEGIN
    CREATE TABLE Fact_Sentiment (
        Sentiment_Key BIGINT PRIMARY KEY IDENTITY(1,1),
        Ticket_Key BIGINT NOT NULL,
        Initial_Sentiment NUMERIC(3,2),
        Final_Sentiment NUMERIC(3,2),
        Sentiment_Shift NUMERIC(4,3),
        is_frustrated_user BIT DEFAULT 0,
        created_at DATETIME DEFAULT GETDATE(),
        FOREIGN KEY (Ticket_Key) REFERENCES Fact_Tickets(Ticket_Key)
    );
END

GO

CREATE INDEX IF NOT EXISTS idx_ticket_sentiment ON Fact_Sentiment(Ticket_Key);
CREATE INDEX idx_frustrated_users ON Fact_Sentiment(is_frustrated_user);

-- ============================================================================
-- VIEW: Sentiment Volatility by Repository
-- ============================================================================

CREATE VIEW View_Sentiment_Volatility_By_Repo AS
WITH sentiment_stats AS (
    SELECT
        r.Repo_Name,
        COUNT(*) as total_tickets,
        COUNT(CASE WHEN s.is_frustrated_user = 1 THEN 1 END) as frustrated_user_count,
        ROUND(
            CAST(COUNT(CASE WHEN s.is_frustrated_user = 1 THEN 1 END) AS FLOAT) 
            / NULLIF(COUNT(*), 0) * 100,
            2
        ) as frustrated_user_pct,
        ROUND(AVG(s.Initial_Sentiment), 3) as avg_initial_sentiment,
        ROUND(AVG(s.Final_Sentiment), 3) as avg_final_sentiment,
        ROUND(AVG(s.Sentiment_Shift), 3) as avg_sentiment_shift,
        ROUND(STDEV(s.Sentiment_Shift), 3) as sentiment_shift_stdev,
        COUNT(CASE WHEN s.Sentiment_Shift > 0.1 THEN 1 END) as positive_shift_count,
        COUNT(CASE WHEN s.Sentiment_Shift < -0.1 THEN 1 END) as negative_shift_count,
        COUNT(CASE WHEN s.Sentiment_Shift BETWEEN -0.1 AND 0.1 THEN 1 END) as stable_count
    FROM Fact_Sentiment s
    JOIN Fact_Tickets f ON s.Ticket_Key = f.Ticket_Key
    JOIN Dim_Repositories r ON f.Repo_Key = r.Repo_Key
    GROUP BY r.Repo_Name
)
SELECT
    Repo_Name,
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

CREATE VIEW View_Frustrated_Users AS
SELECT
    f.Ticket_Key,
    r.Repo_Name,
    a.Author_Name,
    f.Created_At,
    f.Closed_At,
    s.Initial_Sentiment,
    s.Final_Sentiment,
    s.Sentiment_Shift,
    DATEDIFF(HOUR, f.Created_At, f.First_Response_At) as response_time_hrs,
    DATEDIFF(HOUR, f.Created_At, f.Closed_At) as resolution_time_hrs,
    f.Comment_Count,
    CASE
        WHEN s.Sentiment_Shift <= -0.5 THEN 'Very Frustrated'
        WHEN s.Sentiment_Shift BETWEEN -0.5 AND -0.2 THEN 'Frustrated'
        WHEN s.Sentiment_Shift BETWEEN -0.2 AND 0 THEN 'Slightly Disappointed'
        ELSE 'Neutral to Positive'
    END as frustration_level
FROM Fact_Sentiment s
JOIN Fact_Tickets f ON s.Ticket_Key = f.Ticket_Key
JOIN Dim_Repositories r ON f.Repo_Key = r.Repo_Key
JOIN Dim_Authors a ON f.Author_Key = a.Author_Key
WHERE s.is_frustrated_user = 1
ORDER BY s.Sentiment_Shift ASC;

-- ============================================================================
-- VIEW: Sentiment vs SLA Correlation
-- ============================================================================
-- Hypothesis: Poor SLA performance → Higher sentiment volatility

CREATE VIEW View_Sentiment_SLA_Correlation AS
SELECT
    r.Repo_Name,
    CASE
        WHEN DATEDIFF(HOUR, f.Created_At, f.First_Response_At) <= 12 THEN 'Golden Hour (0-12h)'
        WHEN DATEDIFF(HOUR, f.Created_At, f.First_Response_At) <= 24 THEN 'SLA Met (12-24h)'
        ELSE 'SLA Missed (>24h)'
    END as response_tier,
    COUNT(*) as ticket_count,
    ROUND(AVG(s.Initial_Sentiment), 3) as avg_initial_sentiment,
    ROUND(AVG(s.Final_Sentiment), 3) as avg_final_sentiment,
    ROUND(AVG(s.Sentiment_Shift), 3) as avg_sentiment_shift,
    COUNT(CASE WHEN s.is_frustrated_user = 1 THEN 1 END) as frustrated_user_count,
    ROUND(
        CAST(COUNT(CASE WHEN s.is_frustrated_user = 1 THEN 1 END) AS FLOAT) 
        / NULLIF(COUNT(*), 0) * 100,
        2
    ) as frustrated_user_pct
FROM Fact_Sentiment s
JOIN Fact_Tickets f ON s.Ticket_Key = f.Ticket_Key
JOIN Dim_Repositories r ON f.Repo_Key = r.Repo_Key
WHERE f.First_Response_At IS NOT NULL
GROUP BY r.Repo_Name, 
    CASE
        WHEN DATEDIFF(HOUR, f.Created_At, f.First_Response_At) <= 12 THEN 'Golden Hour (0-12h)'
        WHEN DATEDIFF(HOUR, f.Created_At, f.First_Response_At) <= 24 THEN 'SLA Met (12-24h)'
        ELSE 'SLA Missed (>24h)'
    END
ORDER BY r.Repo_Name, frustrated_user_pct DESC;

-- ============================================================================
-- QUERY EXAMPLES FOR POWER BI DASHBOARDS
-- ============================================================================

/*
-- Example 1: Find repositories with highest frustration metrics
SELECT TOP 10 *
FROM View_Sentiment_Volatility_By_Repo
WHERE frustrated_user_pct > 20
ORDER BY frustrated_user_pct DESC;

-- Example 2: Most frustrated users (case studies)
SELECT TOP 20 *
FROM View_Frustrated_Users
WHERE frustration_level = 'Very Frustrated'
ORDER BY Sentiment_Shift ASC;

-- Example 3: SLA Impact on Sentiment (Does faster response reduce frustration?)
SELECT *
FROM View_Sentiment_SLA_Correlation
ORDER BY response_tier, frustrated_user_pct DESC;

-- Example 4: Support Problem vs Product Problem Detection
-- Support Problem: User started happy but ended frustrated
SELECT
    f.Ticket_Key,
    r.Repo_Name,
    s.Initial_Sentiment,
    s.Final_Sentiment,
    'SUPPORT PROBLEM (Bad Communication)' as problem_type,
    DATEDIFF(HOUR, f.Created_At, f.First_Response_At) as ttfr_hrs
FROM Fact_Sentiment s
JOIN Fact_Tickets f ON s.Ticket_Key = f.Ticket_Key
JOIN Dim_Repositories r ON f.Repo_Key = r.Repo_Key
WHERE s.Initial_Sentiment > 0.2
  AND s.Final_Sentiment < -0.2
ORDER BY s.Sentiment_Shift ASC;
*/
