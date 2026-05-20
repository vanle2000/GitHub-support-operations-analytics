# GitHub Support Operations Analytics - Architectural Review

## EXECUTIVE SUMMARY

Your data architecture demonstrates **solid fundamentals** and **practical business insight**, typical of well-executed mid-market analytics platforms. The star schema is appropriately designed, the NLP integration is thoughtful, and your health scoring models show clear business alignment.

**However**, from an enterprise perspective, there are **3 critical architectural gaps** and **5 optimization opportunities** that would significantly enhance scalability, maintainability, and business impact.

---

## ARCHITECTURE REVIEW

### 1. STAR SCHEMA DESIGN

#### ✅ STRENGTHS:

```
Your Current Structure:
dim_repository (4 columns) ─────┐
dim_contributor (4 cols)        │
dim_authors (author_tier) ──────├──→ fact_tickets (13 columns)
dim_labels (standardized_cat)   │    ├── fact_sentiment (6 cols)
                                └──→ risk_scores (11 cols)
```

**What Works:**
- ✅ Normalized dimension tables with appropriate granularity
- ✅ Proper foreign key relationships (referential integrity)
- ✅ BIGSERIAL PKs for scalability (handles billions of rows)
- ✅ Excellent indexing strategy (all fact tables indexed on repo_id, author_id, created_at)
- ✅ Temporal reasoning built in (created_at, first_response_at, closed_at tracking)
- ✅ Sentiment tracking as a separate fact table (excellent modularity)

#### ⚠️ GAPS:

**Critical Gap #1: Missing Slowly Changing Dimension (SCD) Logic**
```sql
-- PROBLEM: If an author changes tier (Newbie → Contributor → Maintainer)
-- Your current schema OVERWRITES the history
-- Amazon Scale Impact: Incorrect retention calculations when roles change

-- SOLUTION: Add SCD Type 2 to dim_authors
CREATE TABLE dim_authors_scd (
    author_key BIGSERIAL PRIMARY KEY,
    author_id INT,
    author_name VARCHAR(255),
    author_tier VARCHAR(50),
    effective_date DATE,
    end_date DATE DEFAULT NULL,
    is_current BOOLEAN DEFAULT TRUE
);
-- This allows: "When did Alice become a Maintainer?"
```

**Critical Gap #2: Missing Date/Time Dimension**
```sql
-- PROBLEM: Your queries repeat EXTRACT(EPOCH...) everywhere
-- 5 different places = 5 opportunities for bugs
-- Amazon Best Practice: Centralize temporal logic

CREATE TABLE dim_time (
    time_key SERIAL PRIMARY KEY,
    full_date DATE,
    year_month VARCHAR(7),
    quarter VARCHAR(2),
    day_of_week VARCHAR(10),
    is_weekend BOOLEAN
);
-- Then: fact_tickets.response_day_key, response_hour_key
-- Benefit: Consistent "holiday-aware" calculations, time-zone handling
```

**Critical Gap #3: No Label/Category Hierarchy**
```sql
-- PROBLEM: You flatten labels to 4 categories (Bug, Feature, Question, Other)
-- But lose the original GitHub label for root cause analysis
-- Missing intermediate taxonomy

-- SOLUTION: Add bridging table
CREATE TABLE dim_label_hierarchy (
    label_hierarchy_key SERIAL PRIMARY KEY,
    github_label_raw VARCHAR(255),
    standardized_category VARCHAR(50),
    severity_tier INT,
    sla_priority INT
);

-- Now you can slice by:
-- - High-level (Feature/Bug/Question)
-- - Medium-level (e.g., "Critical Bug" vs "Nice-to-Have Enhancement")
-- - Low-level (raw GitHub tags for platform-specific analysis)
```

---

### 2. FACT TABLE DESIGN

#### ✅ STRENGTHS:
- ✅ Single fact table = simple, maintainable (no conformed dimension confusion)
- ✅ Proper granularity: ONE row per issue (atomic)
- ✅ Descriptive vs. derived metrics handled correctly (closed_at captured, not calculated)
- ✅ Nullable first_response_at handles "no response" scenario elegantly

#### ⚠️ GAPS:

