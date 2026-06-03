-- ============================================================
-- PROJECT 4: CUSTOMER RETENTION AND CHURN ANALYTICS
-- PostgreSQL views for inactivity, churn risk, retention KPIs,
-- and Power BI-ready reporting tables.
--
-- Dependency:
--   orders_clean table created from orders_raw
-- ============================================================


-- ============================================================
-- 1. CUSTOMER CHURN BASE VIEW
-- Customer lifetime metrics and inactivity calculations.
-- The analysis date is the latest order date in the dataset so
-- historical sample data remains stable and reproducible.
-- ============================================================

CREATE OR REPLACE VIEW vw_churn_customer_base AS
WITH analysis_params AS (
    SELECT MAX(order_date) AS analysis_date
    FROM orders_clean
),
order_sequence AS (
    SELECT
        customer_id,
        order_id,
        order_date,
        LAG(order_date) OVER (
            PARTITION BY customer_id
            ORDER BY order_date, order_id
        ) AS previous_order_date
    FROM orders_clean
),
customer_order_gaps AS (
    SELECT
        customer_id,
        ROUND(AVG(order_date - previous_order_date)::numeric, 2) AS avg_days_between_orders
    FROM order_sequence
    WHERE previous_order_date IS NOT NULL
    GROUP BY customer_id
),
customer_lifetime AS (
    SELECT
        customer_id,
        customer_name,
        MIN(order_date) AS first_order_date,
        MAX(order_date) AS last_order_date,
        COUNT(DISTINCT order_id) AS total_orders,
        COUNT(DISTINCT order_date) AS active_order_days,
        ROUND(SUM(sales)::numeric, 2) AS lifetime_sales,
        ROUND(SUM(profit)::numeric, 2) AS lifetime_profit,
        ROUND(AVG(sales)::numeric, 2) AS avg_line_sales,
        ROUND(
            SUM(sales)::numeric / NULLIF(COUNT(DISTINCT order_id), 0),
            2
        ) AS avg_order_value,
        ROUND(
            SUM(profit)::numeric / NULLIF(SUM(sales)::numeric, 0) * 100,
            2
        ) AS profit_margin_pct
    FROM orders_clean
    GROUP BY
        customer_id,
        customer_name
)
SELECT
    cl.customer_id,
    cl.customer_name,
    ap.analysis_date,
    cl.first_order_date,
    cl.last_order_date,
    (cl.last_order_date - cl.first_order_date) AS customer_lifespan_days,
    (ap.analysis_date - cl.last_order_date) AS days_since_last_order,
    cl.total_orders,
    cl.active_order_days,
    cl.lifetime_sales,
    cl.lifetime_profit,
    cl.avg_line_sales,
    cl.avg_order_value,
    cl.profit_margin_pct,
    COALESCE(cog.avg_days_between_orders, 90.00) AS avg_days_between_orders,
    CASE
        WHEN cl.total_orders = 1 THEN 90
        ELSE GREATEST(ROUND((COALESCE(cog.avg_days_between_orders, 90) * 1.5)::numeric, 0), 30)
    END AS expected_reorder_days,
    ROUND(
        (ap.analysis_date - cl.last_order_date)::numeric /
        NULLIF(
            CASE
                WHEN cl.total_orders = 1 THEN 90
                ELSE GREATEST(ROUND((COALESCE(cog.avg_days_between_orders, 90) * 1.5)::numeric, 0), 30)
            END,
            0
        ),
        2
    ) AS inactivity_ratio,
    CASE
        WHEN cl.total_orders = 1 THEN 'One-Time Customer'
        WHEN cl.total_orders BETWEEN 2 AND 5 THEN 'Repeat Customer'
        WHEN cl.total_orders > 5 THEN 'Loyal Customer'
        ELSE 'Unknown'
    END AS customer_segment
FROM customer_lifetime cl
CROSS JOIN analysis_params ap
LEFT JOIN customer_order_gaps cog
    ON cl.customer_id = cog.customer_id;


-- ============================================================
-- 2. CUSTOMER PERIOD ACTIVITY VIEW
-- Compares recent customer behavior with the previous period.
-- ============================================================

