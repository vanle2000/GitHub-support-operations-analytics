-- ============================================================================
-- Purpose: Dashboard-optimized health metrics with categorization for Tableau
-- ============================================================================

CREATE OR REPLACE VIEW v_repo_health_metrics_tableau AS 
WITH repo_stats AS ( 
    SELECT  
        r.repo_name, 
        -- 1. Retention Rate: % of authors who have >1 ticket in this repo 
        CAST(SUM(CASE WHEN a.author_tier != 'Newbie' THEN 1 ELSE 0 END) AS FLOAT8) / COUNT(*) as retention_rate, 
         
        -- 2. SLA Success Rate: % of tickets responded to within 24 hours 
        CAST(SUM(CASE WHEN EXTRACT(EPOCH FROM (f.first_response_at - f.created_at)) / 3600 <= 24 THEN 1 ELSE 0 END) AS FLOAT8) / COUNT(*) as sla_met_rate, 
         
        -- 3. Average Resolution Speed (Normalized: Lower is better, so we use it as a penalty) 
        AVG(EXTRACT(EPOCH FROM (f.closed_at - f.created_at)) / 3600) as avg_resolution_hrs, 
         
        COUNT(*) as ticket_volume 
    FROM fact_tickets f 
    JOIN dim_repositories r ON f.repo_key = r.repo_key 
    JOIN dim_authors a ON f.author_key = a.author_key 
    GROUP BY r.repo_name 
) 
SELECT  
    repo_name, 
    ticket_volume, 
    ROUND(retention_rate * 100, 2) as retention_rate_pct,
    ROUND(sla_met_rate * 100, 2) as sla_met_rate_pct,
    ROUND(avg_resolution_hrs, 2) as avg_resolution_hrs,
    -- The Health Score Logic (0 to 100 Scale) 
    -- Formula: (Retention * 50) + (SLA * 30) - (Resolution Time Penalty) 
    ROUND((retention_rate * 50) + (sla_met_rate * 30) - (CASE WHEN avg_resolution_hrs > 100 THEN 20 ELSE avg_resolution_hrs * 0.1 END), 2) as health_score, 
     
    -- Categorization for Tableau Slicers 
    CASE  
        WHEN (retention_rate * 50) + (sla_met_rate * 30) - (avg_resolution_hrs * 0.1) < 40 THEN 'Toxic / At Risk' 
        WHEN (retention_rate * 50) + (sla_met_rate * 30) - (avg_resolution_hrs * 0.1) BETWEEN 40 AND 75 THEN 'Stable' 
        ELSE 'Healthy / Elite' 
    END as health_status 
FROM repo_stats;

-- ============================================================================
-- USAGE EXAMPLES FOR TABLEAU DATASOURCE
-- ============================================================================

/*
-- Example 1: Get all repositories ranked by health score
SELECT * 
FROM v_repo_health_metrics_tableau 
ORDER BY health_score DESC;

-- Example 2: Find "Toxic" repositories with high ticket volume
SELECT * 
FROM v_repo_health_metrics_tableau 
WHERE health_status = 'Toxic / At Risk' 
  AND ticket_volume > 50 
ORDER BY health_score ASC;

-- Example 3: Summary by health status (for executive dashboard)
SELECT 
    health_status,
    COUNT(*) as repo_count,
    ROUND(AVG(health_score), 2) as avg_health_score,
    SUM(ticket_volume) as total_tickets,
    ROUND(AVG(retention_rate_pct), 2) as avg_retention_pct,
    ROUND(AVG(sla_met_rate_pct), 2) as avg_sla_met_pct
FROM v_repo_health_metrics_tableau 
GROUP BY health_status 
ORDER BY avg_health_score DESC;

-- Example 4: Elite repositories (candidates for case studies)
SELECT * 
FROM v_repo_health_metrics_tableau 
WHERE health_status = 'Healthy / Elite' 
ORDER BY health_score DESC;

-- Example 5: Stable repositories (maintenance focus)
SELECT * 
FROM v_repo_health_metrics_tableau 
WHERE health_status = 'Stable' 
  AND ticket_volume > 100 
ORDER BY health_score ASC;
*/
