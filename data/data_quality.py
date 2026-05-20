
import pandas as pd
import numpy as np
import logging
from datetime import datetime, timedelta
from typing import Dict, List, Tuple, Optional
from dataclasses import dataclass
from enum import Enum

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class DataQualitySeverity(Enum):
    """Data quality issue severity levels"""
    ERROR = "ERROR"          # Blocks load
    WARNING = "WARNING"      # Logs but continues
    INFO = "INFO"            # Informational only


@dataclass
class DataQualityIssue:
    """Represents a single data quality issue"""
    check_name: str
    severity: DataQualitySeverity
    message: str
    affected_rows: int = 0
    
    def __str__(self):
        return f"[{self.severity.value}] {self.check_name}: {self.message} ({self.affected_rows} rows)"


class DataQualityException(Exception):
    """Raised when critical data quality issues are found"""
    pass


class DataQualityValidator:
    """
    Comprehensive data quality validation framework
    
    Validates data against business rules and schema expectations before
    loading into analytics database.
    """
    
    def __init__(self, table_name: str = "unknown", verbose: bool = True):
        self.table_name = table_name
        self.verbose = verbose
        self.issues: List[DataQualityIssue] = []
        self.check_timestamp = datetime.now()
        
    def add_issue(self, check_name: str, severity: DataQualitySeverity, 
                  message: str, affected_rows: int = 0):
        """Record a data quality issue"""
        issue = DataQualityIssue(check_name, severity, message, affected_rows)
        self.issues.append(issue)
        
        if self.verbose:
            logger.log(
                logging.ERROR if severity == DataQualitySeverity.ERROR else 
                logging.WARNING if severity == DataQualitySeverity.WARNING else 
                logging.INFO,
                str(issue)
            )
    
    def check_null_values(self, df: pd.DataFrame, critical_columns: List[str] = None) -> bool:
        """
        CHECK 1: Validate no null values in critical columns
        
        Args:
            df: DataFrame to validate
            critical_columns: Columns that must not have nulls
            
        Returns:
            True if check passes, False otherwise
        """
        if critical_columns is None:
            critical_columns = df.columns.tolist()
        
        null_counts = df[critical_columns].isnull().sum()
        
        if null_counts.any():
            null_info = null_counts[null_counts > 0]
            message = f"Null values found: {dict(null_info)}"
            affected_rows = df[critical_columns].isnull().any(axis=1).sum()
            
            self.add_issue(
                "NULL_VALUES",
                DataQualitySeverity.ERROR,
                message,
                affected_rows
            )
            return False
        
        logger.info(f"✓ Null check passed for {self.table_name}")
        return True
    
    def check_date_logic(self, df: pd.DataFrame, 
                        start_col: str, end_col: str = None,
                        min_col: str = None, max_col: str = None) -> bool:
        """
        CHECK 2: Validate date relationships (no reversed dates)
        
        Args:
            df: DataFrame to validate
            start_col: Start date column name
            end_col: End date column name (optional)
            min_col: Minimum allowed date (optional)
            max_col: Maximum allowed date (optional)
            
        Returns:
            True if check passes, False otherwise
        """
        passed = True
        
        # Check for future dates beyond reasonable window
        if max_col is None:
            max_col = datetime.now() + timedelta(days=7)  # Allow 7 days future
        
        future_rows = df[df[start_col] > max_col]
        if len(future_rows) > 0:
            self.add_issue(
                "FUTURE_DATES",
                DataQualitySeverity.WARNING,
                f"Future dates found in {start_col}",
                len(future_rows)
            )
            passed = False
        
        # Check for dates too far in past
        if min_col is None:
            min_col = datetime.now() - timedelta(days=3650)  # 10 years back
        
        past_rows = df[df[start_col] < min_col]
        if len(past_rows) > 0:
            self.add_issue(
                "VERY_OLD_DATES",
                DataQualitySeverity.WARNING,
                f"Very old dates found in {start_col}",
                len(past_rows)
            )
            passed = False
        
        # Check for reversed date ranges
        if end_col:
            reversed_rows = df[df[start_col] > df[end_col]]
            if len(reversed_rows) > 0:
                self.add_issue(
                    "REVERSED_DATES",
                    DataQualitySeverity.ERROR,
                    f"Reversed dates: {start_col} > {end_col}",
                    len(reversed_rows)
                )
                passed = False
        
        if passed:
            logger.info(f"✓ Date logic check passed for {self.table_name}")
        
        return passed
    
    def check_duplicates(self, df: pd.DataFrame, key_columns: List[str]) -> bool:
        """
        CHECK 3: Identify duplicate records by key
        
        Args:
            df: DataFrame to validate
            key_columns: Column(s) that should be unique
            
        Returns:
            True if no duplicates, False if duplicates found
        """
        duplicates = df.duplicated(subset=key_columns, keep=False)
        dup_count = duplicates.sum()
        
        if dup_count > 0:
            self.add_issue(
                "DUPLICATE_KEYS",
                DataQualitySeverity.ERROR,
                f"Duplicate records found on {key_columns}",
                dup_count
            )
            return False
        
        logger.info(f"✓ Duplicate check passed for {self.table_name}")
        return True
    
    def check_foreign_keys(self, df: pd.DataFrame, fk_column: str, 
                          valid_ids: List[int]) -> bool:
        """
        CHECK 4: Validate foreign key references
        
        Args:
            df: DataFrame to validate
            fk_column: Foreign key column name
            valid_ids: List of valid IDs from parent table
            
        Returns:
            True if all FKs valid, False if orphan records found
        """
        orphan_rows = ~df[fk_column].isin(valid_ids)
        orphan_count = orphan_rows.sum()
        
        if orphan_count > 0:
            self.add_issue(
                "ORPHAN_RECORDS",
                DataQualitySeverity.ERROR,
                f"Orphan records in {fk_column} (FK not found in parent)",
                orphan_count
            )
            return False
        
        logger.info(f"✓ Foreign key check passed for {self.table_name}")
        return True
    
    def check_numeric_ranges(self, df: pd.DataFrame, 
                            column: str, min_val: float = None, 
                            max_val: float = None) -> bool:
        """
        CHECK 5: Validate numeric columns within acceptable ranges
        
        Args:
            df: DataFrame to validate
            column: Column name to check
            min_val: Minimum acceptable value
            max_val: Maximum acceptable value
            
        Returns:
            True if all values in range, False otherwise
        """
        passed = True
        
        if min_val is not None:
            below_min = (df[column] < min_val).sum()
            if below_min > 0:
                self.add_issue(
                    "VALUE_BELOW_MIN",
                    DataQualitySeverity.WARNING,
                    f"Values below minimum ({min_val}) in {column}",
                    below_min
                )
                passed = False
        
        if max_val is not None:
            above_max = (df[column] > max_val).sum()
            if above_max > 0:
                self.add_issue(
                    "VALUE_ABOVE_MAX",
                    DataQualitySeverity.WARNING,
                    f"Values above maximum ({max_val}) in {column}",
                    above_max
                )
                passed = False
        
        if passed:
            logger.info(f"✓ Numeric range check passed for {self.table_name}")
        
        return passed
    
    def check_categorical_values(self, df: pd.DataFrame, 
                                column: str, allowed_values: List[str]) -> bool:
        """
        CHECK 6: Validate categorical columns have only expected values
        
        Args:
            df: DataFrame to validate
            column: Column name to check
            allowed_values: List of allowed values
            
        Returns:
            True if all values valid, False otherwise
        """
        invalid_rows = ~df[column].isin(allowed_values)
        invalid_count = invalid_rows.sum()
        
        if invalid_count > 0:
            invalid_values = df.loc[invalid_rows, column].unique()
            self.add_issue(
                "INVALID_CATEGORY",
                DataQualitySeverity.ERROR,
                f"Invalid values in {column}: {list(invalid_values)}",
                invalid_count
            )
            return False
        
        logger.info(f"✓ Categorical check passed for {self.table_name}")
        return True
    
    def check_text_length(self, df: pd.DataFrame, column: str, 
                         max_length: int) -> bool:
        """
        CHECK 7: Validate text columns don't exceed max length
        
        Args:
            df: DataFrame to validate
            column: Column name to check
            max_length: Maximum allowed string length
            
        Returns:
            True if all strings within limit, False otherwise
        """
        too_long = (df[column].str.len() > max_length).sum()
        
        if too_long > 0:
            self.add_issue(
                "TEXT_TOO_LONG",
                DataQualitySeverity.WARNING,
                f"Text exceeds {max_length} chars in {column}",
                too_long
            )
            return False
        
        logger.info(f"✓ Text length check passed for {self.table_name}")
        return True
    
    def check_data_freshness(self, df: pd.DataFrame, column: str, 
                           max_days_old: int = 90) -> bool:
        """
        CHECK 8: Validate data is recent (no stale data)
        
        Args:
            df: DataFrame to validate
            column: Date column to check
            max_days_old: Maximum age in days
            
        Returns:
            True if data is recent, False if too stale
        """
        cutoff_date = datetime.now() - timedelta(days=max_days_old)
        stale_rows = (df[column] < cutoff_date).sum()
        
        if stale_rows > 0:
            self.add_issue(
                "STALE_DATA",
                DataQualitySeverity.WARNING,
                f"Stale records older than {max_days_old} days in {column}",
                stale_rows
            )
            return False
        
        logger.info(f"✓ Data freshness check passed for {self.table_name}")
        return True
    
    def check_sentiment_scores(self, df: pd.DataFrame, 
                              columns: List[str] = None) -> bool:
        """
        CHECK 9: Validate VADER sentiment scores are in [-1, 1] range
        
        Args:
            df: DataFrame to validate
            columns: Sentiment columns to check (default: all with 'sentiment' in name)
            
        Returns:
            True if all scores valid, False otherwise
        """
        if columns is None:
            columns = [col for col in df.columns if 'sentiment' in col.lower()]
        
        passed = True
        
        for col in columns:
            invalid = ((df[col] < -1) | (df[col] > 1)).sum()
            if invalid > 0:
                self.add_issue(
                    "INVALID_SENTIMENT_SCORE",
                    DataQualitySeverity.ERROR,
                    f"Sentiment scores outside [-1, 1] range in {col}",
                    invalid
                )
                passed = False
        
        if passed:
            logger.info(f"✓ Sentiment score check passed for {self.table_name}")
        
        return passed
    
    def check_response_logic(self, df: pd.DataFrame, 
                            created_col: str, response_col: str,
                            max_response_days: int = 30) -> bool:
        """
        CHECK 10: Validate response times are logically sound
        
        Args:
            df: DataFrame to validate
            created_col: Ticket creation date column
            response_col: First response date column
            max_response_days: Max acceptable response time
            
        Returns:
            True if response logic valid, False otherwise
        """
        # Filter to rows with responses
        with_response = df[df[response_col].notna()]
        
        # Response must be after creation
        invalid_order = (with_response[response_col] < with_response[created_col]).sum()
        if invalid_order > 0:
            self.add_issue(
                "INVALID_RESPONSE_TIME",
                DataQualitySeverity.ERROR,
                f"Response time before creation time",
                invalid_order
            )
            return False
        
        # Response shouldn't take more than max_response_days
        response_duration = (with_response[response_col] - with_response[created_col]).dt.days
        too_slow = (response_duration > max_response_days).sum()
        
        if too_slow > 0:
            self.add_issue(
                "UNREALISTIC_RESPONSE_TIME",
                DataQualitySeverity.WARNING,
                f"Response time > {max_response_days} days",
                too_slow
            )
        
        logger.info(f"✓ Response logic check passed for {self.table_name}")
        return invalid_order == 0
    
    def get_summary(self) -> Dict:
        """
        Get summary of all quality checks
        
        Returns:
            Dictionary with check results
        """
        errors = [i for i in self.issues if i.severity == DataQualitySeverity.ERROR]
        warnings = [i for i in self.issues if i.severity == DataQualitySeverity.WARNING]
        
        return {
            "table": self.table_name,
            "check_time": self.check_timestamp.isoformat(),
            "total_issues": len(self.issues),
            "errors": len(errors),
            "warnings": len(warnings),
            "issues": [
                {"check": i.check_name, "severity": i.severity.value, 
                 "message": i.message, "affected_rows": i.affected_rows}
                for i in self.issues
            ],
            "status": "PASS" if len(errors) == 0 else "FAIL"
        }
    
    def should_block_load(self) -> bool:
        """
        Determine if data should be blocked from loading
        
        Returns:
            True if any ERROR-level issues found, False otherwise
        """
        errors = [i for i in self.issues if i.severity == DataQualitySeverity.ERROR]
        return len(errors) > 0
    
    def raise_if_errors(self):
        """Raise exception if any ERROR-level issues found"""
        if self.should_block_load():
            error_msgs = [str(i) for i in self.issues 
                         if i.severity == DataQualitySeverity.ERROR]
            raise DataQualityException(
                f"Data quality errors found:\n" + "\n".join(error_msgs)
            )


