-- ============================================================================
-- SLA Breach Risk Scoring Model - PostgreSQL
-- GitHub Support Operations Analytics
-- Purpose: Real-time risk alerts for open tickets approaching SLA deadline
-- Source: Python statistical model (03_risk_score_sla_prediction.ipynb)
-- Database: PostgreSQL 12+
-- ============================================================================

-- ============================================================================
-- TABLE: risk_scores (Populated by Python SLA Prediction Model)
-- ============================================================================

CREATE TABLE IF NOT EXISTS risk_scores (
    risk_score_key BIGSERIAL PRIMARY KEY,
    ticket_key BIGINT NOT NULL,
    repo_name VARCHAR(255),
    author_name VARCHAR(255),
    created_at TIMESTAMP,
    ticket_age_hours NUMERIC(8,2),
    comment_count INTEGER,
    label_weight NUMERIC(4,2),
    has_response SMALLINT,
    sla_breach_probability NUMERIC(5,2),
    risk_tier VARCHAR(50),
    calculated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (ticket_key) REFERENCES fact_tickets(ticket_key)
);

CREATE INDEX IF NOT EXISTS idx_risk_breach_prob ON risk_scores(sla_breach_probability);
CREATE INDEX IF NOT EXISTS idx_risk_tier ON risk_scores(risk_tier);
CREATE INDEX IF NOT EXISTS idx_risk_ticket ON risk_scores(ticket_key);
CREATE INDEX IF NOT EXISTS idx_risk_calculated ON risk_scores(calculated_at);

-- ============================================================================
-- VIEW: Open Tickets Risk Dashboard
-- ============================================================================
-- Real-time view of all open tickets with risk classifications

CREATE OR REPLACE VIEW v_open_tickets_risk AS
SELECT
    rs.ticket_key,
    rs.repo_name,
    rs.author_name,
    rs.created_at,
    rs.ticket_age_hours,
    rs.comment_count,
    rs.label_weight,
    rs.has_response,
    CASE WHEN rs.has_response = 1 THEN 'Yes' ELSE 'No - Awaiting Response' END as has_first_response,
    rs.sla_breach_probability,
    rs.risk_tier,
    24 - rs.ticket_age_hours as hours_until_sla_deadline,
    CASE
        WHEN 24 - rs.ticket_age_hours <= 0 THEN 'OVERDUE'
        WHEN 24 - rs.ticket_age_hours <= 2 THEN 'Less than 2 hours'
        WHEN 24 - rs.ticket_age_hours <= 6 THEN 'Less than 6 hours'
        ELSE CAST(CAST(24 - rs.ticket_age_hours AS INTEGER) AS VARCHAR) || ' hours'
    END as time_remaining
FROM risk_scores rs
WHERE rs.calculated_at = (SELECT MAX(calculated_at) FROM risk_scores)
ORDER BY rs.sla_breach_probability DESC;

-- ============================================================================
-- VIEW: Critical Risk Tickets (Escalation Alert)
-- ============================================================================
-- Only tickets with >80% breach probability or overdue

CREATE OR REPLACE VIEW v_critical_risk_tickets AS
SELECT
    ticket_key,
    repo_name,
    author_name,
    created_at,
    ticket_age_hours,
    comment_count,
    sla_breach_probability,
    hours_until_sla_deadline,
    CASE
        WHEN hours_until_sla_deadline < 0 THEN '🔴 OVERDUE - IMMEDIATE ESCALATION'
        WHEN sla_breach_probability >= 90 THEN '🔴 CRITICAL (90%+ breach risk)'
        WHEN sla_breach_probability >= 80 THEN '🟠 SEVERE (80%+ breach risk)'
        ELSE 'Monitoring'
    END as escalation_action
FROM v_open_tickets_risk
WHERE sla_breach_probability >= 80
   OR hours_until_sla_deadline <= 0
ORDER BY sla_breach_probability DESC, hours_until_sla_deadline ASC;

-- ============================================================================
-- VIEW: Risk by Repository (Aggregate)
-- ============================================================================

