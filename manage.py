"""Command-line maintenance tasks for HeatGuard.

Examples:
    python manage.py init-db
    python manage.py monitor-once
    python manage.py backfill --days 7
    python manage.py validate-pagasa
    python manage.py validate-pagasa --json
"""

from __future__ import annotations

import argparse
import json
import re
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


def init_mobile_auth() -> int:
    """Add only the account tables; leave existing locations and readings intact."""
    migration_path = config.BASE_DIR / "sql" / "mobile_accounts.sql"
    if migration_path.is_file():
        migration = migration_path.read_text(encoding="utf-8")
    else:
        # The full schema also supports repositories that keep a single SQL source.
        schema = (config.BASE_DIR / "sql" / "schema.sql").read_text(encoding="utf-8")
        migration = ";".join(statement for statement in schema.split(";") if re.search(
            r"CREATE TABLE IF NOT EXISTS `?(?:mobile_users|mobile_registration_challenges|mobile_user_sessions)`?\s*\(", statement))
    try:
        with db.connection() as conn:
            with conn.cursor() as cursor:
                for statement in migration.split(";"):
                    if statement.strip():
                        cursor.execute(statement)
    except (db.DatabaseError, pymysql.MySQLError):
        print("Could not create the mobile account tables. Check MySQL and the database permissions.", file=sys.stderr)
        return 1
    print("Mobile account, verification, and session tables are ready.")
    return 0


def init_mobile_routines() -> int:
    if init_mobile_auth() != 0:
        return 1
    migration = (config.BASE_DIR / "sql" / "mobile_routines.sql").read_text(encoding="utf-8")
    try:
        with db.connection() as conn:
            with conn.cursor() as cursor:
                for statement in migration.split(";"):
                    if statement.strip():
                        cursor.execute(statement)
                # CREATE TABLE leaves existing installations unchanged. Add the
                # timing fields once without replacing any routines or history.
                for table, column in (("mobile_notifications", "scheduled_for"),
                                      ("mobile_notifications", "prepared_at"),
                                      ("mobile_notification_deliveries", "sent_at")):
                    cursor.execute("SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=%s AND COLUMN_NAME=%s", (table, column))
                    if not cursor.fetchone():
                        cursor.execute(f"ALTER TABLE {table} ADD COLUMN {column} DATETIME NULL")
    except (db.DatabaseError, pymysql.MySQLError):
        print("Could not create routine tables. Check MySQL and database permissions.", file=sys.stderr)
        return 1
    print("Personal routine, notification inbox, and push delivery tables are ready.")
    from services import private_locations
    migration = (config.BASE_DIR / "sql" / "mobile_locations.sql").read_text(encoding="utf-8")
    try:
        with db.connection() as conn:
            with conn.cursor() as cursor:
                for statement in migration.split(";"):
                    if statement.strip():
                        cursor.execute(statement)
        private_locations.migrate_routine_locations()
    except (db.DatabaseError, pymysql.MySQLError, ValueError):
        print("Could not create private addresses. Check MySQL and database permissions.", file=sys.stderr)
        return 1
    print("Private mobile addresses are ready; legacy routine addresses have been preserved.")
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


def validate_pagasa(as_json: bool = False, timeout: int = 20) -> int:
    from services.pagasa_validation import (
        PAGASAValidationError,
        fetch_and_validate,
    )

    try:
        report = fetch_and_validate(timeout=timeout)
    except PAGASAValidationError as exc:
        print(f"Validation failed: {exc}", file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0

    metrics = report["metrics"]
    agreement = report["category_agreement"]
    print("PAGASA heat-index validation")
    print(f"  Stations parsed:       {report['station_count']}")
    print(f"  Stations compared:     {report['compared_station_count']}")
    print(f"  Skipped:               {report['skipped_station_count']}")
    print(f"  Mean absolute error:   {metrics['mae_c']} C")
    print(f"  RMSE:                  {metrics['rmse_c']} C")
    print(f"  Mean bias:             {metrics['bias_c']} C")
    print(f"  Within 1 C:            {metrics['within_1c_pct']}%")
    print(f"  Within 2 C:            {metrics['within_2c_pct']}%")
    print(
        "  Category agreement:    "
        f"{agreement['agreement_pct']}% "
        f"({agreement['matches']}/{agreement['total']})"
    )
    print("\n  Largest deviations:")
    for item in report["largest_deviations"]:
        print(
            f"  - {item['station']}: PAGASA {item['reported_heat_index_c']} C, "
            f"HeatGuard {item['calculated_heat_index_c']} C, "
            f"difference {item['difference_c']:+.2f} C"
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="HeatGuard maintenance")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("init-db", help="Create database, tables, and seeds")
    subparsers.add_parser("init-mobile-auth", help="Add verified mobile accounts to an existing database")
    subparsers.add_parser("init-mobile-routines", help="Add personal routines and notification tables")
    subparsers.add_parser("init-mobile-locations", help="Add private mobile addresses and migrate routine locations")

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

    validation_parser = subparsers.add_parser(
        "validate-pagasa",
        help="Compare HeatGuard's heat index with PAGASA station data",
    )
    validation_parser.add_argument(
        "--json", action="store_true", help="Print the full report as JSON"
    )
    validation_parser.add_argument(
        "--timeout", type=int, default=20, help="Request timeout in seconds"
    )

    args = parser.parse_args()

    if args.command == "init-db":
        return init_db()
    if args.command == "init-mobile-auth":
        return init_mobile_auth()
    if args.command in {"init-mobile-routines", "init-mobile-locations"}:
        return init_mobile_routines()
    if args.command == "monitor-once":
        return monitor_once()
    if args.command == "backfill":
        return backfill(args.days, args.location)
    if args.command == "validate-pagasa":
        return validate_pagasa(args.json, args.timeout)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