**Gap #1: Denormalization Without Purpose**
```sql
-- Current fact_tickets has these DERIVED fields:
-- - comment_count: Can be calculated from fact_sentiment rows
-- - is_resolved: Redundant with (closed_at IS NOT NULL)

-- RECOMMENDATION: Either store them OR pre-aggregate
-- DO NOT store both (update consistency nightmare)

-- Option A: Remove comment_count, calculate on-the-fly from fact_sentiment
-- Option B: Remove fact_sentiment, denormalize comments into fact_tickets

-- Amazon Rule: If a metric is in 2 places, you WILL have a bug someday
```

**Gap #2: Missing SLA Contract Tracking**
```sql
-- Problem: Your SLA is hardcoded as "24 hours"
-- But reality: SLA changes by repository or label

-- Better design:
CREATE TABLE dim_sla_contracts (
    sla_contract_key SERIAL PRIMARY KEY,
    repo_id INT,
    label_category VARCHAR(50),
    response_sla_hours INT,
    resolution_sla_days INT,
    effective_date DATE,
    end_date DATE
);

-- Then: fact_tickets.sla_contract_key
-- Benefit: "What was the SLA target for this ticket?"
-- Enables: SLA trend analysis (has SLA been tightening/loosening?)
```

**Gap #3: No Audit Trail**
```sql
-- Problem: ETL fails silently if:
-- - Row appears in fact_tickets but no dim_author exists (orphan record)
-- - ticket_age_hours calculated wrong in Python (no data validation)
-- - Repository goes from "active" to "archived"

-- Solution: Add quality metrics table
CREATE TABLE fact_data_quality (
    quality_check_key BIGSERIAL PRIMARY KEY,
    check_date DATE,
    table_name VARCHAR(100),
    orphaned_records INT,
    missing_first_response_pct NUMERIC,
    duplicate_ticket_ids INT,
    data_freshness_hours INT,
    check_status VARCHAR(50)
);
-- Track: "Is our data reliable?"
```

---

### 3. METRIC CALCULATION LOGIC

#### ✅ WHAT WORKS WELL:

**Health Score Formula is Sound:**
```
Health = (Retention * 0.5) + (SLA * 0.3) - (Res_Time * 0.2)
```
- ✅ Weights are defensible (retention is most important)
- ✅ Directional logic correct (longer resolution time = penalty)
- ✅ Categorization (Toxic/At Risk/Healthy) creates actionable segments
- ✅ "Golden Hour" insight (12-hour threshold = 3.5x lift) is GOLD

**SLA Risk Model is Mathematically Sound:**
```
Breach_Probability = (Time_Risk * 0.5) + (Comment_Risk * 0.3) + (Label_Weight * 0.2)
```
- ✅ Properly normalized (0-100 scale)
- ✅ Multi-factor model prevents oversimplification
- ✅ Comment count as proxy for complexity is clever
- ✅ Label weighting enables priority-based logic

#### ⚠️ IMPROVEMENTS NEEDED:

**Issue #1: Static Weights Without Validation**
```sql
-- Current: Hardcoded weights (Retention=50%, SLA=30%, Time=20%)
-- Problem: You don't validate these are optimal

-- Better: Add model performance tracking
CREATE TABLE fact_model_weights_test (
    experiment_id SERIAL PRIMARY KEY,
    weight_retention NUMERIC,
    weight_sla NUMERIC,
    weight_time NUMERIC,
    prediction_accuracy NUMERIC,
    tested_date DATE
);

-- Then use A/B testing to confirm:
-- "Does 50/30/20 actually predict retention better than 40/40/20?"
```

**Issue #2: Resolution Time Normalization**
```sql
-- Current: Linear penalty for avg_resolution_hrs
-- Problem: Non-linear (100 hours is worse than 50 hours, but is it 2x worse?)

-- Suggestion: Log-scale penalty
-- (avg_resolution_hrs > 100 THEN 20 ELSE avg_resolution_hrs * 0.1)
-- Should be: LN(avg_resolution_hrs) * penalty_factor

-- This captures: First 24 hours matter more than going from 200→300 hours
```

