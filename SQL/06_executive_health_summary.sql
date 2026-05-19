-- ============================================================================
-- Executive Health Summary Views
-- GitHub Support Operations Analytics
-- Purpose: Data Modeling at Scale - Aggregated metrics for Power BI
-- Source: Star Schema aggregation across all fact & dimension tables
-- ============================================================================

-- ============================================================================
-- PRIMARY EXECUTIVE VIEW: Comprehensive Repository Summary
-- ============================================================================

CREATE VIEW View_Executive_Health_Summary AS
SELECT  
    r.Repo_Name,
    l.Standardized_Category,
    COUNT(f.Ticket_Key) as Total_Tickets,
    COUNT(DISTINCT f.Author_Key) as Unique_Contributors,
    
    -- Retention & Community Health
    SUM(CASE WHEN a.Author_Tier = 'Maintainer' THEN 1 ELSE 0 END) as Power_User_Interactions,
    SUM(CASE WHEN a.Author_Tier = 'Newbie' THEN 1 ELSE 0 END) as Newbie_Interactions,
    ROUND(
        CAST(SUM(CASE WHEN a.Author_Tier = 'Maintainer' THEN 1 ELSE 0 END) AS FLOAT) 
        / NULLIF(COUNT(f.Ticket_Key), 0) * 100,
        2
    ) as Power_User_Percentage,
    
    -- Resolution Velocity
    ROUND(AVG(CAST(DATEDIFF(HOUR, f.Created_At, f.Closed_At) AS FLOAT)), 2) as Avg_Resolution_Time_Hrs,
    ROUND(AVG(CAST(DATEDIFF(DAY, f.Created_At, f.Closed_At) AS FLOAT)), 2) as Avg_Resolution_Time_Days,
    
    -- SLA Achievement (24-hour response threshold)
    ROUND(
        SUM(CASE WHEN DATEDIFF(HOUR, f.Created_At, f.First_Response_At) <= 24 THEN 1 ELSE 0 END) * 100.0 
        / NULLIF(COUNT(f.Ticket_Key), 0),
        2
    ) as SLA_Achievement_Rate_Pct,
    
    -- Golden Hour Impact (12-hour response threshold)
    ROUND(
        SUM(CASE WHEN DATEDIFF(HOUR, f.Created_At, f.First_Response_At) <= 12 THEN 1 ELSE 0 END) * 100.0 
        / NULLIF(COUNT(f.Ticket_Key), 0),
        2
    ) as Golden_Hour_Achievement_Pct,
    
    -- Ticket Status Distribution
    SUM(CASE WHEN f.Closed_At IS NOT NULL THEN 1 ELSE 0 END) as Closed_Tickets,
    SUM(CASE WHEN f.Closed_At IS NULL THEN 1 ELSE 0 END) as Open_Tickets,
    
    -- Comment Activity
    ROUND(AVG(CAST(f.Comment_Count AS FLOAT)), 2) as Avg_Comment_Count,
    
    GETDATE() as Last_Calculated
FROM Fact_Tickets f
JOIN Dim_Repositories r ON f.Repo_Key = r.Repo_Key
JOIN Dim_Labels l ON f.Label_Key = l.Label_Key
JOIN Dim_Authors a ON f.Author_Key = a.Author_Key
WHERE f.Created_At >= DATEADD(DAY, -90, CAST(GETDATE() AS DATE))
GROUP BY r.Repo_Name, l.Standardized_Category
ORDER BY Total_Tickets DESC;

-- ============================================================================
-- ENHANCED EXECUTIVE VIEW: Integrated with Health Scores & Risk Metrics
-- ============================================================================

