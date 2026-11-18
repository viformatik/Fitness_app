#!/usr/bin/env python3
"""Check preserved hashes and distinguish current diagnostics from reproduced risks.

Does not run a browser, connect to a service, inspect a real diary, or prove a
release safe. Writes a NEW JSON report only when --output is supplied.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parent.parent


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path: str):
    return json.loads((ROOT/path).read_text(encoding='utf8'))


def require(condition: bool, label: str) -> None:
    if not condition:
        raise RuntimeError(label)


def main() -> None:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    if args.output and (args.output.exists() or args.output.is_symlink()):
        raise SystemExit('Refusing to overwrite a report')
    checks=[]
    def check(label: str, condition: bool) -> None:
        require(condition,label);checks.append({'name':label,'status':'PASS'})
    exact={
      'base_reconstruction/fitness_smart_synthetic_preview_restored_candidate.bundle':'da094330d3cead7c8ebc6559bf56be8a5f2a00d42caf6fa17b47e6039e984e73',
      'base_reconstruction/fitness_smart_local_clear_checkpoint_browser_WIP_NOT_RELEASE.patch.gz':'d5432d0f4a56ce0e4ed6301f7ee28f732cd6827a92f34fd1ef0102b2b24f45d1',
      'fixtures/archived_v14_web.tar.gz':'457e5da0b9d7da6d55e29c712428b52a84d8b626a4c7af39a3501cdcb4d5ae02',
      'recovered_exact_catalogs/lib/smart/local_catalog.dart':'4e17b536b880c4ab3900d5df348431fe4d9c42a67e5a2e3b4482055588902fe2',
      'recovered_exact_catalogs/lib/smart/regional_foods.dart':'dd6b091a2e07d7476337892012e7cc6586e5ab41dbad2049defba63b51a6a479',
      'recovered_exact_catalogs/tools/build_regional_foods.py':'7efddc5a580c9c9c782e39096dae051c30ca345846ff9c3f9696f6dd2ec0e3a7',
      'recovered_exact_catalogs/tools/data/regional_dairy.json':'539b40bdbf86313e41e89ad18d36f45c174241b3129475b4e7a0330661fc93c0',
      'recovered_sql_v1_DO_NOT_APPLY/food_search_upstream_budget_v1_as_sent_test.sql':'148e919d7b8cc247856529db963cc76c42da5dee4a3e122eba6f150a6c127b81',
      'surviving_previous_evidence/recovery_tests/reconstructed_online_contract_test.dart':'2189c0739a3fc73e446e002704743b2b62fbf4d5ed7c1d264fd42df1fcef6a1c',
    }
    for file,expected in exact.items():
        check('pinned '+file,sha(ROOT/file)==expected)
    local=load('recovered_exact_catalogs/tools/data/pmr_catalog.json')
    dairy=load('recovered_exact_catalogs/tools/data/regional_dairy.json')
    check('regenerated catalog rows are 99 PMR and 29 dairy',len(local['items'])==99 and len(dairy['items'])==29)
    evidence=load('surviving_previous_evidence/manifest.json')
    check('all 22 individually enumerated survivor hashes match',len(evidence['files'])==22 and all(
        sha(ROOT/'surviving_previous_evidence'/x['path'])==x['sha256'] for x in evidence['files']))
    survivor=load('surviving_previous_evidence/test_survivors_manifest.json')
    check('separate recovered/fast test survivor hashes match',len(survivor['files'])==6 and all(
        sha(ROOT/'surviving_previous_evidence'/x['path'])==x['sha256'] for x in survivor['files']))
    hist='surviving_previous_evidence/legacy_lab/'
    fork=load(hist+'checks/fork_review_complete_evidence.json')
    check('historical fork source hashes match',all(sha(ROOT/hist/f)==v for f,v in fork['sourceSha256'].items()))
    check('historical fork report hashes match',all(sha(ROOT/hist/x['report'])==x['sha256'] for x in fork['browserReports'].values()))
    oldrace=load('surviving_previous_evidence/fast_recovery_legacy_race_v1.json')
    check('historical +14/+41 race harness source hashes match',all(
      sha(ROOT/hist/name)==oldrace['sha256'][name] for name in
      ('checks/fast_recovery_legacy_race_v1.cjs','checks/serve_fast_recovery_legacy_race_v1.py')))
    summary=[]
    for engine in ('chromium','firefox'):
      for stem,source,passes in [
        (engine+'_initial','experiments/offline_fence_probe_initial.cjs.fixture',21),
        (engine+'_guarded_v2','experiments/offline_fence_probe.cjs',22),
        ('race_'+engine+'_initial','experiments/offline_stale_race_probe.cjs',14),
      ]:
        file='experiments/'+stem+'.json';r=load(file)
        check(stem+' report is bound to its included source',r['sourceSha256']==sha(ROOT/source))
        check(stem+' has the expected diagnostic and risk statuses',
          r['status']=='PARTIAL_SYNTHETIC_KNOWN_RISKS_NOT_A_RELEASE' and not r['failures'] and
          len(r['checks'])==passes and all(x['status']=='PASS' for x in r['checks']) and
          len(r['risks'])==2 and all(x['status']=='RISK_REPRODUCED' for x in r['risks']))
        check(stem+' actually loaded pinned +14 JS offline via service worker',any(
          x.get('sha256')=='fbe81cc44f9d747592ebe7c2a687fe137c46a853d5f680c04bc442a3db489c11' and
          x.get('serviceWorker') and x['page'] in ('control-offline','offline-reopen') for x in r['loaded']))
        if stem.startswith('race_'):
            seq=r['observations']['sequence']
            check(stem+' has 750 expected, 500 actual and identical later snapshots',
              seq['expectedForThreeSeparateActions']==750 and seq['actual']==500 and seq['afterTabA']==seq['afterTabB'] and
              any(x['value']==500 and x['completed'] and not x['aborted'] for x in seq['tabBTrace']))
        else:
            check(stem+' observes actual v1 VersionError after v2',any(
              x.get('version')==1 and x.get('error')=='VersionError' for x in r['observations']['rollback']['opens']))
        summary.append({'report':file,'sha256':sha(ROOT/file),'passConditions':passes,'risksReproduced':2,
                        'browserVersion':r['observations']['browserVersion']})
    wrapper=load('experiments/chromium_wrapper_v1.json')
    check('portable wrapper independently ran the current fence source',
      wrapper['sourceSha256']==sha(ROOT/'experiments/offline_fence_probe.cjs') and not wrapper['failures'] and
      len(wrapper['checks'])==22 and len(wrapper['risks'])==2 and
      wrapper['observations']['networkIsolation']['interfaces']==['lo'])
    refusal=load('experiments/outside_netns_refusal.json')
    check('outside-netns failure is a deliberate refusal before browser load',
      refusal['status']=='FAIL_OR_INCOMPLETE' and bool(refusal['failures']) and not refusal['loaded'] and not refusal['risks'])
    result={'status':'PARTIAL_SYNTHETIC_RESEARCH_NOT_RELEASE','verificationSourceSha256':sha(Path(__file__)),
      'passed':len(checks),'checks':checks,'browserReports':summary,
      'limitations':['Verifies hashes and internal report consistency, not authenticity or an independent rerun.',
                     'Prior full regression and reconstructed release sources are missing; no current full-app claim.',
                     'Two-browser synthetic tests reproduced risks, not fixes.']}
    text=json.dumps(result,indent=2,ensure_ascii=False)+'\n'
    if args.output:
        with args.output.open('x',encoding='utf8') as f:f.write(text)
    print(text,end='')


if __name__=='__main__':
    main()
