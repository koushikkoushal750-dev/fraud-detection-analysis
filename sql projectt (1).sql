-- ================================================================
--  FRAUD DETECTION ANALYSIS — FULL SQL PROJECT
--  Database: projectt
--
--  PROJECT SUMMARY (for recruiters / clients):
--  This project analyzes ~1,000,000 financial transactions across
--  50,000 accounts to detect fraud patterns, score account risk,
--  and uncover organized fraud rings using a 5-table relational
--  schema. It progresses from basic filtering to advanced window
--  functions, CTEs, views, stored procedures, and graph-style
--  self-joins — demonstrating the full SQL skill range used in
--  real-world fraud/risk analytics teams.
--
--  TABLES:
--   transactions        1,000,000 rows  (fact table)
--   account_profiles       50,000 rows  (dimension: per-account risk profile)
--   fraud_patterns               7 rows (lookup: fraud type definitions)
--   network_edges            7,411 rows (graph: shared-identifier links)
--   time_series_stats       26,280 rows (hourly rollup)
-- ================================================================

USE projectt;


-- ================================================================
-- SECTION 1 — BASIC QUERIES
-- Goal: get comfortable with the data — filtering, sorting, basic math
-- ================================================================

-- 1.1  How many transactions and accounts do we have in total?
--      (Simple COUNT — establishes the scale of the dataset)
SELECT
    (SELECT COUNT(*) FROM transactions)      AS total_transactions,
    (SELECT COUNT(*) FROM account_profiles)  AS total_accounts;

-- 1.2  What does a "typical" transaction look like?
--      (Basic aggregate stats — min/max/avg give a sanity-check baseline)
SELECT
    ROUND(MIN(amount), 2)  AS min_amount,
    ROUND(MAX(amount), 2)  AS max_amount,
    ROUND(AVG(amount), 2)  AS avg_amount
FROM transactions;

-- 1.3  Show the 10 largest transactions overall
--      (Simple ORDER BY + LIMIT)
SELECT transaction_id, account_id, amount, merchant_category, is_fraud
FROM transactions
ORDER BY amount DESC
LIMIT 10;

(WHERE with multiple conditions)
SELECT transaction_id, account_id, amount, merchant_country, is_fraud
FROM transactions
WHERE is_foreign_txn = 1 AND has_2fa = 0
LIMIT 20;


-- ================================================================
-- SECTION 2 — AGGREGATION (GROUP BY / HAVING)
-- ================================================================

-- 2.1  Overall fraud rate and financial exposure
--      Business question: "How big is our fraud problem, in money terms?"
SELECT
    COUNT(*)                                   AS total_transactions,
    SUM(is_fraud)                              AS fraud_transactions,
    ROUND(SUM(is_fraud) / COUNT(*) * 100, 3)   AS fraud_rate_pct,
    ROUND(SUM(amount), 2)                      AS total_volume,
    ROUND(SUM(CASE WHEN is_fraud = 1 THEN amount ELSE 0 END), 2) AS fraud_volume
FROM transactions;

-- 2.2  Fraud rate by merchant category and channel (card-present vs not)
--      Business question: "Which merchant types should get tighter controls?"
SELECT
    merchant_category,
    CASE WHEN card_present = 1 THEN 'Card Present' ELSE 'Card Not Present' END AS channel,
    COUNT(*)                                    AS txn_count,
    ROUND(AVG(is_fraud) * 100, 3)               AS fraud_rate_pct
FROM transactions
GROUP BY merchant_category, channel
HAVING txn_count > 500          -- HAVING filters on the aggregated result
ORDER BY fraud_rate_pct DESC
LIMIT 15;

-- 2.3  Fraud rate by hour of day and weekend flag
--      Business question: "When should fraud monitoring be most alert?"
SELECT
    hour_of_day,
    is_weekend,
    COUNT(*)                       AS txn_count,
    ROUND(AVG(is_fraud) * 100, 3)  AS fraud_rate_pct
FROM transactions
GROUP BY hour_of_day, is_weekend
ORDER BY fraud_rate_pct DESC
LIMIT 10;

-- 2.4  Does 2FA actually reduce fraud?
--      Business question: "Is our 2FA investment paying off?"
SELECT
    has_2fa,
    COUNT(*)                       AS txn_count,
    ROUND(AVG(is_fraud) * 100, 3)  AS fraud_rate_pct,
    ROUND(AVG(amount), 2)          AS avg_amount
FROM transactions
GROUP BY has_2fa;

