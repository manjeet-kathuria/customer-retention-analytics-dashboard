"""
Project 4: Customer Retention and Churn Analytics

This script reads the PostgreSQL churn views, creates retention KPI outputs,
and exports Power BI-ready CSV files.
"""

from pathlib import Path
import os

import pandas as pd
from sqlalchemy import create_engine


PROJECT_DIR = Path(__file__).resolve().parents[1]
OUTPUT_DIR = PROJECT_DIR / "outputs"


def build_database_url() -> str:
    """Build the PostgreSQL connection string from environment variables."""
    user = os.getenv("PGUSER", "postgres")
    password = os.getenv("PGPASSWORD", "NewPassword123")
    host = os.getenv("PGHOST", "localhost")
    port = os.getenv("PGPORT", "5432")
    database = os.getenv("PGDATABASE", "retail_analytics")

    return f"postgresql+psycopg2://{user}:{password}@{host}:{port}/{database}"


def read_view(engine, view_name: str) -> pd.DataFrame:
    """Read a database view into a pandas DataFrame."""
    query = f"SELECT * FROM {view_name}"
    return pd.read_sql(query, engine)


def add_priority_rank(customer_detail: pd.DataFrame) -> pd.DataFrame:
    """Rank customers for retention outreach."""
    df = customer_detail.copy()

    df["retention_priority_score"] = (
        df["churn_risk_score"].fillna(0) * 0.55
        + df["lifetime_sales"].rank(pct=True).fillna(0) * 30
        + df["lifetime_profit"].rank(pct=True).fillna(0) * 15
    ).round(2)

    df["retention_priority_rank"] = (
        df["retention_priority_score"]
        .rank(method="dense", ascending=False)
        .astype(int)
    )

    df["priority_group"] = pd.cut(
        df["retention_priority_rank"],
        bins=[0, 25, 75, float("inf")],
        labels=["Top 25", "Next 50", "Long Tail"],
        include_lowest=True,
    )

    return df.sort_values(
        ["retention_priority_rank", "lifetime_sales"],
        ascending=[True, False],
    )


def build_retention_action_summary(customer_detail: pd.DataFrame) -> pd.DataFrame:
    """Summarize customers and revenue by recommended action."""
    summary = (
        customer_detail
        .groupby("recommended_retention_action", dropna=False)
        .agg(
            customer_count=("customer_id", "nunique"),
            lifetime_sales=("lifetime_sales", "sum"),
            lifetime_profit=("lifetime_profit", "sum"),
            avg_churn_risk_score=("churn_risk_score", "mean"),
            avg_days_since_last_order=("days_since_last_order", "mean"),
        )
        .reset_index()
    )

    summary["lifetime_sales"] = summary["lifetime_sales"].round(2)
    summary["lifetime_profit"] = summary["lifetime_profit"].round(2)
    summary["avg_churn_risk_score"] = summary["avg_churn_risk_score"].round(2)
    summary["avg_days_since_last_order"] = summary["avg_days_since_last_order"].round(2)

    return summary.sort_values(
        "avg_churn_risk_score",
        ascending=False,
    )


def build_retention_matrix(monthly_retention: pd.DataFrame) -> pd.DataFrame:
    """Create a cohort retention matrix for Power BI heatmaps."""
    matrix = monthly_retention.pivot_table(
        index="cohort_month",
        columns="cohort_period_month",
        values="retention_rate_pct",
        aggfunc="max",
    ).reset_index()

    matrix.columns = [
        "cohort_month" if col == "cohort_month" else f"month_{int(col)}"
        for col in matrix.columns
    ]

    return matrix


def export_dataframe(df: pd.DataFrame, file_name: str) -> Path:
    """Export a DataFrame to the project outputs folder."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    output_path = OUTPUT_DIR / file_name
    df.to_csv(output_path, index=False)
    return output_path


def main() -> None:
    engine = create_engine(build_database_url())

    customer_detail = read_view(engine, "vw_churn_powerbi_customer_detail")
    segment_summary = read_view(engine, "vw_churn_powerbi_segment_summary")
    monthly_kpis = read_view(engine, "vw_churn_powerbi_monthly_kpis")
    monthly_retention = read_view(engine, "vw_churn_monthly_retention")
    kpi_summary = read_view(engine, "vw_churn_kpi_summary")

    customer_detail_ranked = add_priority_rank(customer_detail)
    action_summary = build_retention_action_summary(customer_detail_ranked)
    retention_matrix = build_retention_matrix(monthly_retention)

    exports = {
        "churn_customer_detail.csv": customer_detail_ranked,
        "churn_segment_summary.csv": segment_summary,
        "churn_monthly_kpis.csv": monthly_kpis,
        "churn_monthly_retention.csv": monthly_retention,
        "churn_retention_matrix.csv": retention_matrix,
        "churn_action_summary.csv": action_summary,
        "churn_kpi_summary.csv": kpi_summary,
    }

    print("Project 4 churn analytics export started.")
    for file_name, dataframe in exports.items():
        output_path = export_dataframe(dataframe, file_name)
        print(f"Exported {len(dataframe):,} rows -> {output_path}")

    print("\nExecutive KPI snapshot:")
    print(kpi_summary.to_string(index=False))
    print("\nTop 10 retention priorities:")
    print(
        customer_detail_ranked[
            [
                "retention_priority_rank",
                "customer_name",
                "churn_risk_band",
                "inactivity_status",
                "days_since_last_order",
                "lifetime_sales",
                "recommended_retention_action",
            ]
        ]
        .head(10)
        .to_string(index=False)
    )


if __name__ == "__main__":
    main()