CREATE OR REPLACE VIEW vw_churn_customer_period_activity AS
WITH analysis_params AS (
    SELECT MAX(order_date) AS analysis_date
    FROM orders_clean
)
SELECT
    o.customer_id,
    o.customer_name,
    COUNT(DISTINCT CASE
        WHEN o.order_date >= ap.analysis_date - INTERVAL '90 days'
        THEN o.order_id
    END) AS orders_last_90_days,
    COUNT(DISTINCT CASE
        WHEN o.order_date >= ap.analysis_date - INTERVAL '180 days'
         AND o.order_date < ap.analysis_date - INTERVAL '90 days'
        THEN o.order_id
    END) AS orders_previous_90_days,
    ROUND(SUM(CASE
        WHEN o.order_date >= ap.analysis_date - INTERVAL '90 days'
        THEN o.sales
        ELSE 0
    END)::numeric, 2) AS sales_last_90_days,
    ROUND(SUM(CASE
        WHEN o.order_date >= ap.analysis_date - INTERVAL '180 days'
         AND o.order_date < ap.analysis_date - INTERVAL '90 days'
        THEN o.sales
        ELSE 0
    END)::numeric, 2) AS sales_previous_90_days,
    ROUND(SUM(CASE
        WHEN o.order_date >= ap.analysis_date - INTERVAL '90 days'
        THEN o.profit
        ELSE 0
    END)::numeric, 2) AS profit_last_90_days,
    ROUND(SUM(CASE
        WHEN o.order_date >= ap.analysis_date - INTERVAL '180 days'
         AND o.order_date < ap.analysis_date - INTERVAL '90 days'
        THEN o.profit
        ELSE 0
    END)::numeric, 2) AS profit_previous_90_days,
    COUNT(DISTINCT CASE
        WHEN o.order_date >= ap.analysis_date - INTERVAL '365 days'
        THEN o.order_id
    END) AS orders_last_12_months,
    ROUND(SUM(CASE
        WHEN o.order_date >= ap.analysis_date - INTERVAL '365 days'
        THEN o.sales
        ELSE 0
    END)::numeric, 2) AS sales_last_12_months
FROM orders_clean o
CROSS JOIN analysis_params ap
GROUP BY
    o.customer_id,
    o.customer_name;


-- ============================================================
-- 3. CUSTOMER BEHAVIOR TREND VIEW
-- Detects declining, inactive, growing, and stable behavior.
-- ============================================================

CREATE OR REPLACE VIEW vw_churn_customer_behavior_trend AS
SELECT
    customer_id,
    customer_name,
    orders_last_90_days,
    orders_previous_90_days,
    sales_last_90_days,
    sales_previous_90_days,
    profit_last_90_days,
    profit_previous_90_days,
    orders_last_12_months,
    sales_last_12_months,
    ROUND(
        (orders_last_90_days - orders_previous_90_days)::numeric /
        NULLIF(orders_previous_90_days, 0) * 100,
        2
    ) AS order_change_pct,
    ROUND(
        (sales_last_90_days - sales_previous_90_days)::numeric /
        NULLIF(sales_previous_90_days, 0) * 100,
        2
    ) AS sales_change_pct,
    ROUND(
        (profit_last_90_days - profit_previous_90_days)::numeric /
        NULLIF(profit_previous_90_days, 0) * 100,
        2
    ) AS profit_change_pct,
    CASE
        WHEN orders_last_90_days = 0
         AND orders_previous_90_days > 0
            THEN 'Recently Inactive'
        WHEN sales_previous_90_days > 0
         AND (sales_last_90_days - sales_previous_90_days)::numeric /
             NULLIF(sales_previous_90_days, 0) <= -0.50
            THEN 'Sharp Decline'
        WHEN sales_previous_90_days > 0
         AND (sales_last_90_days - sales_previous_90_days)::numeric /
             NULLIF(sales_previous_90_days, 0) <= -0.20
            THEN 'Declining'
        WHEN sales_previous_90_days > 0
         AND (sales_last_90_days - sales_previous_90_days)::numeric /
             NULLIF(sales_previous_90_days, 0) >= 0.20
            THEN 'Growing'
        WHEN sales_last_90_days > 0
         AND sales_previous_90_days = 0
            THEN 'New or Reactivated'
        ELSE 'Stable'
    END AS behavior_trend
FROM vw_churn_customer_period_activity;


-- ============================================================
-- 4. CHURN RISK INDICATORS VIEW
-- Combines inactivity, trend, value, and profitability into a
-- churn-risk score and recommended retention action.
-- ============================================================

