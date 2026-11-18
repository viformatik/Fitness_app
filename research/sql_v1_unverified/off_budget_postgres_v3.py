#!/usr/bin/env python3
"""Test local candidate rate limit in a fresh Unix-socket-only PostgreSQL.

Creates synthetic roles and an ephemeral test database in the guarded cluster.
Never connects to Supabase, real accounts, or any user diary. Report is create-only.
"""
from __future__ import annotations
import concurrent.futures
import hashlib
import json
from pathlib import Path
import secrets
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LAB = Path('/home/user/.cache/fitness-off-budget-pg-v1')
SOCKET, DATA = LAB / 'socket', LAB / 'data'
SQL = ROOT / 'supabase/candidates/food_search_upstream_budget_v1.sql'
OUT = ROOT / 'checks/off_budget_postgres_v3.json'
DB = 'off_budget_synthetic_' + secrets.token_hex(6)


def run(db: str, sql: str, expect: bool = True) -> subprocess.CompletedProcess:
    if db not in ('postgres', DB):
        raise RuntimeError('unexpected database')
    p = subprocess.run(['/usr/bin/psql','-X','-v','ON_ERROR_STOP=1','-h',str(SOCKET),
                        '-p','55457','-U','user','-d',db,'-Atq'], input=sql, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if expect and p.returncode:
        raise RuntimeError('local psql error: ' + p.stderr[-600:])
    return p


def main() -> int:
    if OUT.exists() or OUT.is_symlink():
        raise RuntimeError('refusing to overwrite report')
    identity = run('postgres',"select current_setting('data_directory'),current_setting('listen_addresses'),inet_server_addr() is null;").stdout.strip()
    if identity != f'{DATA}||t':
        raise RuntimeError('refusing non-isolated postgres: ' + repr(identity))
    checks = []
    def check(name: str, actual: bool):
        checks.append({'name':name,'status':'PASS' if actual else 'FAIL'})
        if not actual:
            raise AssertionError(name)
        print('PASS',name,flush=True)
    failure = None
    try:
        roles = run('postgres', "select count(*) from pg_roles where rolname in ('anon','authenticated','service_role') and not rolcanlogin and not rolsuper;").stdout.strip()
        if roles == '0':
            run('postgres', 'create role anon nologin; create role authenticated nologin; create role service_role nologin;')
        elif roles != '3':
            raise RuntimeError('unexpected local synthetic roles')
        run('postgres', f'create database {DB};')
        run(DB, SQL.read_text(encoding='utf8'))
        check('local candidate installed only in random synthetic DB', True)
        for role in ('anon','authenticated'):
            denied = run(DB, f"set role {role}; select public.reserve_fitness_off_search_v1('batch');", expect=False)
            check(f'{role} cannot call privileged budget RPC',denied.returncode != 0 and 'permission denied' in denied.stderr.lower())
        denied = run(DB, 'set role service_role; select * from public.fitness_off_search_budget_v1;', expect=False)
        check('service role has no direct table grant',denied.returncode != 0 and 'permission denied' in denied.stderr.lower())
        invalid = run(DB, "set role service_role; select public.reserve_fitness_off_search_v1(null), public.reserve_fitness_off_search_v1('other');").stdout.strip()
        check('unknown kinds fail closed',invalid == 'f|f')
        count = run(DB,'select count(*) from public.fitness_off_search_budget_v1;').stdout.strip()
        check('invalid kinds consume no budget',count == '0')
        output = run(DB,"set role service_role; select public.reserve_fitness_off_search_v1('batch') from generate_series(1,9);").stdout.splitlines()
        check('first eight reservations succeed and ninth is denied',output == ['t']*8 + ['f'])
        blocked_other = run(DB,"set role service_role; select public.reserve_fitness_off_search_v1('discovery');").stdout.strip()
        check('discovery and batch share one combined upstream budget',blocked_other == 'f')
        run(DB,'delete from public.fitness_off_search_budget_v1;')
        output = run(DB,"set role service_role; select public.reserve_fitness_off_search_v1(case when n % 2 = 0 then 'discovery' else 'batch' end) from generate_series(1,9) as n;").stdout.splitlines()
        check('mixed search types cannot exceed the combined budget',output == ['t']*8 + ['f'])
        run(DB,"delete from public.fitness_off_search_budget_v1; insert into public.fitness_off_search_budget_v1(kind,reserved_at) select 'batch',clock_timestamp()-interval '61 seconds' from generate_series(1,8);")
        blocked = run(DB,"set role service_role; select public.reserve_fitness_off_search_v1('batch');").stdout.strip()
        check('rolling window does not reset at minute boundary',blocked == 'f')
        run(DB,"update public.fitness_off_search_budget_v1 set reserved_at=clock_timestamp()-interval '71 seconds';")
        allowed = run(DB,"set role service_role; select public.reserve_fitness_off_search_v1('batch');").stdout.strip()
        check('expired reservations release capacity',allowed == 't')
        count = run(DB,'select count(*) from public.fitness_off_search_budget_v1;').stdout.strip()
        check('expired rows are cleaned without user data',count == '1')
        run(DB,'delete from public.fitness_off_search_budget_v1;')
        def call(_):
            return run(DB,"set role service_role; select public.reserve_fitness_off_search_v1('batch');").stdout.strip()
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            results = list(pool.map(call,range(24)))
        check('24 concurrent callers admit exactly eight',results.count('t')==8 and results.count('f')==16)
        count = run(DB,"select count(*) from public.fitness_off_search_budget_v1 where kind='batch';").stdout.strip()
        check('concurrent reservations leave exactly eight rows',count == '8')
    except Exception as exc:
        failure = f'{type(exc).__name__}: {exc}'
        print('FAIL_OR_INCOMPLETE',failure,file=sys.stderr,flush=True)
    report = {'status':'PASS_SYNTHETIC_LOCAL_ONLY' if failure is None else 'FAIL_OR_INCOMPLETE',
              'checks':checks, 'passed':sum(x['status']=='PASS' for x in checks),
              'failure':failure, 'database':DB,
              'sqlSha256':hashlib.sha256(SQL.read_bytes()).hexdigest(),
              'limitations':['Local PostgreSQL with synthetic roles only, not Supabase Auth/PostgREST or deployment.',
                             'Other apps can share an egress IP; reserve timing does not prove the external service will accept requests.',
                             'The test cluster has Unix sockets only, contains no user data, and is not a backup.']}
    with OUT.open('x',encoding='utf8') as f:
        json.dump(report,f,ensure_ascii=False,indent=2);f.write('\n')
    return 1 if failure else 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f'Stopped: {type(exc).__name__}: {exc}',file=sys.stderr)
        raise SystemExit(1)