-- 2.5  Segment accounts into risk tiers 
--      Business question: "How does fraud concentrate across risk tiers?"
SELECT
    CASE
        WHEN risk_score < 20 THEN '1. Low (0-20)'
        WHEN risk_score < 40 THEN '2. Medium (20-40)'
        WHEN risk_score < 60 THEN '3. High (40-60)'
        ELSE '4. Very High (60+)'
    END AS risk_tier,
    COUNT(*)                        AS account_count,
    ROUND(AVG(fraud_rate) * 100, 3) AS avg_fraud_rate_pct,
    ROUND(SUM(fraud_amount), 2)     AS total_fraud_amount
FROM account_profiles
GROUP BY risk_tier
ORDER BY risk_tier;

-- SECTION 3 — JOINS
-- Goal: combine the fact table with dimension/lookup tables


-- 3.1  INNER JOIN: fraud loss broken down by fraud pattern
--      Business question: "Which fraud *type* costs us the most money?"
SELECT
    fp.fraud_pattern,
    fp.description,
    COUNT(t.transaction_id)          AS txn_count,
    ROUND(AVG(t.amount), 2)          AS avg_amount,
    ROUND(SUM(t.amount), 2)          AS total_fraud_amount
FROM transactions t
JOIN fraud_patterns fp ON t.fraud_pattern = fp.fraud_pattern
WHERE t.is_fraud = 1
GROUP BY fp.fraud_pattern, fp.description
ORDER BY total_fraud_amount DESC;

-- 3.2  JOIN transactions to account_profiles: 
--      Business question: "Are known-bad accounts still transacting?"
SELECT
    t.transaction_id,
    t.account_id,
    t.amount,
    t.txn_timestamp,
    ap.risk_score,
    ap.fraud_rate AS account_historical_fraud_rate
FROM transactions t
JOIN account_profiles ap ON t.account_id = ap.account_id
WHERE ap.is_fraudster = 1
ORDER BY t.amount DESC
LIMIT 20;

-- 3.3  Accounts connected to a known fraudster 
--      Business question: "Who is one connection away from a fraudster?"
SELECT DISTINCT
    CASE WHEN ne.account_a = ap.account_id THEN ne.account_b ELSE ne.account_a END AS connected_account,
    ne.shared_type,
    ap.account_id AS fraudster_account
FROM network_edges ne
JOIN account_profiles ap
    ON ap.is_fraudster = 1
   AND ap.account_id IN (ne.account_a, ne.account_b)
LIMIT 50;

-- SECTION 4 — SUBQUERIES
-- Goal: use a query's result inside another query

-- 4.1  Accounts whose fraud rate is above the overall average
--      Business question: "Which accounts are worse than average?"
SELECT account_id, fraud_rate, total_transactions
FROM account_profiles
WHERE fraud_rate > (SELECT AVG(fraud_rate) FROM account_profiles)
ORDER BY fraud_rate DESC
LIMIT 20;

-- 4.2  Transactions larger than their own account's historical average
--      Business question: "Which single transactions look abnormal for that account?"
SELECT
    t.transaction_id,
    t.account_id,
    t.amount,
    (SELECT AVG(t2.amount) FROM transactions t2 WHERE t2.account_id = t.account_id) AS account_avg_amount
FROM transactions t
WHERE t.amount > (
    SELECT AVG(t2.amount) * 5
    FROM transactions t2
    WHERE t2.account_id = t.account_id
)
ORDER BY t.amount DESC
LIMIT 20;

-- SECTION 5 — CTEs (Common Table Expressions)

-- 5.1  CTE + JOIN: 
--      Business question: "Flag transactions that spike far above normal
--      spending behaviour for that account — a classic fraud signal."
WITH account_avg AS (
    SELECT account_id, AVG(amount) AS hist_avg_amount
    FROM transactions
    GROUP BY account_id
)
SELECT
    t.transaction_id,
    t.account_id,
    t.amount,
    a.hist_avg_amount,
    ROUND(t.amount / a.hist_avg_amount, 2) AS times_above_avg,
    t.is_fraud
FROM transactions t
JOIN account_avg a ON t.account_id = a.account_id
WHERE t.amount > a.hist_avg_amount * 5
ORDER BY times_above_avg DESC
LIMIT 20;

-- 5.2  Multi-step CTE: cohort analysis by account age
--      Business question: "Are newer accounts riskier than established ones?"
WITH cohort AS (
    SELECT
        CASE
            WHEN account_age_days < 30   THEN '1. New (<30 days)'
            WHEN account_age_days < 180  THEN '2. Recent (30-180 days)'
            WHEN account_age_days < 730  THEN '3. Established (6mo-2yr)'
            ELSE '4. Veteran (2yr+)'
        END AS account_age_cohort,
        account_id,
        is_fraud,
        amount
    FROM transactions
)
SELECT
    account_age_cohort,
    COUNT(DISTINCT account_id)      AS accounts_in_cohort,
    COUNT(*)                        AS txn_count,
    ROUND(AVG(is_fraud) * 100, 3)   AS fraud_rate_pct,
    ROUND(AVG(amount), 2)           AS avg_txn_amount
