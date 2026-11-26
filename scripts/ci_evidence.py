"""Fail-closed test partition, runtime evidence and exact-run artifact provenance."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LANES = {'native', 'unit', 'ui-a', 'ui-b', 'archive'}


def configuration(lane):
    return {'archive': 'Release', 'native': 'C++20 O2 + O1 ASan+UBSan'}.get(lane, 'Debug')


def partition():
    groups = json.loads((ROOT / 'scripts/ui_shards.json').read_text())
    assigned = [name for names in groups.values() for name in names]
    source = []
    for path in (ROOT / 'Tests/CodaUITests').glob('*.swift'):
        source += re.findall(r'func (test\w+)\s*\(', path.read_text())
    if set(groups) != {'ui-a', 'ui-b'} or Counter(assigned) != Counter(source):
        raise ValueError('UI inventory changed: update the disjoint explicit partition')
    if len(assigned) != len(set(assigned)):
        raise ValueError('Duplicate UI assignment')
    return groups


def runtime(lane, log):
    text = Path(log).read_text(errors='replace')
    if re.search(r"Test Case .* (?:failed|skipped)\b|with [1-9][0-9]* tests? skipped", text):
        raise ValueError('Failed or skipped XCTest case in runtime log')
    cases = re.findall(r"Test Case '-\[([^ ]+) (test\w+)\]' (passed|failed|skipped) \(([\d.]+) seconds\)", text)
    if not cases or any(case[2] != 'passed' for case in cases):
        raise ValueError('Missing, failed or skipped XCTest runtime cases')
    ids = [f'{c}/{m}' for c, m, _, _ in cases]
    if len(ids) != len(set(ids)):
        raise ValueError('Repeated runtime cases (unexpected retry/duplicate)')
    ui = [m for c, m, _, _ in cases if c.startswith('codaUITests.')]
    if lane.startswith('ui-'):
        if Counter(ui) != Counter(partition()[lane]) or len(ui) != len(cases):
            raise ValueError('Runtime UI inventory differs from assigned shard')
    elif lane == 'unit':
        if ui:
            raise ValueError('UI case leaked into unit lane')
        # Every source test target remains in the unfiltered scheme; additions
        # are automatically exercised. Runtime evidence must include each target.
        for target in ('CodaMusicTests', 'CodaInteractionTests', 'CodaAudioTests'):
            if f"Test Suite '{target}.xctest' passed" not in text:
                raise ValueError(f'Missing runtime target: {target}')
    return [{'id': i, 'seconds': float(case[3])} for i, case in zip(ids, cases)]


def identity():
    return {key: os.environ[key] for key in ('GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT')}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record(lane, directory, log=None):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if sha != os.environ['GITHUB_SHA']:
        raise ValueError('Checkout is not this exact workflow SHA')
    evidence = {**identity(), 'lane': lane, 'toolchain': Path('build-toolchain.txt').read_text().strip(),
                'arch': subprocess.check_output(['uname', '-m'], text=True).strip(),
                'configuration': configuration(lane),
                'tests': runtime(lane, log) if log else [],
                'files': {p.relative_to(directory).as_posix(): digest(p)
                          for p in directory.rglob('*') if p.is_file() and p.name != 'provenance.json'}}
    (directory / 'provenance.json').write_text(json.dumps(evidence, indent=2) + '\n')
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write(f"\n### {lane}\nSHA `{sha}`; {len(evidence['tests'])} runtime XCTest cases.\n\n")
        for case in evidence['tests']:
            summary.write(f"- `{case['id']}`: {case['seconds']:.3f}s\n")


def verify(directory, results):
    if set(results) != LANES or any(v != 'success' for v in results.values()):
        raise ValueError('All five lanes must succeed before publication')
    root = Path(directory)
    for lane in sorted(LANES):
        folder = root / f'coda-internal-{lane}'
        evidence = json.loads((folder / 'provenance.json').read_text())
        if any(evidence.get(k) != v for k, v in identity().items()) or evidence['lane'] != lane:
            raise ValueError('Stale or foreign artifact provenance')
        if evidence['toolchain'] != 'Xcode 27.2; iOS SDK 27.2' or evidence['arch'] not in ('arm64', 'x86_64'):
            raise ValueError('Unexpected producer toolchain/architecture')
        if evidence['configuration'] != configuration(lane):
            raise ValueError('Unexpected configuration')
        actual = {p.relative_to(folder).as_posix(): digest(p) for p in folder.rglob('*')
                  if p.is_file() and p.name != 'provenance.json'}
        if actual != evidence['files'] or not actual:
            raise ValueError('Artifact payload differs from producer manifest')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('select'); p.add_argument('lane')
    p = sub.add_parser('record'); p.add_argument('lane', choices=sorted(LANES)); p.add_argument('directory'); p.add_argument('--log')
    p = sub.add_parser('verify'); p.add_argument('directory'); p.add_argument('results')
    args = parser.parse_args()
    if args.command == 'select':
        groups = partition()
        if args.lane == 'unit':
            print('-skip-testing:codaUITests')
        else:
            for name in groups[args.lane]:
                print(f'-only-testing:codaUITests/CodaLaunchTests/{name}')
    elif args.command == 'record':
        record(args.lane, args.directory, args.log)
    else:
        verify(args.directory, json.loads(args.results))