CREATE VIEW View_Executive_Integrated_Health AS
WITH base_summary AS (
    SELECT  
        r.Repo_Name,
        COUNT(f.Ticket_Key) as Total_Tickets_90d,
        COUNT(DISTINCT f.Author_Key) as Unique_Contributors,
        ROUND(AVG(CAST(DATEDIFF(HOUR, f.Created_At, f.Closed_At) AS FLOAT)), 2) as Avg_Resolution_Hrs,
        ROUND(
            SUM(CASE WHEN DATEDIFF(HOUR, f.Created_At, f.First_Response_At) <= 24 THEN 1 ELSE 0 END) * 100.0 
            / NULLIF(COUNT(f.Ticket_Key), 0),
            2
        ) as SLA_Achievement_Pct,
        ROUND(
            SUM(CASE WHEN a.Author_Tier != 'Newbie' THEN 1 ELSE 0 END) * 100.0 
            / NULLIF(COUNT(f.Ticket_Key), 0),
            2
        ) as Retention_Rate_Pct,
        ROUND(AVG(CAST(f.Comment_Count AS FLOAT)), 2) as Avg_Comment_Count,
        SUM(CASE WHEN f.Closed_At IS NULL THEN 1 ELSE 0 END) as Open_Tickets_Current
    FROM Fact_Tickets f
    JOIN Dim_Repositories r ON f.Repo_Key = r.Repo_Key
    JOIN Dim_Authors a ON f.Author_Key = a.Author_Key
    WHERE f.Created_At >= DATEADD(DAY, -90, CAST(GETDATE() AS DATE))
    GROUP BY r.Repo_Name
),
sentiment_summary AS (
    SELECT
        r.Repo_Name,
        ROUND(AVG(s.Initial_Sentiment), 3) as Avg_Initial_Sentiment,
        ROUND(AVG(s.Final_Sentiment), 3) as Avg_Final_Sentiment,
        ROUND(AVG(s.Sentiment_Shift), 3) as Avg_Sentiment_Shift,
        SUM(CASE WHEN s.is_frustrated_user = 1 THEN 1 ELSE 0 END) as Frustrated_User_Count
    FROM Fact_Sentiment s
    JOIN Fact_Tickets f ON s.Ticket_Key = f.Ticket_Key
    JOIN Dim_Repositories r ON f.Repo_Key = r.Repo_Key
    WHERE f.Created_At >= DATEADD(DAY, -90, CAST(GETDATE() AS DATE))
    GROUP BY r.Repo_Name
),
risk_summary AS (
    SELECT
        rs.Repo_Name,
        ROUND(AVG(rs.SLA_Breach_Probability), 2) as Avg_Breach_Probability,
        SUM(CASE WHEN rs.Risk_Tier = 'CRITICAL - Immediate Action' THEN 1 ELSE 0 END) as Critical_Risk_Count,
        SUM(CASE WHEN rs.Risk_Tier = 'HIGH - Monitor Closely' THEN 1 ELSE 0 END) as High_Risk_Count,
        SUM(CASE WHEN rs.Risk_Tier LIKE 'CRITICAL%' OR rs.Risk_Tier LIKE 'HIGH%' THEN 1 ELSE 0 END) as At_Risk_Ticket_Count
    FROM Risk_Scores rs
    WHERE rs.Calculated_At = (SELECT MAX(Calculated_At) FROM Risk_Scores)
    GROUP BY rs.Repo_Name
)
SELECT
    b.Repo_Name,
    b.Total_Tickets_90d,
    b.Unique_Contributors,
    b.Open_Tickets_Current,
    b.Avg_Resolution_Hrs,
    b.SLA_Achievement_Pct,
    b.Retention_Rate_Pct,
    b.Avg_Comment_Count,
    -- Health Score (calculated formula)
    ROUND(
        (b.Retention_Rate_Pct * 0.5) + 
        (b.SLA_Achievement_Pct * 0.3) - 
        (CASE WHEN b.Avg_Resolution_Hrs > 720 THEN 30 ELSE (b.Avg_Resolution_Hrs / 720 * 30) END * 0.2),
        2
    ) as Weighted_Health_Score,
    -- Sentiment Metrics
    COALESCE(s.Avg_Initial_Sentiment, 0) as Avg_Initial_Sentiment,
    COALESCE(s.Avg_Final_Sentiment, 0) as Avg_Final_Sentiment,
    COALESCE(s.Avg_Sentiment_Shift, 0) as Avg_Sentiment_Shift,
    COALESCE(s.Frustrated_User_Count, 0) as Frustrated_User_Count,
    -- Risk Metrics
    COALESCE(r.Avg_Breach_Probability, 0) as Avg_SLA_Breach_Probability,
    COALESCE(r.Critical_Risk_Count, 0) as Critical_Risk_Tickets,
    COALESCE(r.High_Risk_Count, 0) as High_Risk_Tickets,
    COALESCE(r.At_Risk_Ticket_Count, 0) as Total_At_Risk_Tickets,
    -- Classification
    CASE
        WHEN ROUND((b.Retention_Rate_Pct * 0.5) + (b.SLA_Achievement_Pct * 0.3) - (CASE WHEN b.Avg_Resolution_Hrs > 720 THEN 30 ELSE (b.Avg_Resolution_Hrs / 720 * 30) END * 0.2), 2) >= 75 THEN 'Healthy'
        WHEN ROUND((b.Retention_Rate_Pct * 0.5) + (b.SLA_Achievement_Pct * 0.3) - (CASE WHEN b.Avg_Resolution_Hrs > 720 THEN 30 ELSE (b.Avg_Resolution_Hrs / 720 * 30) END * 0.2), 2) >= 50 THEN 'At Risk'
        ELSE 'Toxic'
    END as Health_Status,
    GETDATE() as Last_Calculated
FROM base_summary b
LEFT JOIN sentiment_summary s ON b.Repo_Name = s.Repo_Name
LEFT JOIN risk_summary r ON b.Repo_Name = r.Repo_Name
ORDER BY Weighted_Health_Score DESC;

-- ============================================================================
-- EXECUTIVE DASHBOARD VIEW: KPI Summary
-- ============================================================================

