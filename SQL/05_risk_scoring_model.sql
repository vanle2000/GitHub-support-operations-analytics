-- ============================================================================
-- SLA Breach Risk Scoring Model
-- GitHub Support Operations Analytics
-- Purpose: Real-time risk alerts for open tickets approaching SLA deadline
-- Source: Python statistical model (03_risk_score_sla_prediction.ipynb)
-- ============================================================================

-- ============================================================================
-- TABLE: Risk_Scores (Populated by Python SLA Prediction Model)
-- ============================================================================

IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID('Risk_Scores'))
BEGIN
    CREATE TABLE Risk_Scores (
        Risk_Score_Key BIGINT PRIMARY KEY IDENTITY(1,1),
        Ticket_Key BIGINT NOT NULL,
        Repo_Name VARCHAR(255),
        Author_Name VARCHAR(255),
        Created_At DATETIME,
        Ticket_Age_Hours NUMERIC(8,2),
        Comment_Count INT,
        Label_Weight NUMERIC(4,2),
        Has_Response BIT,
        SLA_Breach_Probability NUMERIC(5,2),
        Risk_Tier VARCHAR(50),
        Calculated_At DATETIME DEFAULT GETDATE(),
        FOREIGN KEY (Ticket_Key) REFERENCES Fact_Tickets(Ticket_Key)
    );
END

GO

CREATE INDEX IF NOT EXISTS idx_risk_breach_prob ON Risk_Scores(SLA_Breach_Probability);
CREATE INDEX idx_risk_tier ON Risk_Scores(Risk_Tier);
CREATE INDEX idx_risk_ticket ON Risk_Scores(Ticket_Key);
CREATE INDEX idx_risk_calculated ON Risk_Scores(Calculated_At);

-- ============================================================================
-- VIEW: Open Tickets Risk Dashboard
-- ============================================================================
-- Real-time view of all open tickets with risk classifications

CREATE VIEW View_Open_Tickets_Risk AS
SELECT
    rs.Ticket_Key,
    rs.Repo_Name,
    rs.Author_Name,
    rs.Created_At,
    rs.Ticket_Age_Hours,
    rs.Comment_Count,
    rs.Label_Weight,
    rs.Has_Response,
    CASE WHEN rs.Has_Response = 1 THEN 'Yes' ELSE 'No - Awaiting Response' END as has_first_response,
    rs.SLA_Breach_Probability,
    rs.Risk_Tier,
    24 - rs.Ticket_Age_Hours as hours_until_sla_deadline,
    CASE
        WHEN 24 - rs.Ticket_Age_Hours <= 0 THEN 'OVERDUE'
        WHEN 24 - rs.Ticket_Age_Hours <= 2 THEN 'Less than 2 hours'
        WHEN 24 - rs.Ticket_Age_Hours <= 6 THEN 'Less than 6 hours'
        ELSE CAST(CAST(24 - rs.Ticket_Age_Hours AS INT) AS VARCHAR) + ' hours'
    END as time_remaining
FROM Risk_Scores rs
WHERE Calculated_At = (SELECT MAX(Calculated_At) FROM Risk_Scores)
ORDER BY rs.SLA_Breach_Probability DESC;

-- ============================================================================
-- VIEW: Critical Risk Tickets (Escalation Alert)
-- ============================================================================
-- Only tickets with >80% breach probability or overdue

CREATE VIEW View_Critical_Risk_Tickets AS
SELECT
    Ticket_Key,
    Repo_Name,
    Author_Name,
    Created_At,
    Ticket_Age_Hours,
    Comment_Count,
    SLA_Breach_Probability,
    hours_until_sla_deadline,
    CASE
        WHEN hours_until_sla_deadline < 0 THEN '🔴 OVERDUE - IMMEDIATE ESCALATION'
        WHEN SLA_Breach_Probability >= 90 THEN '🔴 CRITICAL (90%+ breach risk)'
        WHEN SLA_Breach_Probability >= 80 THEN '🟠 SEVERE (80%+ breach risk)'
        ELSE 'Monitoring'
    END as escalation_action
FROM View_Open_Tickets_Risk
WHERE SLA_Breach_Probability >= 80
   OR hours_until_sla_deadline <= 0
ORDER BY SLA_Breach_Probability DESC, hours_until_sla_deadline ASC;

-- ============================================================================
-- VIEW: Risk by Repository (Aggregate)
-- ============================================================================

