#!/bin/bash
# GitHub Support Operations Analytics - Cleanup Script
# Removes deprecated T-SQL files and temporary documentation

echo "🧹 Cleaning repository: Removing non-PostgreSQL files..."

# Remove deprecated T-SQL SQL files
rm -f SQL/02_repo_health_metrics_tsql.sql
rm -f SQL/03_view_repo_health_metrics_azure.sql
rm -f SQL/04_sentiment_volatility_metrics.sql
rm -f SQL/05_risk_scoring_model.sql
rm -f SQL/06_executive_health_summary.sql

# Remove temporary migration documentation
rm -f MIGRATION_TO_POSTGRESQL_TABLEAU.md
rm -f VALIDATION_REPORT.md

echo "✅ Cleanup complete!"
echo ""
echo "Remaining PostgreSQL SQL files:"
ls -lh SQL/*.sql

echo ""
echo "Documentation files:"
ls -lh *.md | grep -v node_modules