CREATE OR REPLACE VIEW v_risk_by_repository AS
SELECT
    repo_name,
    COUNT(*) as total_open_tickets,
    COUNT(CASE WHEN risk_tier = 'CRITICAL - Immediate Action' THEN 1 END) as critical_count,
    COUNT(CASE WHEN risk_tier = 'HIGH - Monitor Closely' THEN 1 END) as high_count,
    COUNT(CASE WHEN risk_tier = 'MEDIUM - Track Progress' THEN 1 END) as medium_count,
    ROUND(AVG(sla_breach_probability), 2) as avg_breach_probability,
    ROUND(AVG(ticket_age_hours), 2) as avg_ticket_age_hours,
    ROUND(AVG(comment_count), 2) as avg_comment_count,
    COUNT(CASE WHEN has_response = 0 THEN 1 END) as tickets_awaiting_response,
    CASE
        WHEN ROUND(AVG(sla_breach_probability), 2) >= 70 THEN '🔴 HIGH RISK REPO'
        WHEN ROUND(AVG(sla_breach_probability), 2) >= 50 THEN '🟠 ELEVATED RISK'
        ELSE '🟢 MANAGED RISK'
    END as repo_risk_status
FROM risk_scores
WHERE calculated_at = (SELECT MAX(calculated_at) FROM risk_scores)
GROUP BY repo_name
ORDER BY avg_breach_probability DESC;

-- ============================================================================
-- VIEW: Risk Score Distribution
-- ============================================================================

CREATE OR REPLACE VIEW v_risk_distribution AS
SELECT
    risk_tier,
    COUNT(*) as ticket_count,
    ROUND(CAST(COUNT(*) AS FLOAT8) / (SELECT COUNT(*) FROM risk_scores WHERE calculated_at = (SELECT MAX(calculated_at) FROM risk_scores)) * 100, 2) as percentage,
    ROUND(AVG(sla_breach_probability), 2) as avg_breach_probability,
    MIN(sla_breach_probability) as min_probability,
    MAX(sla_breach_probability) as max_probability
FROM risk_scores
WHERE calculated_at = (SELECT MAX(calculated_at) FROM risk_scores)
GROUP BY risk_tier
ORDER BY AVG(sla_breach_probability) DESC;

-- ============================================================================
-- VIEW: Response Time Impact on Risk
-- ============================================================================
-- Does having a first response reduce risk?

CREATE OR REPLACE VIEW v_response_time_risk_impact AS
SELECT
    CASE 
        WHEN has_response = 0 THEN 'No Response Yet'
        ELSE 'Has First Response'
    END as response_status,
    COUNT(*) as ticket_count,
    ROUND(AVG(sla_breach_probability), 2) as avg_breach_probability,
    ROUND(AVG(ticket_age_hours), 2) as avg_ticket_age_hrs,
    ROUND(AVG(comment_count), 2) as avg_comment_count,
    COUNT(CASE WHEN risk_tier LIKE 'CRITICAL%' THEN 1 END) as critical_count,
    COUNT(CASE WHEN risk_tier LIKE 'HIGH%' THEN 1 END) as high_count
FROM risk_scores
WHERE calculated_at = (SELECT MAX(calculated_at) FROM risk_scores)
GROUP BY CASE 
    WHEN has_response = 0 THEN 'No Response Yet'
    ELSE 'Has First Response'
END;

-- ============================================================================
-- QUERY EXAMPLES FOR TABLEAU / ALERTS
-- ============================================================================

/*
-- Example 1: All critical tickets needing immediate attention
SELECT * FROM v_critical_risk_tickets
ORDER BY sla_breach_probability DESC;

-- Example 2: Repositories with highest risk (management view)
SELECT * FROM v_risk_by_repository
WHERE repo_risk_status = '🔴 HIGH RISK REPO'
ORDER BY avg_breach_probability DESC;

-- Example 3: Risk distribution summary
SELECT * FROM v_risk_distribution
ORDER BY avg_breach_probability DESC;

-- Example 4: Does first response help? (Quality metric)
SELECT * FROM v_response_time_risk_impact;

-- Example 5: Specific ticket details for escalation
SELECT TOP 15
    ticket_key,
    repo_name,
    author_name,
    CAST(ticket_age_hours AS INTEGER) as hours_open,
    comment_count,
    sla_breach_probability,
    risk_tier,
    hours_until_sla_deadline
FROM v_open_tickets_risk
WHERE risk_tier LIKE 'CRITICAL%'
ORDER BY sla_breach_probability DESC;
*/
