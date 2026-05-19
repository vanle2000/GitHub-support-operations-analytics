-- ============================================================================
-- Repository Health Score Metrics - Azure SQL Server Implementation
-- GitHub Support Operations Analytics
-- Purpose: T-SQL version for Azure Data Studio & SQL Server
-- Note: PostgreSQL version available in 01_repo_health_view.sql
-- ============================================================================

-- ============================================================================
-- SIMPLE FORMULA-BASED HEALTH SCORE
-- ============================================================================
-- Health Score = (Retention Rate * 0.5) + (SLA Success Rate * 0.3) - (Avg Response Time * 0.2)

SELECT  
    Repo_Name, 
    (AVG(CASE WHEN Is_Retained = 1 THEN 1.0 ELSE 0.0 END) * 50) +  -- Retention Weight
    (AVG(CASE WHEN Response_Time_Hrs <= 24 THEN 1.0 ELSE 0.0 END) * 30)  -- SLA Weight
    AS Repo_Health_Score 
FROM Fact_Tickets f 
JOIN Dim_Repositories r ON f.Repo_Key = r.Repo_Key 
GROUP BY Repo_Name 
ORDER BY Repo_Health_Score ASC;  -- Lowest scores are "Toxic"

GO

-- ============================================================================
-- COMPREHENSIVE HEALTH METRICS VIEW (Azure Data Studio)
-- ============================================================================