CREATE OR REPLACE VIEW vw_churn_risk_indicators AS
WITH scored_customers AS (
    SELECT
        b.customer_id,
        b.customer_name,
        b.analysis_date,
        b.first_order_date,
        b.last_order_date,
        b.customer_lifespan_days,
        b.days_since_last_order,
        b.expected_reorder_days,
        b.inactivity_ratio,
        b.total_orders,
        b.active_order_days,
        b.lifetime_sales,
        b.lifetime_profit,
        b.avg_order_value,
        b.profit_margin_pct,
        b.customer_segment,
        t.orders_last_90_days,
        t.orders_previous_90_days,
        t.sales_last_90_days,
        t.sales_previous_90_days,
        t.profit_last_90_days,
        t.sales_change_pct,
        t.profit_change_pct,
        t.behavior_trend,
        (
            CASE
                WHEN b.days_since_last_order > 180 THEN 40
                WHEN b.days_since_last_order BETWEEN 91 AND 180 THEN 30
                WHEN b.days_since_last_order BETWEEN 61 AND 90 THEN 20
                WHEN b.days_since_last_order BETWEEN 31 AND 60 THEN 10
                ELSE 0
            END
            +
            CASE
                WHEN b.inactivity_ratio >= 2.00 THEN 25
                WHEN b.inactivity_ratio >= 1.50 THEN 15
                WHEN b.inactivity_ratio >= 1.00 THEN 10
                ELSE 0
            END
            +
            CASE
                WHEN t.behavior_trend = 'Sharp Decline' THEN 20
                WHEN t.behavior_trend IN ('Declining', 'Recently Inactive') THEN 15
                ELSE 0
            END
            +
            CASE
                WHEN t.orders_last_90_days = 0 THEN 10
                ELSE 0
            END
            +
            CASE
                WHEN b.total_orders = 1 THEN 10
                ELSE 0
            END
            +
            CASE
                WHEN t.profit_last_90_days < 0 THEN 5
                ELSE 0
            END
        ) AS churn_risk_score
    FROM vw_churn_customer_base b
    LEFT JOIN vw_churn_customer_behavior_trend t
        ON b.customer_id = t.customer_id
)
SELECT
    customer_id,
    customer_name,
    analysis_date,
    first_order_date,
    last_order_date,
    customer_lifespan_days,
    days_since_last_order,
    expected_reorder_days,
    inactivity_ratio,
    total_orders,
    active_order_days,
    lifetime_sales,
    lifetime_profit,
    avg_order_value,
    profit_margin_pct,
    customer_segment,
    orders_last_90_days,
    orders_previous_90_days,
    sales_last_90_days,
    sales_previous_90_days,
    profit_last_90_days,
    sales_change_pct,
    profit_change_pct,
    behavior_trend,
    churn_risk_score,
    CASE
        WHEN churn_risk_score >= 80 THEN 'Critical Risk'
        WHEN churn_risk_score >= 60 THEN 'High Risk'
        WHEN churn_risk_score >= 40 THEN 'Medium Risk'
        WHEN churn_risk_score >= 20 THEN 'Low Risk'
        ELSE 'Healthy'
    END AS churn_risk_band,
    CASE
        WHEN days_since_last_order <= 30 THEN 'Active'
        WHEN days_since_last_order BETWEEN 31 AND 60 THEN 'Watch'
        WHEN days_since_last_order BETWEEN 61 AND 90 THEN 'At Risk'
        WHEN days_since_last_order BETWEEN 91 AND 180 THEN 'Inactive'
        ELSE 'Churned'
    END AS inactivity_status,
    CASE
        WHEN churn_risk_score >= 60
          OR days_since_last_order > 180
            THEN 1
        ELSE 0
    END AS churn_flag,
    CASE
        WHEN behavior_trend IN ('Sharp Decline', 'Declining', 'Recently Inactive')
            THEN 1
        ELSE 0
    END AS declining_behavior_flag,
    CASE
        WHEN churn_risk_score >= 80
            THEN 'Immediate win-back outreach'
        WHEN churn_risk_score >= 60
            THEN 'Targeted retention offer'
        WHEN churn_risk_score >= 40
            THEN 'Monitor and re-engage'
        WHEN churn_risk_score >= 20
            THEN 'Light-touch nurture'
        ELSE 'Maintain relationship'
    END AS recommended_retention_action
FROM scored_customers;


-- ============================================================
-- 5. CHURN KPI SUMMARY VIEW
-- One-row executive KPI layer for dashboard cards.
-- ============================================================

