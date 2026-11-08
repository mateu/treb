#!/usr/bin/env python3
"""Operator-only, identity-verified recovery for a pending Burt PR create."""
import argparse
import json
from pathlib import Path
import sqlite3
import sys

from broker import BASE, confirm_absent_pending_pull_request, reconcile_pending_pull_request
from repository import Repository
from runner import BrokerRejection


def main():
    parser = argparse.ArgumentParser(
        description='Reconcile one pending repo_pr_create using GitHub GETs only.')
    parser.add_argument('--task-id', required=True,
                        help='64-character task ID from pending_pull_request_operations')
    parser.add_argument('--confirm-absent', action='store_true',
                        help='verify that no PR exists for the stored branch, then optionally clear one record')
    parser.add_argument('--operator', help='bounded operator identifier; required with --confirm-absent')
    parser.add_argument('--yes', action='store_true',
                        help='commit an eligible --confirm-absent operation; otherwise preview only')
    args = parser.parse_args()
    if args.yes and not args.confirm_absent:
        parser.error('--yes requires --confirm-absent')
    if args.confirm_absent and not args.operator:
        parser.error('--confirm-absent requires --operator')
    if not args.confirm_absent and args.operator:
        parser.error('--operator requires --confirm-absent')

    database = BASE / 'jobs.sqlite'
    if (not database.is_file() or database.is_symlink()
            or database.stat().st_mode & 0o077):
        raise BrokerRejection('expected private Burt workbench database')
    db = sqlite3.connect(database, timeout=10)
    db.row_factory = sqlite3.Row
    try:
        if args.confirm_absent:
            result = confirm_absent_pending_pull_request(db, Repository(), args.task_id,
                                                          args.operator, commit=args.yes)
        else:
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