**Issue #3: Frustrated User Definition Might Be Too Simple**
```sql
-- Current: initial_sentiment >= 0 AND final_sentiment dropped > 0.5
-- Problem: Misses context

-- Better:
-- VADER compound ranges: -1 to +1 (more nuanced than binary)
-- Current definition: Only catches if user STARTED positive

-- But what about: Started neutral, ended very angry?
-- Or: Started positive, ended still positive but declined?

-- Recommendation: Add frustration_level dimension
-- (Very Frustrated, Frustrated, Neutral, Satisfied, Very Satisfied)
-- This captures gradation, not just binary
```

---

### 4. ETL PIPELINE (Python Notebooks)

#### ✅ STRENGTHS:
- ✅ Clean modular structure (01=explore, 02=NLP, 03=risk)
- ✅ VADER sentiment choice is smart (faster than BERT, good enough for GH support)
- ✅ Label standardization logic prevents data chaos
- ✅ SQLAlchemy for database insertion is correct pattern
- ✅ Filtering for open tickets in risk model is precise

#### ⚠️ PRODUCTION READINESS GAPS:

**Critical Issue #1: No Error Handling**
```python
# Current pattern:
df = pd.read_csv('helpdesk_tickets.csv')  # What if file missing?
sentiment_output.to_sql('Fact_Sentiment', con=engine, if_exists='replace')
# if_exists='replace' = DELETES ALL DATA if schema changes

# Production pattern:
try:
    df = pd.read_csv(CSV_PATH)
except FileNotFoundError:
    logger.error(f"CSV not found at {CSV_PATH}"); sys.exit(1)

# Use if_exists='append' with upsert logic (ON CONFLICT)
```

**Critical Issue #2: Hardcoded Values in Code**
```python
# Hardcoded: label_map = {'bug': 'High Priority - Bug', ...}
# Hardcoded: VADER sentiment cutoff = -0.5
# Hardcoded: Risk weights = (0.5, 0.3, 0.2)

# Should be: Configuration management
config.yaml:
    label_map:
        bug: "High Priority - Bug"
    sentiment_thresholds:
        frustrated_user_drop: -0.5
    risk_model_weights:
        time_risk: 0.5
        comment_risk: 0.3

# Enables: Change thresholds without redeploying code
```

**Critical Issue #3: No Incremental/Delta Loads**
```python
# Current: if_exists='replace' = FULL RELOAD EVERY RUN
# Problem: Inefficient, slow, re-processes old data

# Better:
# 1. Track max(created_at) from last run
# 2. Only process tickets created since then
# 3. Upsert into database (INSERT ... ON CONFLICT UPDATE)

# Benefits:
# - Reduces compute (1M old rows → only 1K new rows)
# - Enables real-time refresh (run hourly, not nightly)
```

**Critical Issue #4: No Data Validation Layer**
```python
# Current: Trust CSV is correct

# Add validation:
class TicketValidator:
    def validate_row(self, row):
        assert row['created_at'] <= row['closed_at'], "Invalid dates"
        assert row['comment_count'] >= 0, "Negative comment count"
        assert row['repo_name'] in KNOWN_REPOS, "Unknown repo"
        assert row['author_name'] is not None, "Missing author"
        return True

# This catches 80% of data quality issues upstream
```

---

### 5. VIEWS & AGGREGATIONS

#### ✅ EXCELLENT WORK:

**v_executive_integrated_health** is the star of your design:
- ✅ Combines all 3 fact tables (tickets, sentiment, risk) elegantly
- ✅ Left joins handle missing data correctly
- ✅ CTE structure is readable
- ✅ COALESCE handles null sentiment/risk gracefully
- ✅ Perfect for Tableau (15 columns = manageable cardinality)

**v_risk_by_repository** is production-grade:
- ✅ Counts by risk_tier correctly
- ✅ Averages are meaningful
- ✅ Emoji indicators (🔴 vs 🟠) add UX value
- ✅ Properly filtered by latest calculation timestamp

#### ⚠️ OPTIMIZATION OPPORTUNITIES:

**Opportunity #1: Materialized Views for Performance**
```sql
-- Current: All views calculated on-the-fly
-- Problem: Tableau refreshes trigger recalculation of complex CTEs
-- Cost: If v_executive_integrated_health takes 10 seconds,
--       and Tableau dashboard has 5 sheets, total = 50 seconds

-- Solution: Materialize the heavy ones
CREATE MATERIALIZED VIEW mv_executive_integrated_health AS
SELECT * FROM v_executive_integrated_health;

REFRESH MATERIALIZED VIEW CONCURRENTLY mv_executive_integrated_health;
-- (Run nightly via cron, not on-demand)

-- Benefits:
-- - Tableau dashboard loads in 1-2 seconds (not 50)
-- - Users see refreshed data within predictable window (8am refresh = 8:05am ready)
-- - Database query log shows fast queries (materialized views = small tables)
```

**Opportunity #2: Incremental Aggregation**
```sql
-- Current aggregation (v_executive_integrated_health):
WHERE f.created_at >= CURRENT_DATE - INTERVAL '90 days'

-- Problem: Recalculates ALL 90 days every refresh
-- If you have 10M tickets/year, that's 2.5M recalculated every query

-- Better: Pre-aggregate by day, roll up
CREATE TABLE fact_daily_repo_health (
    date DATE,
    repo_name VARCHAR(255),
    daily_tickets INT,
    daily_sla_met INT,
    daily_frustration_count INT,
    cumulative_breach_probability NUMERIC
);

-- Then v_executive_integrated_health becomes:
SELECT repo_name,
       SUM(daily_tickets) as total_tickets_90d,
       SUM(daily_sla_met) / SUM(daily_tickets) as sla_pct
FROM fact_daily_repo_health
WHERE date >= CURRENT_DATE - 90;
-- Instant queries on 90 rows instead of 2.5M rows
```

**Opportunity #3: Missing Metrics Customers Actually Want**
```sql
-- You track: SLA, Retention, Health Score
-- But missing: Things that drive business decisions

-- Recommend adding:

-- 1. Response Consistency
SELECT repo_name,
       STDDEV(EXTRACT(EPOCH FROM (first_response_at - created_at))/3600) as response_time_variance
-- Why: Inconsistent response (0-50 hours) is worse than consistent (20 hours)

-- 2. Escalation Frequency
SELECT repo_name,
       COUNT(*) FILTER (WHERE comment_count > 10) / COUNT(*) as escalation_rate_pct
-- Why: High escalation = root cause analysis problem

-- 3. First-Contact Resolution (BEST METRIC)
SELECT repo_name,
       COUNT(*) FILTER (WHERE is_resolved AND comment_count <= 2) / COUNT(*) as fcr_pct
-- Why: If your first response ACTUALLY resolves the issue = best SLA metric
-- Current 24-hour response might be hit, but customer still frustrated (12 more comments)
```

---

## TOP 5 PRIORITIES TO FIX 

### Priority 1: Data Quality Framework (CRITICAL)
```python
# Add this to your ETL:
class DataQualityGate:
    def check_pre_load(self, df):
        issues = []
        if df.isnull().sum().any():
            issues.append(f"Nulls found: {df.isnull().sum()}")
        if df[df['created_at'] > df['closed_at']].shape[0] > 0:
            issues.append("Reversed dates found")
        if issues:
            logger.error("; ".join(issues))
            raise DataQualityException()
        return True
```
**Why**: One bad row corrupts health_score calculations for entire repo

---

### Priority 2: Incremental Load Pattern (HIGH)
```python
# Replace if_exists='replace' with:
def upsert_fact_sentiment(df, engine):
    with engine.begin() as conn:
        conn.execute(text("""
            INSERT INTO fact_sentiment (ticket_key, initial_sentiment, ...)
            VALUES (:ticket_key, :initial_sentiment, ...)
            ON CONFLICT (ticket_key) DO UPDATE SET
                final_sentiment = :final_sentiment,
                sentiment_shift = :sentiment_shift
        """), df.to_dict('records'))
```
**Why**: Enables real-time refreshes (currently limited to nightly)

---

### Priority 3: SCD for dim_authors (HIGH)
```sql
-- Track when authors change tier:
-- This enables: "Did retention improve AFTER we promoted more contributors?"
-- Without SCD: Historical analysis is impossible
```
**Why**: Unlocks causal analysis (does maintainer promotion → retention?)

---

### Priority 4: Materialized Views (MEDIUM)
```sql
REFRESH MATERIALIZED VIEW mv_executive_integrated_health;
-- Scheduled nightly, cuts query time from 50s → 2s
```
**Why**: Tableau dashboard performance (user experience)

