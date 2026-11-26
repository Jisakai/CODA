import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ci_evidence', ROOT / 'scripts/ci_evidence.py')
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class CIEvidenceTests(unittest.TestCase):
    def test_exact_disjoint_ui_inventory_and_runtime(self):
        groups = ci.partition()
        self.assertEqual(sum(map(len, groups.values())), 15)
        self.assertFalse(set(groups['ui-a']) & set(groups['ui-b']))
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'tests.log'
            for lane, methods in groups.items():
                lines = [f"Test Case '-[codaUITests.CodaLaunchTests {m}]' passed (1.000 seconds)." for m in methods]
                log.write_text('\n'.join(lines))
                self.assertEqual(len(ci.runtime(lane, log)), len(methods))
                for bad in ('\n'.join(lines[:-1]), '\n'.join(lines + lines[:1]), '\n'.join(lines).replace('passed', 'skipped', 1), '\n'.join(lines).replace('passed', 'failed', 1)):
                    log.write_text(bad)
                    with self.assertRaises(ValueError):
                        ci.runtime(lane, log)

    def test_new_unassigned_or_duplicate_methods_fail_closed(self):
        original = Path.read_text
        def changed(path, *args, **kwargs):
            value = original(path, *args, **kwargs)
            return value + '\nfunc testNewFutureCase() {}' if path.suffix == '.swift' else value
        with patch.object(Path, 'read_text', changed), self.assertRaises(ValueError):
            ci.partition()
        groups = ci.partition()
        groups['ui-b'].append(groups['ui-a'][0])
        with patch.object(ci.json, 'loads', return_value=groups), self.assertRaises(ValueError):
            ci.partition()

    def test_unit_runtime_requires_all_three_native_targets(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'tests.log'
            text = "Test Case '-[CodaMusicTests.MusicTests testExample]' passed (0.001 seconds).\n"
            for target in ('CodaMusicTests', 'CodaInteractionTests', 'CodaAudioTests'):
                text += f"Test Suite '{target}.xctest' passed\n"
            log.write_text(text)
            self.assertEqual(len(ci.runtime('unit', log)), 1)
            log.write_text(text + "Test Case '-[CodaMusicTests.MusicTests testSkipped]' skipped.\n")
            with self.assertRaises(ValueError):
                ci.runtime('unit', log)
            log.write_text(text.replace("Test Suite 'CodaAudioTests.xctest' passed", ''))
            with self.assertRaises(ValueError):
                ci.runtime('unit', log)

    def test_publication_rejects_any_failed_skipped_cancelled_or_missing_lane(self):
        good = dict.fromkeys(ci.LANES, 'success')
        for lane in ci.LANES:
            for status in ('failure', 'skipped', 'cancelled', 'timed_out'):
                with self.subTest(lane=lane, status=status), self.assertRaises(ValueError):
                    ci.verify('not-read-before-gating', {**good, lane: status})
        with self.assertRaises(ValueError):
            ci.verify('not-read-before-gating', {'archive': 'success'})

    def test_exact_sha_run_attempt_toolchain_and_payload_provenance(self):
        identity = {'GITHUB_SHA': 'a'*40, 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1'}
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, identity):
            root = Path(tmp)
            for lane in ci.LANES:
                folder = root / f'coda-internal-{lane}'
                folder.mkdir()
                (folder / 'payload').write_text(lane)
                evidence = {**identity, 'lane': lane, 'toolchain': 'Xcode 27.2; iOS SDK 27.2',
                            'arch': 'arm64', 'configuration': ci.configuration(lane),
                            'files': {'payload': ci.digest(folder / 'payload')}}
                (folder / 'provenance.json').write_text(json.dumps(evidence))
            results = dict.fromkeys(ci.LANES, 'success')
            ci.verify(root, results)
            path = root / 'coda-internal-archive/provenance.json'
            original = json.loads(path.read_text())
            for key in (*identity, 'toolchain', 'arch', 'configuration', 'lane'):
                path.write_text(json.dumps({**original, key: 'foreign'}))
                with self.subTest(key=key), self.assertRaises(ValueError):
                    ci.verify(root, results)
            path.write_text(json.dumps(original))
            (path.parent / 'payload').write_text('tampered')
            with self.assertRaises(ValueError):
                ci.verify(root, results)

    def test_workflow_is_five_mac_producers_with_fail_independent_release_gate(self):
        workflow = (ROOT / '.github/workflows/unsigned-ipa.yml').read_text()
        self.assertIn('lane: [unit, ui-a, ui-b]', workflow)
        self.assertIn('fail-fast: false', workflow)
        self.assertIn('cancel-in-progress: true', workflow)
        self.assertEqual(workflow.count('runs-on: xcode-27'), 3)  # native + 3 matrix + archive
        release = workflow.split('\n  publish:\n')[1]
        for lane in ('native', 'simulator', 'archive'):
            self.assertIn(f"needs.{lane}.result == 'success'", release)
        self.assertIn('python3 scripts/ci_evidence.py verify incoming', release)
        self.assertEqual(workflow.count('name: coda-unsigned-ipa\n'), 1)
        self.assertNotIn('name: coda-unsigned-ipa\n', workflow.split('\n  publish:\n')[0])
        self.assertIn('ref: ${{ github.sha }}', release)
        self.assertNotIn('continue-on-error', workflow)


if __name__ == '__main__':
    unittest.main()