class FactTicketsValidator(DataQualityValidator):
    """Specialized validator for fact_tickets table"""
    
    def validate_all(self, df: pd.DataFrame, 
                    known_repos: List[str] = None) -> bool:
        """
        Run all validations for fact_tickets
        
        Args:
            df: DataFrame to validate
            known_repos: List of valid repository names
            
        Returns:
            True if all checks pass, False if any fail
        """
        logger.info(f"Starting comprehensive validation for fact_tickets...")
        logger.info(f"Dataset size: {len(df)} rows x {len(df.columns)} columns")
        
        checks_passed = 0
        checks_failed = 0
        
        # Check 1: Critical nulls
        if self.check_null_values(df, critical_columns=['ticket_key', 'created_at', 'repo_name']):
            checks_passed += 1
        else:
            checks_failed += 1
        
        # Check 2: Date logic
        if self.check_date_logic(df, 'created_at', 'closed_at'):
            checks_passed += 1
        else:
            checks_failed += 1
        
        # Check 3: No duplicate tickets
        if self.check_duplicates(df, ['ticket_key']):
            checks_passed += 1
        else:
            checks_failed += 1
        
        # Check 4: Valid repositories
        if known_repos and self.check_categorical_values(df, 'repo_name', known_repos):
            checks_passed += 1
        else:
            checks_failed += 1
        
        # Check 5: Comment count >= 0
        if self.check_numeric_ranges(df, 'comment_count', min_val=0, max_val=10000):
            checks_passed += 1
        else:
            checks_failed += 1
        
        # Check 6: Response logic valid
        if self.check_response_logic(df, 'created_at', 'first_response_at'):
            checks_passed += 1
        else:
            checks_failed += 1
        
        logger.info(f"Validation complete: {checks_passed} passed, {checks_failed} failed")
        
        return not self.should_block_load()