---

### Priority 5: First-Contact Resolution Metric (MEDIUM)
```sql
-- Add to health score formula:
-- (Retention * 0.5) + (SLA * 0.3) + (FCR * 0.15) - (Time * 0.05)
-- This shift: Emphasis from "fast response" to "good response"
```
**Why**: Better business alignment (customers care about *resolution*, not *response*)

---

## SCALABILITY ASSESSMENT

### Current Capacity (Your System Today):
- **Tickets**: ~10M (comfortable)
- **Sentiment rows**: ~10M (parallel fact table = good)
- **Risk scores**: Re-calculated nightly (fine)
- **Query latency**: Estimated 10-30s for v_executive_integrated_health
- **Tableau load time**: ~1-2 minutes for full dashboard refresh

### Scaling Horizon (If You Grow 10x):
- **Tickets**: 100M
- **Query latency**: 100-300s (TOO SLOW)
- **Tableau**: Unusable

### How to Scale:
1. ✅ Materialized views (already recommended)
2. ✅ Incremental fact aggregation (daily pre-aggs)
3. ✅ Partitioning fact tables by repo_id or month
4. ✅ Consider columnar format (Parquet) for historical archive
5. ✅ Add caching layer (Redis) for frequently accessed repos

---

## 💡 BUSINESS INSIGHTS (Exceptionally Well Done)

Your three core discoveries are **legitimately insightful**:

### ✅ Discovery #1: "Toxic Repositories" Concept
- Identifies repos with HIGH traffic but POOR SLA
- Health Score formula surfaces this clearly
- **Impact**: Allows targeted team investment

### ✅ Discovery #2: "Golden Hour" Effect (12-hour response = 3.5x lift)
- **This is research-grade insight**
- Data-driven SLA target (not arbitrary "1 business day")
- **Impact**: Can justify team hiring/process changes with math

### ✅ Discovery #3: Sentiment Volatility ≠ Product Quality
- "Users went from positive → negative even though issue was fixed"
- Distinguishes support problem from product problem
- **Impact**: Helps product team vs. support team prioritize differently

**Recommendation**: Publish these 3 insights as internal research. They're worth more than the dashboards.

---

## 🔐 DATA GOVERNANCE OBSERVATIONS

### Missing Documentation:
- [ ] Data dictionary (what is comment_count? system-generated or real?)
- [ ] Calculation lineage (where does health_score feed to?)
- [ ] Ownership (who updates label_map when GitHub changes tags?)
- [ ] SLA contracts document (when was 24-hour SLA set?)
- [ ] Refresh schedule (when does Python run? What's the cutoff?)

### Recommendation:
Create a single `DATA_GOVERNANCE.md`:
```markdown
# Data Governance

## fact_tickets
- Grain: One row per GitHub issue
- Refresh: Nightly (10 PM PST via Airflow)
- Owner: DevOps Analytics
- Recalculation: Yes (full reload to catch edits)

## dim_authors
- Grain: One row per unique GitHub user (current state)
- Issue: Author tier only captured once (no history)
- Recommendation: Add SCD Type 2 for role changes
```

---

## FINAL ASSESSMENT

- Core architecture is sound and normalized
- Business metrics are well-designed
- ETL is functional
- Insights are genuinely valuable

## IMPROVEMENTS
- Gaps in enterprise production rigor (error handling, validation, monitoring)
- Some technical debt (hardcoded values, full reloads, no incremental logic)
- Missing scalability patterns (materialized views, aggregation pre-computation)
- Data quality framework is absent

### NEXT STEPS:
1. **Immediate** (1 week): Add data quality gate to Python notebooks
2. **Short-term** (2 weeks): Implement materialized views
3. **Medium-term** (1 month): Add SCD to dim_authors, incremental loads
4. **Long-term** (ongoing): Publish business insights, document data governance

---

## Questions for Your Team:

1. **Who reviews the health_score weights?** Are they validated against actual churn data?
2. **How many repositories are "Toxic" in your actual dataset?** Is intervention possible?
3. **Has the "Golden Hour" insight translated to process changes?**
4. **Who owns updating the label_map when GitHub tags evolve?**
5. **What's your current data refresh latency?** (Real-time vs. daily?)


