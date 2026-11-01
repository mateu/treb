#!/usr/bin/env python3
"""Operator-only, identity-verified recovery for a pending Burt PR create."""
import argparse
import json
from pathlib import Path
import sqlite3
import sys

from broker import BASE, reconcile_pending_pull_request
from repository import Repository


def main():
    parser = argparse.ArgumentParser(
        description='Reconcile one pending repo_pr_create using GitHub GETs only.')
    parser.add_argument('--task-id', required=True,
                        help='64-character task ID from pending_pull_request_operations')
    args = parser.parse_args()

    database = BASE / 'jobs.sqlite'
    if (not database.is_file() or database.is_symlink()
            or database.stat().st_mode & 0o077):
        raise ValueError('expected private Burt workbench database')
    db = sqlite3.connect(database, timeout=10)
    db.row_factory = sqlite3.Row
    try:
        result = reconcile_pending_pull_request(db, Repository(), args.task_id)
    finally:
        db.close()
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('reconciliation blocked: ' + str(exc), file=sys.stderr)
        raise SystemExit(2)