CREATE VIEW View_Repo_Health_Metrics AS 
WITH RepoStats AS ( 
    SELECT  
        r.Repo_Name, 
        -- 1. Retention Rate: % of authors who have >1 ticket in this repo 
        CAST(SUM(CASE WHEN a.Author_Tier != 'Newbie' THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) as Retention_Rate, 
         
        -- 2. SLA Success Rate: % of tickets responded to within 24 hours 
        CAST(SUM(CASE WHEN DATEDIFF(HOUR, f.Created_At, f.First_Response_At) <= 24 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) as SLA_Met_Rate, 
         
        -- 3. Average Resolution Speed (Normalized: Lower is better, so we use it as a penalty) 
        AVG(CAST(DATEDIFF(HOUR, f.Created_At, f.Closed_At) AS FLOAT)) as Avg_Resolution_Hrs,
        
        -- 4. High-traffic indicator
        COUNT(*) as Total_Tickets_90d,
        
        -- 5. Sentiment volatility (tickets with 3+ comments showing sentiment shift)
        CAST(SUM(CASE WHEN f.Comment_Count >= 3 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) as Sentiment_Volatility_Rate
    FROM Fact_Tickets f 
    JOIN Dim_Repositories r ON f.Repo_Key = r.Repo_Key 
    JOIN Dim_Authors a ON f.Author_Key = a.Author_Key 
    WHERE f.Created_At >= DATEADD(DAY, -90, CAST(GETDATE() AS DATE))
    GROUP BY r.Repo_Name, r.Repo_Key
)
SELECT  
    Repo_Name,
    Total_Tickets_90d,
    ROUND(Retention_Rate * 100, 2) as Retention_Rate_Pct,
    ROUND(SLA_Met_Rate * 100, 2) as SLA_Met_Rate_Pct,
    ROUND(Avg_Resolution_Hrs, 2) as Avg_Resolution_Hours,
    ROUND(Sentiment_Volatility_Rate * 100, 2) as Sentiment_Volatility_Pct,
    -- Weighted Health Score Formula
    -- Score = (Retention * 0.5) + (SLA * 0.3) - (Avg_Resolution_Normalized * 0.2)
    ROUND(
        (Retention_Rate * 0.5 * 100) + 
        (SLA_Met_Rate * 0.3 * 100) - 
        (CASE 
            WHEN Avg_Resolution_Hrs > 720 THEN 30  -- Cap penalty at 30 days (720 hrs)
            ELSE (Avg_Resolution_Hrs / 720 * 30)
         END * 0.2),
        2
    ) as Weighted_Health_Score,
    -- Health Classification
    CASE 
        WHEN ROUND(
            (Retention_Rate * 0.5 * 100) + 
            (SLA_Met_Rate * 0.3 * 100) - 
            (CASE 
                WHEN Avg_Resolution_Hrs > 720 THEN 30
                ELSE (Avg_Resolution_Hrs / 720 * 30)
             END * 0.2),
            2
        ) >= 75 THEN 'Healthy'
        WHEN ROUND(
            (Retention_Rate * 0.5 * 100) + 
            (SLA_Met_Rate * 0.3 * 100) - 
            (CASE 
                WHEN Avg_Resolution_Hrs > 720 THEN 30
                ELSE (Avg_Resolution_Hrs / 720 * 30)
             END * 0.2),
            2
        ) >= 50 THEN 'At Risk'
        ELSE 'Toxic'
    END as Health_Status
FROM RepoStats
ORDER BY Weighted_Health_Score DESC;

-- ============================================================================
-- QUERY: IDENTIFY "TOXIC" REPOSITORIES (High Traffic + Low Health)
-- ============================================================================

SELECT TOP 10
    Repo_Name,
    Total_Tickets_90d,
    Weighted_Health_Score,
    Health_Status,
    Retention_Rate_Pct,
    SLA_Met_Rate_Pct,
    Avg_Resolution_Hours
FROM View_Repo_Health_Metrics
WHERE Health_Status = 'Toxic'
  AND Total_Tickets_90d > 50  -- High-traffic filter
ORDER BY Weighted_Health_Score ASC;

-- ============================================================================
-- QUERY: GOLDEN HOUR IMPACT (12-hour response threshold analysis)
-- ============================================================================

WITH Golden_Hour_Analysis AS (
    SELECT
        r.Repo_Name,
        CASE 
            WHEN DATEDIFF(HOUR, f.Created_At, f.First_Response_At) <= 12 THEN 'Golden Hour (0-12h)'
            WHEN DATEDIFF(HOUR, f.Created_At, f.First_Response_At) <= 24 THEN 'SLA Met (12-24h)'
            ELSE 'SLA Missed (>24h)'
        END as Response_Tier,
        COUNT(*) as Ticket_Count,
        CAST(COUNT(*) AS FLOAT) / (SELECT COUNT(*) FROM Fact_Tickets WHERE Repo_Key = f.Repo_Key) as Tier_Percentage
    FROM Fact_Tickets f
    JOIN Dim_Repositories r ON f.Repo_Key = r.Repo_Key
    WHERE f.First_Response_At IS NOT NULL
      AND f.Created_At >= DATEADD(DAY, -90, CAST(GETDATE() AS DATE))
    GROUP BY r.Repo_Name, f.Repo_Key, 
        CASE 
            WHEN DATEDIFF(HOUR, f.Created_At, f.First_Response_At) <= 12 THEN 'Golden Hour (0-12h)'
            WHEN DATEDIFF(HOUR, f.Created_At, f.First_Response_At) <= 24 THEN 'SLA Met (12-24h)'
            ELSE 'SLA Missed (>24h)'
        END
)
SELECT
    Repo_Name,
    Response_Tier,
    Ticket_Count,
    ROUND(Tier_Percentage * 100, 2) as Percentage
FROM Golden_Hour_Analysis
ORDER BY Repo_Name, 
    CASE 
        WHEN Response_Tier = 'Golden Hour (0-12h)' THEN 1
        WHEN Response_Tier = 'SLA Met (12-24h)' THEN 2
        ELSE 3
    END;

-- ============================================================================
-- QUERY: SENTIMENT VOLATILITY REPORT
-- ============================================================================
-- Discovery: Tickets with 3+ comments show 40% increase in negative sentiment

SELECT TOP 15
    r.Repo_Name,
    COUNT(*) as Total_Issues_Analyzed,
    SUM(CASE WHEN f.Comment_Count >= 3 THEN 1 ELSE 0 END) as Volatile_Issues_Count,
    ROUND(
        CAST(SUM(CASE WHEN f.Comment_Count >= 3 THEN 1 ELSE 0 END) AS FLOAT) / 
        NULLIF(COUNT(*), 0) * 100,
        2
    ) as Sentiment_Volatility_Pct,
    ROUND(AVG(ABS(f.Final_Sentiment - f.Initial_Sentiment)), 3) as Avg_Sentiment_Shift
FROM Fact_Tickets f
JOIN Dim_Repositories r ON f.Repo_Key = r.Repo_Key
WHERE f.Initial_Sentiment IS NOT NULL 
  AND f.Final_Sentiment IS NOT NULL
  AND f.Created_At >= DATEADD(DAY, -90, CAST(GETDATE() AS DATE))
GROUP BY r.Repo_Name
ORDER BY Sentiment_Volatility_Pct DESC;

-- ============================================================================
-- SCHEDULED REFRESH (if using views)
-- Note: SQL Server requires a job or scheduled task for automated refresh
-- Recommended frequency: Every 6 hours
-- ============================================================================

/*
-- Example: Create SQL Agent Job to refresh materialized view
CREATE PROCEDURE sp_RefreshHealthMetrics
AS
BEGIN
    -- Your refresh logic here
    PRINT 'Health metrics view refreshed at ' + CAST(GETDATE() AS VARCHAR);
END;

-- Usage: EXECUTE sp_RefreshHealthMetrics;
*/
