"""Command-line maintenance tasks for HeatGuard.

Examples:
    python manage.py init-db
    python manage.py monitor-once
    python manage.py backfill --days 7
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone

import pymysql
from pymysql.constants import CLIENT

import config
from services import db
from services.heat_index import calculate_heat_index_c
from services.risk import classify_heat_index
from services.weather import WeatherAPIError, fetch_past_observations


def init_db() -> int:
    schema_path = config.BASE_DIR / "sql" / "schema.sql"
    schema_sql = schema_path.read_text(encoding="utf-8")
    try:
        connection = pymysql.connect(
            host=config.DB_CONFIG["host"],
            port=config.DB_CONFIG["port"],
            user=config.DB_CONFIG["user"],
            password=config.DB_CONFIG["password"],
            charset=config.DB_CONFIG["charset"],
            autocommit=True,
            client_flag=CLIENT.MULTI_STATEMENTS,
        )
    except pymysql.MySQLError as exc:
        print(f"Could not connect to MySQL: {exc}", file=sys.stderr)
        print(
            "Check DB_HOST, DB_PORT, DB_USER, and DB_PASSWORD in .env.",
            file=sys.stderr,
        )
        return 1

    try:
        with connection.cursor() as cursor:
            cursor.execute(schema_sql)
            while cursor.nextset():
                pass
    except pymysql.MySQLError as exc:
        print(f"Database initialisation failed: {exc}", file=sys.stderr)
        return 1
    finally:
        connection.close()

    print(
        f"Database '{config.DB_CONFIG['database']}' is ready with tables "
        "and default locations."
    )
    return 0


def monitor_once() -> int:
    from services.monitoring import run_monitoring_cycle

    results = run_monitoring_cycle()
    if not results:
        print("No monitoring results were produced.")
        return 1
    failures = 0
    for result in results:
        if result.get("ok"):
            print(
                f"[OK] location {result['location_id']}: "
                f"{result['temperature_c']} C, "
                f"{result['humidity_pct']}% RH, "
                f"HI {result['heat_index_c']} C, "
                f"{result['risk']['label']}"
            )
        else:
            failures += 1
            print(
                f"[ERROR] location {result['location_id']}: "
                f"{result.get('error')}",
                file=sys.stderr,
            )
    return 0 if failures < len(results) else 1


def backfill(days: int, location_id: int | None = None) -> int:
    try:
        locations = db.get_locations(active_only=True)
    except db.DatabaseError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if location_id is not None:
        locations = [item for item in locations if int(item["id"]) == location_id]
        if not locations:
            print(f"Location {location_id} was not found.", file=sys.stderr)
            return 1

    total = 0
    for location in locations:
        try:
            observations = fetch_past_observations(location, days=days)
        except WeatherAPIError as exc:
            print(f"{location['name']}: {exc}", file=sys.stderr)
            continue

        rows = []
        fetched_at = datetime.now(timezone.utc).replace(tzinfo=None)
        for observation in observations:
            heat_index_c = calculate_heat_index_c(
                observation["temperature_c"], observation["humidity_pct"]
            )
            risk = classify_heat_index(heat_index_c)
            rows.append(
                {
                    "observed_at": observation["observed_at"],
                    "fetched_at": fetched_at,
                    "temperature_c": observation["temperature_c"],
                    "humidity_pct": observation["humidity_pct"],
                    "heat_index_c": heat_index_c,
                    "risk_key": risk["key"],
                    "risk_label": risk["label"],
                    "source": observation["source"],
                    "api_timezone": observation.get("api_timezone"),
                }
            )

        inserted = db.insert_historical_readings(int(location["id"]), rows)
        total += inserted
        print(
            f"{location['name']}: stored {inserted} historical hourly "
            f"readings from the last {days} day(s)."
        )

    print(f"Backfill complete: {total} new rows.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="HeatGuard maintenance")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("init-db", help="Create database, tables, and seeds")

    subparsers.add_parser(
        "monitor-once", help="Fetch and store one reading for every location"
    )

    backfill_parser = subparsers.add_parser(
        "backfill", help="Fill charts with recent historical hourly data"
    )
    backfill_parser.add_argument(
        "--days", type=int, default=7, help="Number of past days (1-92)"
    )
    backfill_parser.add_argument(
        "--location", type=int, default=None, help="Optional location id"
    )

    args = parser.parse_args()

    if args.command == "init-db":
        return init_db()
    if args.command == "monitor-once":
        return monitor_once()
    if args.command == "backfill":
        return backfill(args.days, args.location)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