class FactSentimentValidator(DataQualityValidator):
    """Specialized validator for fact_sentiment table"""
    
    def validate_all(self, df: pd.DataFrame) -> bool:
        """
        Run all validations for fact_sentiment
        
        Args:
            df: DataFrame to validate
            
        Returns:
            True if all checks pass, False if any fail
        """
        logger.info(f"Starting comprehensive validation for fact_sentiment...")
        logger.info(f"Dataset size: {len(df)} rows x {len(df.columns)} columns")
        
        checks_passed = 0
        checks_failed = 0
        
        # Check 1: Critical nulls
        if self.check_null_values(df, critical_columns=['ticket_key', 'initial_sentiment', 'final_sentiment']):
            checks_passed += 1
        else:
            checks_failed += 1
        
        # Check 2: Sentiment scores in valid range
        if self.check_sentiment_scores(df, ['initial_sentiment', 'final_sentiment', 'sentiment_shift']):
            checks_passed += 1
        else:
            checks_failed += 1
        
        # Check 3: Sentiment shift = final - initial
        df['calculated_shift'] = df['final_sentiment'] - df['initial_sentiment']
        shift_mismatch = (np.abs(df['sentiment_shift'] - df['calculated_shift']) > 0.01).sum()
        
        if shift_mismatch > 0:
            self.add_issue(
                "SENTIMENT_SHIFT_MISMATCH",
                DataQualitySeverity.WARNING,
                "Calculated sentiment_shift doesn't match final - initial",
                shift_mismatch
            )
            checks_failed += 1
        else:
            checks_passed += 1
        
        # Check 4: is_frustrated_user logic
        frustrated_check = (
            (df['is_frustrated_user'] == 1) & 
            ((df['initial_sentiment'] < 0) | (df['sentiment_shift'] > -0.5))
        ).sum()
        
        if frustrated_check > 0:
            self.add_issue(
                "FRUSTRATED_USER_LOGIC_ERROR",
                DataQualitySeverity.WARNING,
                "is_frustrated_user flag doesn't match sentiment criteria",
                frustrated_check
            )
            checks_failed += 1
        else:
            checks_passed += 1
        
        logger.info(f"Validation complete: {checks_passed} passed, {checks_failed} failed")
        
        return not self.should_block_load()


def create_quality_report_sql(summary: Dict) -> str:
    """
    Generate SQL INSERT for data quality tracking table
    
    Args:
        summary: Summary dict from validator
        
    Returns:
        SQL INSERT statement
    """
    timestamp = datetime.now().isoformat()
    
    sql = f"""
    INSERT INTO fact_data_quality 
    (check_date, table_name, total_issues, error_count, warning_count, check_status, check_details)
    VALUES (
        '{timestamp}',
        '{summary['table']}',
        {summary['total_issues']},
        {summary['errors']},
        {summary['warnings']},
        '{summary['status']}',
        '{str(summary['issues'])}'
    );
    """
    
    return sql


if __name__ == "__main__":
    # Example usage
    print("Data Quality Framework Module Loaded")
    print("Use this module to validate data before loading to analytics database")