CREATE VIEW View_Executive_KPI_Summary AS
SELECT
    'Overall Portfolio' as Metric_Category,
    COUNT(*) as Repo_Count,
    SUM(Total_Tickets_90d) as Total_Tickets_90d,
    SUM(Unique_Contributors) as Total_Contributors,
    SUM(Open_Tickets_Current) as Total_Open_Tickets,
    ROUND(AVG(SLA_Achievement_Pct), 2) as Portfolio_Avg_SLA_Pct,
    ROUND(AVG(Retention_Rate_Pct), 2) as Portfolio_Avg_Retention_Pct,
    ROUND(AVG(Weighted_Health_Score), 2) as Portfolio_Avg_Health_Score,
    COUNT(CASE WHEN Health_Status = 'Healthy' THEN 1 END) as Healthy_Repos,
    COUNT(CASE WHEN Health_Status = 'At Risk' THEN 1 END) as At_Risk_Repos,
    COUNT(CASE WHEN Health_Status = 'Toxic' THEN 1 END) as Toxic_Repos
FROM View_Executive_Integrated_Health;

-- ============================================================================
-- LABEL-LEVEL SUMMARY (Helps identify problem categories)
-- ============================================================================

CREATE VIEW View_Health_By_Label_Category AS
SELECT
    l.Standardized_Category,
    COUNT(f.Ticket_Key) as Total_Tickets,
    COUNT(DISTINCT r.Repo_Name) as Repos_Affected,
    ROUND(
        SUM(CASE WHEN DATEDIFF(HOUR, f.Created_At, f.First_Response_At) <= 24 THEN 1 ELSE 0 END) * 100.0 
        / NULLIF(COUNT(f.Ticket_Key), 0),
        2
    ) as SLA_Achievement_Pct,
    ROUND(AVG(CAST(DATEDIFF(HOUR, f.Created_At, f.Closed_At) AS FLOAT)), 2) as Avg_Resolution_Hrs,
    ROUND(AVG(CAST(f.Comment_Count AS FLOAT)), 2) as Avg_Comment_Count,
    SUM(CASE WHEN f.Closed_At IS NULL THEN 1 ELSE 0 END) as Open_Tickets
FROM Fact_Tickets f
JOIN Dim_Labels l ON f.Label_Key = l.Label_Key
JOIN Dim_Repositories r ON f.Repo_Key = r.Repo_Key
WHERE f.Created_At >= DATEADD(DAY, -90, CAST(GETDATE() AS DATE))
GROUP BY l.Standardized_Category
ORDER BY Total_Tickets DESC;

-- ============================================================================
-- TIME-SERIES VIEW (For trend analysis in Power BI)
-- ============================================================================

CREATE VIEW View_Health_Trends_Daily AS
SELECT
    CAST(f.Created_At AS DATE) as Date,
    r.Repo_Name,
    COUNT(f.Ticket_Key) as Tickets_Created,
    SUM(CASE WHEN DATEDIFF(HOUR, f.Created_At, f.First_Response_At) <= 24 THEN 1 ELSE 0 END) as SLA_Met_Count,
    SUM(CASE WHEN f.Closed_At IS NOT NULL THEN 1 ELSE 0 END) as Tickets_Closed,
    ROUND(AVG(CAST(f.Comment_Count AS FLOAT)), 2) as Avg_Comments
FROM Fact_Tickets f
JOIN Dim_Repositories r ON f.Repo_Key = r.Repo_Key
WHERE f.Created_At >= DATEADD(DAY, -90, CAST(GETDATE() AS DATE))
GROUP BY CAST(f.Created_At AS DATE), r.Repo_Name
ORDER BY Date DESC, r.Repo_Name;

-- ============================================================================
-- QUERY EXAMPLES FOR POWER BI CONNECTION
-- ============================================================================

/*
-- Example 1: Get current executive summary
SELECT *
FROM View_Executive_Integrated_Health
ORDER BY Weighted_Health_Score DESC;

-- Example 2: KPI Overview
SELECT *
FROM View_Executive_KPI_Summary;

-- Example 3: Drill-down by label category
SELECT *
FROM View_Health_By_Label_Category
WHERE Total_Tickets > 10
ORDER BY SLA_Achievement_Pct ASC;

-- Example 4: Identify high-risk repositories
SELECT
    Repo_Name,
    Health_Status,
    Weighted_Health_Score,
    SLA_Achievement_Pct,
    Open_Tickets_Current,
    Critical_Risk_Tickets,
    High_Risk_Tickets,
    Frustrated_User_Count
FROM View_Executive_Integrated_Health
WHERE Health_Status IN ('At Risk', 'Toxic')
   OR Critical_Risk_Tickets > 5
ORDER BY Weighted_Health_Score ASC;

-- Example 5: Trend analysis (last 30 days)
SELECT
    Date,
    SUM(Tickets_Created) as Daily_Tickets_Created,
    SUM(SLA_Met_Count) as Daily_SLA_Met,
    SUM(Tickets_Closed) as Daily_Tickets_Closed,
    ROUND(AVG(Avg_Comments), 2) as Portfolio_Avg_Comments
FROM View_Health_Trends_Daily
WHERE Date >= DATEADD(DAY, -30, CAST(GETDATE() AS DATE))
GROUP BY Date
ORDER BY Date DESC;
*/