CREATE VIEW View_Risk_By_Repository AS
SELECT
    Repo_Name,
    COUNT(*) as total_open_tickets,
    COUNT(CASE WHEN Risk_Tier = 'CRITICAL - Immediate Action' THEN 1 END) as critical_count,
    COUNT(CASE WHEN Risk_Tier = 'HIGH - Monitor Closely' THEN 1 END) as high_count,
    COUNT(CASE WHEN Risk_Tier = 'MEDIUM - Track Progress' THEN 1 END) as medium_count,
    ROUND(AVG(SLA_Breach_Probability), 2) as avg_breach_probability,
    ROUND(AVG(Ticket_Age_Hours), 2) as avg_ticket_age_hours,
    ROUND(AVG(Comment_Count), 2) as avg_comment_count,
    COUNT(CASE WHEN Has_Response = 0 THEN 1 END) as tickets_awaiting_response,
    CASE
        WHEN ROUND(AVG(SLA_Breach_Probability), 2) >= 70 THEN '🔴 HIGH RISK REPO'
        WHEN ROUND(AVG(SLA_Breach_Probability), 2) >= 50 THEN '🟠 ELEVATED RISK'
        ELSE '🟢 MANAGED RISK'
    END as repo_risk_status
FROM Risk_Scores
WHERE Calculated_At = (SELECT MAX(Calculated_At) FROM Risk_Scores)
GROUP BY Repo_Name
ORDER BY avg_breach_probability DESC;

-- ============================================================================
-- VIEW: Risk Score Distribution
-- ============================================================================

CREATE VIEW View_Risk_Distribution AS
SELECT
    Risk_Tier,
    COUNT(*) as ticket_count,
    ROUND(CAST(COUNT(*) AS FLOAT) / (SELECT COUNT(*) FROM Risk_Scores WHERE Calculated_At = (SELECT MAX(Calculated_At) FROM Risk_Scores)) * 100, 2) as percentage,
    ROUND(AVG(SLA_Breach_Probability), 2) as avg_breach_probability,
    MIN(SLA_Breach_Probability) as min_probability,
    MAX(SLA_Breach_Probability) as max_probability
FROM Risk_Scores
WHERE Calculated_At = (SELECT MAX(Calculated_At) FROM Risk_Scores)
GROUP BY Risk_Tier
ORDER BY AVG(SLA_Breach_Probability) DESC;

-- ============================================================================
-- VIEW: Response Time Impact on Risk
-- ============================================================================
-- Does having a first response reduce risk?

CREATE VIEW View_Response_Time_Risk_Impact AS
SELECT
    CASE 
        WHEN Has_Response = 0 THEN 'No Response Yet'
        ELSE 'Has First Response'
    END as response_status,
    COUNT(*) as ticket_count,
    ROUND(AVG(SLA_Breach_Probability), 2) as avg_breach_probability,
    ROUND(AVG(Ticket_Age_Hours), 2) as avg_ticket_age_hrs,
    ROUND(AVG(Comment_Count), 2) as avg_comment_count,
    COUNT(CASE WHEN Risk_Tier LIKE 'CRITICAL%' THEN 1 END) as critical_count,
    COUNT(CASE WHEN Risk_Tier LIKE 'HIGH%' THEN 1 END) as high_count
FROM Risk_Scores
WHERE Calculated_At = (SELECT MAX(Calculated_At) FROM Risk_Scores)
GROUP BY CASE 
    WHEN Has_Response = 0 THEN 'No Response Yet'
    ELSE 'Has First Response'
END;

-- ============================================================================
-- QUERY EXAMPLES FOR POWER BI / ALERTS
-- ============================================================================

/*
-- Example 1: All critical tickets needing immediate attention
SELECT *
FROM View_Critical_Risk_Tickets
ORDER BY SLA_Breach_Probability DESC;

-- Example 2: Repositories with highest risk (management view)
SELECT *
FROM View_Risk_By_Repository
WHERE repo_risk_status = '🔴 HIGH RISK REPO'
ORDER BY avg_breach_probability DESC;

-- Example 3: Risk distribution summary
SELECT *
FROM View_Risk_Distribution
ORDER BY avg_breach_probability DESC;

-- Example 4: Does first response help? (Quality metric)
SELECT *
FROM View_Response_Time_Risk_Impact;

-- Example 5: Specific ticket details for escalation
SELECT TOP 15
    Ticket_Key,
    Repo_Name,
    Author_Name,
    CAST(Ticket_Age_Hours AS INT) as hours_open,
    Comment_Count,
    SLA_Breach_Probability,
    Risk_Tier,
    hours_until_sla_deadline
FROM View_Open_Tickets_Risk
WHERE Risk_Tier LIKE 'CRITICAL%'
ORDER BY SLA_Breach_Probability DESC;

-- Example 6: Alert for repos with no responses on high-risk tickets
SELECT
    Repo_Name,
    COUNT(*) as no_response_high_risk_count,
    ROUND(AVG(SLA_Breach_Probability), 2) as avg_breach_prob
FROM View_Open_Tickets_Risk
WHERE has_first_response = 'No - Awaiting Response'
  AND SLA_Breach_Probability >= 60
GROUP BY Repo_Name
ORDER BY avg_breach_prob DESC;
*/