FROM cohort
GROUP BY account_age_cohort
ORDER BY account_age_cohort;

-- 5.3  CTE for fraud-ring detection: rings where EVERY connected
--      pair is confirmed fraud
--      Business question: "Which fraud rings should investigators prioritize?"
WITH ring_summary AS (
    SELECT
        ring_id,
        COUNT(*)                         AS edge_count,
        SUM(both_fraud)                  AS fraud_edge_count,
        COUNT(DISTINCT account_a) + COUNT(DISTINCT account_b) AS approx_accounts_involved
    FROM network_edges
    WHERE ring_id IS NOT NULL
    GROUP BY ring_id
)
SELECT *
FROM ring_summary
WHERE fraud_edge_count = edge_count
ORDER BY edge_count DESC;


-- SECTION 6 — WINDOW FUNCTIONS

-- 6.1  RANK():
--      Business question: "Who are the 3 top fraud suspects, country by country?"
SELECT *
FROM (
    SELECT
        account_id,
        home_country,
        fraud_amount,
        RANK() OVER (PARTITION BY home_country ORDER BY fraud_amount DESC) AS rank_in_country
    FROM account_profiles
    WHERE is_fraudster = 1
) ranked
WHERE rank_in_country <= 3
ORDER BY home_country, rank_in_country;

-- 6.2  
--      Business question: "Is fraud trending up or down over time?"
SELECT
    DATE(stat_hour)                                        AS day,
    SUM(transaction_count)                                 AS daily_txns,
    SUM(fraud_count)                                       AS daily_fraud,
    ROUND(
        AVG(SUM(fraud_count) / SUM(transaction_count) * 100)
        OVER (ORDER BY DATE(stat_hour) ROWS BETWEEN 6 PRECEDING AND CURRENT ROW),
    3) AS rolling_7day_fraud_rate_pct
FROM time_series_stats
GROUP BY DATE(stat_hour)
ORDER BY day;

-- 6.3  ROW_NUMBER() + PARTITION BY: 
--      Business question: "What's the biggest single transaction on each account?"
SELECT account_id, transaction_id, amount, txn_timestamp
FROM (
    SELECT
        account_id, transaction_id, amount, txn_timestamp,
        ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY amount DESC) AS rn
    FROM transactions
) ranked
WHERE rn = 1
ORDER BY amount DESC
LIMIT 20;

-- 6.4  LAG(): 
--      Business question: "Spot rapid-fire transactions (velocity fraud)."
SELECT
    account_id,
    transaction_id,
    txn_timestamp,
    LAG(txn_timestamp) OVER (PARTITION BY account_id ORDER BY txn_timestamp) AS prev_txn_time,
    TIMESTAMPDIFF(
        SECOND,
        LAG(txn_timestamp) OVER (PARTITION BY account_id ORDER BY txn_timestamp),
        txn_timestamp
    ) AS seconds_since_prev_txn
FROM transactions
WHERE account_id = 'ACC0000001'
ORDER BY txn_timestamp;


-- SECTION 7 — VIEWS (reusable, presentation-ready building blocks)

-- 7.1  Reusable fraud-pattern summary (eg. for a BI dashboard)
CREATE OR REPLACE VIEW vw_fraud_pattern_summary AS
SELECT
    fp.fraud_pattern,
    fp.description,
    COUNT(t.transaction_id)  AS txn_count,
    ROUND(AVG(t.amount), 2)  AS avg_amount,
    ROUND(SUM(t.amount), 2)  AS total_fraud_amount
FROM transactions t
JOIN fraud_patterns fp ON t.fraud_pattern = fp.fraud_pattern
WHERE t.is_fraud = 1
GROUP BY fp.fraud_pattern, fp.description;
-- usage: SELECT * FROM vw_fraud_pattern_summary ORDER BY total_fraud_amount DESC;

-- 7.2  High-risk account watchlist
CREATE OR REPLACE VIEW vw_high_risk_accounts AS
SELECT
    account_id, account_type, home_country, risk_score,
    total_transactions, fraud_count, fraud_amount, fraud_rate