CREATE OR REPLACE VIEW vw_churn_kpi_summary AS
SELECT
    COUNT(DISTINCT customer_id) AS total_customers,
    COUNT(DISTINCT CASE
        WHEN inactivity_status = 'Active'
        THEN customer_id
    END) AS active_customers,
    COUNT(DISTINCT CASE
        WHEN inactivity_status IN ('Watch', 'At Risk')
        THEN customer_id
    END) AS customers_to_watch,
    COUNT(DISTINCT CASE
        WHEN inactivity_status IN ('Inactive', 'Churned')
        THEN customer_id
    END) AS inactive_or_churned_customers,
    COUNT(DISTINCT CASE
        WHEN churn_risk_band IN ('High Risk', 'Critical Risk')
        THEN customer_id
    END) AS high_risk_customers,
    COUNT(DISTINCT CASE
        WHEN churn_flag = 1
        THEN customer_id
    END) AS churned_customers,
    ROUND(
        COUNT(DISTINCT CASE WHEN churn_flag = 1 THEN customer_id END)::numeric /
        NULLIF(COUNT(DISTINCT customer_id), 0) * 100,
        2
    ) AS churn_rate_pct,
    ROUND(SUM(lifetime_sales)::numeric, 2) AS total_lifetime_sales,
    ROUND(SUM(CASE
        WHEN churn_risk_band IN ('High Risk', 'Critical Risk')
        THEN lifetime_sales
        ELSE 0
    END)::numeric, 2) AS revenue_at_high_risk,
    ROUND(
        SUM(CASE
            WHEN churn_risk_band IN ('High Risk', 'Critical Risk')
            THEN lifetime_sales
            ELSE 0
        END)::numeric / NULLIF(SUM(lifetime_sales)::numeric, 0) * 100,
        2
    ) AS revenue_at_high_risk_pct,
    ROUND(AVG(days_since_last_order)::numeric, 2) AS avg_days_since_last_order,
    ROUND(AVG(churn_risk_score)::numeric, 2) AS avg_churn_risk_score
FROM vw_churn_risk_indicators;


-- ============================================================
-- 6. MONTHLY RETENTION COHORT VIEW
-- Cohort retention by first purchase month and activity month.
-- ============================================================

CREATE OR REPLACE VIEW vw_churn_monthly_retention AS
WITH first_purchase AS (
    SELECT
        customer_id,
        MIN(DATE_TRUNC('month', order_date)::date) AS cohort_month
    FROM orders_clean
    GROUP BY customer_id
),
monthly_activity AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', order_date)::date AS activity_month
    FROM orders_clean
    GROUP BY
        customer_id,
        DATE_TRUNC('month', order_date)::date
),
cohort_activity AS (
    SELECT
        fp.cohort_month,
        ma.activity_month,
        (
            (EXTRACT(YEAR FROM ma.activity_month) - EXTRACT(YEAR FROM fp.cohort_month)) * 12
            +
            (EXTRACT(MONTH FROM ma.activity_month) - EXTRACT(MONTH FROM fp.cohort_month))
        )::int AS cohort_period_month,
        COUNT(DISTINCT ma.customer_id) AS active_customers
    FROM first_purchase fp
    JOIN monthly_activity ma
        ON fp.customer_id = ma.customer_id
    GROUP BY
        fp.cohort_month,
        ma.activity_month
),
cohort_sizes AS (
    SELECT
        cohort_month,
        COUNT(DISTINCT customer_id) AS cohort_customers
    FROM first_purchase
    GROUP BY cohort_month
)
SELECT
    ca.cohort_month,
    ca.activity_month,
    ca.cohort_period_month,
    cs.cohort_customers,
    ca.active_customers AS retained_customers,
    (cs.cohort_customers - ca.active_customers) AS inactive_from_cohort,
    ROUND(
        ca.active_customers::numeric / NULLIF(cs.cohort_customers, 0) * 100,
        2
    ) AS retention_rate_pct
FROM cohort_activity ca
JOIN cohort_sizes cs
    ON ca.cohort_month = cs.cohort_month;


-- ============================================================
-- 7. POWER BI CUSTOMER DETAIL VIEW
-- Customer-level table with latest customer attributes.
-- ============================================================

