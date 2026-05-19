-- ============================================================================
-- Repository Health Score View - Azure Data Studio
-- GitHub Support Operations Analytics
-- Purpose: Dashboard-optimized health metrics with categorization
-- Database: Azure SQL Server / SQL Server
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
         
        COUNT(*) as Ticket_Volume 
    FROM Fact_Tickets f 
    JOIN Dim_Repositories r ON f.Repo_Key = r.Repo_Key 
    JOIN Dim_Authors a ON f.Author_Key = a.Author_Key 
    GROUP BY r.Repo_Name 
) 
SELECT  
    Repo_Name, 
    Ticket_Volume, 
    ROUND(Retention_Rate * 100, 2) as Retention_Rate_Pct,
    ROUND(SLA_Met_Rate * 100, 2) as SLA_Met_Rate_Pct,
    ROUND(Avg_Resolution_Hrs, 2) as Avg_Resolution_Hrs,
    -- The Health Score Logic (0 to 100 Scale) 
    -- Formula: (Retention * 50) + (SLA * 30) - (Resolution Time Penalty) 
    ROUND((Retention_Rate * 50) + (SLA_Met_Rate * 30) - (CASE WHEN Avg_Resolution_Hrs > 100 THEN 20 ELSE Avg_Resolution_Hrs * 0.1 END), 2) as Health_Score, 
     
    -- Categorization for Dashboard Slicers 
    CASE  
        WHEN (Retention_Rate * 50) + (SLA_Met_Rate * 30) - (Avg_Resolution_Hrs * 0.1) < 40 THEN 'Toxic / At Risk' 
        WHEN (Retention_Rate * 50) + (SLA_Met_Rate * 30) - (Avg_Resolution_Hrs * 0.1) BETWEEN 40 AND 75 THEN 'Stable' 
        ELSE 'Healthy / Elite' 
    END as Health_Status 
FROM RepoStats;

-- ============================================================================
-- USAGE EXAMPLES FOR POWER BI / DASHBOARD
-- ============================================================================

/*
-- Example 1: Get all repositories ranked by health score
SELECT TOP 20 * 
FROM View_Repo_Health_Metrics 
ORDER BY Health_Score DESC;

-- Example 2: Find "Toxic" repositories with high ticket volume
SELECT * 
FROM View_Repo_Health_Metrics 
WHERE Health_Status = 'Toxic / At Risk' 
  AND Ticket_Volume > 50 
ORDER BY Health_Score ASC;

-- Example 3: Summary by health status (for executive dashboard)
SELECT 
    Health_Status,
    COUNT(*) as Repo_Count,
    AVG(Health_Score) as Avg_Health_Score,
    SUM(Ticket_Volume) as Total_Tickets,
    ROUND(AVG(Retention_Rate_Pct), 2) as Avg_Retention_Pct,
    ROUND(AVG(SLA_Met_Rate_Pct), 2) as Avg_SLA_Met_Pct,
    ROUND(AVG(Avg_Resolution_Hrs), 2) as Avg_Resolution_Hrs
FROM View_Repo_Health_Metrics 
GROUP BY Health_Status 
ORDER BY Avg_Health_Score DESC;

-- Example 4: Elite repositories (candidates for case studies)
SELECT * 
FROM View_Repo_Health_Metrics 
WHERE Health_Status = 'Healthy / Elite' 
ORDER BY Health_Score DESC;

-- Example 5: Stable repositories (maintenance focus)
SELECT * 
FROM View_Repo_Health_Metrics 
WHERE Health_Status = 'Stable' 
  AND Ticket_Volume > 100 
ORDER BY Health_Score ASC;
*/