FROM account_profiles
WHERE is_fraudster = 1 OR risk_score >= 60
ORDER BY fraud_amount DESC;
-- usage: SELECT * FROM vw_high_risk_accounts LIMIT 20;

-- 7.3  Daily fraud trend
CREATE OR REPLACE VIEW vw_daily_fraud_trend AS
SELECT
    DATE(stat_hour)          AS day,
    SUM(transaction_count)   AS daily_txns,
    SUM(fraud_count)         AS daily_fraud,
    ROUND(SUM(fraud_count) / SUM(transaction_count) * 100, 3) AS daily_fraud_rate_pct
FROM time_series_stats
GROUP BY DATE(stat_hour);
-- usage: SELECT * FROM vw_daily_fraud_trend ORDER BY day;


-- SECTION 8 — STORED PROCEDURES 

-- 8.1  Look up all transactions for a given account above a threshold
DELIMITER //
CREATE PROCEDURE sp_account_txns_above (
    IN p_account_id VARCHAR(20),
    IN p_min_amount DECIMAL(12,2)
)
BEGIN
    SELECT transaction_id, txn_timestamp, amount, merchant_category,
           is_fraud, fraud_pattern
    FROM transactions
    WHERE account_id = p_account_id
      AND amount >= p_min_amount
    ORDER BY txn_timestamp;
END //
DELIMITER ;
-- usage: CALL sp_account_txns_above('ACC0000001', 500);

-- 8.2  Fraud summary for any given date range (e.g. monthly reporting)
DELIMITER //
CREATE PROCEDURE sp_fraud_summary_by_range (
    IN p_start DATETIME,
    IN p_end DATETIME
)
BEGIN
    SELECT
        COUNT(*)                                  AS total_txns,
        SUM(is_fraud)                              AS fraud_txns,
        ROUND(SUM(is_fraud) / COUNT(*) * 100, 3)   AS fraud_rate_pct,
        ROUND(SUM(amount), 2)                      AS total_volume,
        ROUND(SUM(CASE WHEN is_fraud = 1 THEN amount ELSE 0 END), 2) AS fraud_volume
    FROM transactions
    WHERE txn_timestamp BETWEEN p_start AND p_end;
END //
DELIMITER ;
-- usage: CALL sp_fraud_summary_by_range('2023-01-01', '2023-01-31');


-- SECTION 9 — ADVANCED: UNION & GRAPH SELF-JOINS

-- 9.1  UNION:
--      Business question: "Give the fraud team one combined queue to review."
SELECT transaction_id, account_id, amount, velocity_1h, 'high_value' AS flag_reason
FROM transactions
WHERE is_fraud = 1 AND amount > 2000

UNION

SELECT transaction_id, account_id, amount, velocity_1h, 'high_velocity' AS flag_reason
FROM transactions
WHERE is_fraud = 1 AND velocity_1h >= 8

ORDER BY amount DESC
LIMIT 30;

-- 9.2  Self-join on network_edges:
--      Business question: "Who else might be part of this ring, indirectly?"
SELECT DISTINCT e2.account_b AS second_degree_account
FROM network_edges e1
JOIN network_edges e2
    ON (e1.account_b = e2.account_a OR e1.account_b = e2.account_b)
   AND e2.account_a != e1.account_a
WHERE e1.ring_id IS NOT NULL
  AND e2.account_b NOT IN (
      SELECT account_a FROM network_edges WHERE ring_id = e1.ring_id
      UNION
      SELECT account_b FROM network_edges WHERE ring_id = e1.ring_id
  )
LIMIT 50;


-- SECTION 10 — ROUNDING OUT THE TOOLKIT
-- LEFT JOIN | EXISTS/NOT EXISTS | DENSE_RANK/NTILE | Triggers |
-- User-defined function | INSERT/UPDATE/DELETE | EXPLAIN


-- 10.1  LEFT JOIN: 
--       Business question: "Which onboarded accounts have never transacted?"
SELECT
    ap.account_id,
    ap.account_type,
    ap.home_country,
    t.transaction_id
FROM account_profiles ap
LEFT JOIN transactions t ON ap.account_id = t.account_id
WHERE t.transaction_id IS NULL
LIMIT 20;

-- 10.2  EXISTS: accounts that have at least one fraudulent transaction
--       Business question: "Which accounts have ANY fraud history at all?"
SELECT ap.account_id, ap.account_type, ap.home_country
FROM account_profiles ap
WHERE EXISTS (
    SELECT 1 FROM transactions t
    WHERE t.account_id = ap.account_id AND t.is_fraud = 1
)
LIMIT 20;