CREATE OR REPLACE VIEW vw_churn_powerbi_customer_detail AS
WITH latest_customer_profile AS (
    SELECT
        customer_id,
        segment,
        region,
        state,
        city,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY order_date DESC, order_id DESC
        ) AS row_num
    FROM orders_clean
)
SELECT
    r.customer_id,
    r.customer_name,
    p.segment,
    p.region,
    p.state,
    p.city,
    r.analysis_date,
    r.first_order_date,
    r.last_order_date,
    r.days_since_last_order,
    r.expected_reorder_days,
    r.inactivity_ratio,
    r.total_orders,
    r.lifetime_sales,
    r.lifetime_profit,
    r.avg_order_value,
    r.profit_margin_pct,
    r.customer_segment,
    r.orders_last_90_days,
    r.sales_last_90_days,
    r.sales_previous_90_days,
    r.sales_change_pct,
    r.behavior_trend,
    r.churn_risk_score,
    r.churn_risk_band,
    r.inactivity_status,
    r.churn_flag,
    r.declining_behavior_flag,
    r.recommended_retention_action
FROM vw_churn_risk_indicators r
LEFT JOIN latest_customer_profile p
    ON r.customer_id = p.customer_id
   AND p.row_num = 1;


-- ============================================================
-- 8. POWER BI SEGMENT SUMMARY VIEW
-- Aggregated view for risk, segment, and retention dashboards.
-- ============================================================

CREATE OR REPLACE VIEW vw_churn_powerbi_segment_summary AS
SELECT
    customer_segment,
    churn_risk_band,
    inactivity_status,
    recommended_retention_action,
    COUNT(DISTINCT customer_id) AS customer_count,
    ROUND(SUM(lifetime_sales)::numeric, 2) AS lifetime_sales,
    ROUND(SUM(lifetime_profit)::numeric, 2) AS lifetime_profit,
    ROUND(AVG(days_since_last_order)::numeric, 2) AS avg_days_since_last_order,
    ROUND(AVG(churn_risk_score)::numeric, 2) AS avg_churn_risk_score,
    ROUND(AVG(inactivity_ratio)::numeric, 2) AS avg_inactivity_ratio
FROM vw_churn_risk_indicators
GROUP BY
    customer_segment,
    churn_risk_band,
    inactivity_status,
    recommended_retention_action;


-- ============================================================
-- 9. POWER BI MONTHLY CUSTOMER KPI VIEW
-- Monthly active, new, repeat, and reactivated customers.
-- ============================================================

CREATE OR REPLACE VIEW vw_churn_powerbi_monthly_kpis AS
WITH customer_months AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', order_date)::date AS order_month,
        COUNT(DISTINCT order_id) AS monthly_orders,
        ROUND(SUM(sales)::numeric, 2) AS monthly_sales,
        ROUND(SUM(profit)::numeric, 2) AS monthly_profit
    FROM orders_clean
    GROUP BY
        customer_id,
        DATE_TRUNC('month', order_date)::date
),
customer_month_history AS (
    SELECT
        cm.*,
        MIN(order_month) OVER (
            PARTITION BY customer_id
        ) AS first_order_month,
        LAG(order_month) OVER (
            PARTITION BY customer_id
            ORDER BY order_month
        ) AS previous_order_month
    FROM customer_months cm
)
SELECT
    order_month,
    COUNT(DISTINCT customer_id) AS active_customers,
    COUNT(DISTINCT CASE
        WHEN order_month = first_order_month
        THEN customer_id
    END) AS new_customers,
    COUNT(DISTINCT CASE
        WHEN order_month > first_order_month
        THEN customer_id
    END) AS repeat_customers,
    COUNT(DISTINCT CASE
        WHEN previous_order_month IS NOT NULL
         AND order_month > previous_order_month + INTERVAL '90 days'
        THEN customer_id
    END) AS reactivated_customers,
    SUM(monthly_orders) AS total_orders,
    ROUND(SUM(monthly_sales)::numeric, 2) AS total_sales,
    ROUND(SUM(monthly_profit)::numeric, 2) AS total_profit
FROM customer_month_history
GROUP BY order_month;


-- ============================================================
-- QUICK VALIDATION QUERIES
-- Run these after creating the views.
-- ============================================================

SELECT *
FROM vw_churn_kpi_summary;

SELECT *
FROM vw_churn_risk_indicators
ORDER BY churn_risk_score DESC, lifetime_sales DESC
LIMIT 20;

SELECT *
FROM vw_churn_powerbi_segment_summary
ORDER BY avg_churn_risk_score DESC;