-- 10.3  NOT EXISTS: 
--       Business question: "Which accounts are clean — safe to fast-track?"
SELECT ap.account_id, ap.account_type, ap.home_country
FROM account_profiles ap
WHERE NOT EXISTS (
    SELECT 1 FROM transactions t
    WHERE t.account_id = ap.account_id AND t.is_fraud = 1
)
LIMIT 20;

-- 10.4  DENSE_RANK():
--       Business question: "Give me a clean 1-2-3-4 leaderboard of fraud types."
SELECT
    fraud_pattern,
    total_fraud_amount,
    DENSE_RANK() OVER (ORDER BY total_fraud_amount DESC) AS loss_rank
FROM (
    SELECT fraud_pattern, SUM(amount) AS total_fraud_amount
    FROM transactions
    WHERE is_fraud = 1
    GROUP BY fraud_pattern
) t;

-- 10.5  NTILE(): 
--       Business question: "Which 25% of accounts carry the most fraud risk?"
SELECT
    account_id,
    fraud_rate,
    NTILE(4) OVER (ORDER BY fraud_rate DESC) AS risk_quartile
FROM account_profiles
ORDER BY fraud_rate DESC
LIMIT 20;

-- 10.6  User-defined function: reusable risk-label logic

DELIMITER //
CREATE FUNCTION fn_risk_label(p_risk_score DECIMAL(6,2))
RETURNS VARCHAR(20)
DETERMINISTIC
BEGIN
    DECLARE label VARCHAR(20);
    IF p_risk_score < 20 THEN SET label = 'Low';
    ELSEIF p_risk_score < 40 THEN SET label = 'Medium';
    ELSEIF p_risk_score < 60 THEN SET label = 'High';
    ELSE SET label = 'Very High';
    END IF;
    RETURN label;
END //
DELIMITER ;
-- usage: SELECT account_id, risk_score, fn_risk_label(risk_score) FROM account_profiles LIMIT 10;

-- 10.7  Trigger: auto-flag an account as high-risk the moment a fraudulent transaction over 5000 is inserted for it
--       Business question: "Update risk status automatically, no manual step."
DELIMITER //
CREATE TRIGGER trg_flag_high_risk_after_fraud
AFTER INSERT ON transactions
FOR EACH ROW
BEGIN
    IF NEW.is_fraud = 1 AND NEW.amount > 5000 THEN
        UPDATE account_profiles
        SET is_high_risk = 1
        WHERE account_id = NEW.account_id;
    END IF;
END //
DELIMITER ;

-- 10.8  Basic DML — INSERT / UPDATE / DELETE

-- INSERT a new transaction record
INSERT INTO transactions
(transaction_id, account_id, txn_timestamp, hour_of_day, day_of_week,
 is_weekend, amount, merchant_category, mcc_code, merchant_country,
 card_present, device_type, device_known, ip_risk_score, is_foreign_txn,
 time_since_last_s, velocity_1h, amount_vs_avg_ratio, account_age_days,
 has_2fa, credit_limit, is_fraud, fraud_pattern)
VALUES
('TXN999999999', 'ACC0000001', '2026-09-06 12:00:00', 12, 0, 0,
 250.00, 'online_retail', 5999, 'US', 0, 'web_browser', 1, 30.5, 0,
 60, 2, 1.10, 353, 1, 2171.42, 0, NULL);

-- UPDATE: correct a risk_score for one account
UPDATE account_profiles
SET risk_score = 18.0
WHERE account_id = 'ACC0000001';

-- DELETE: remove a specific bad/duplicate transaction
DELETE FROM transactions
WHERE transaction_id = 'TXN999999999';

-- 10.9  EXPLAIN: check how MySQL will execute a query (index usage,
--       scan type) — shows awareness of performance, not just syntax
--       Business question: "Is this query using our indexes efficiently?"
EXPLAIN
SELECT account_id, amount
FROM transactions
WHERE account_id = 'ACC0000001' AND is_fraud = 1;


-- END OF PROJECT
-- Recap of techniques demonstrated:
--   Basic SELECT/WHERE/ORDER BY/LIMIT | Aggregation (GROUP BY/HAVING)
--   CASE-based bucketing | INNER JOIN + LEFT JOIN across all 5 tables
--   Scalar, correlated, EXISTS/NOT EXISTS subqueries
--   CTEs (single and multi-step)
--   Window functions: RANK, DENSE_RANK, ROW_NUMBER, NTILE, LAG, AVG() OVER
--   Views for reusable reporting | Parameterized stored procedures
--   User-defined functions | Triggers | INSERT/UPDATE/DELETE | EXPLAIN
--   UNION | Self-joins for graph/network analysis
-- ================================================================
