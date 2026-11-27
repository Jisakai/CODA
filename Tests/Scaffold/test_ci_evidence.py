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
    def test_exact_disjoint_exhaustive_four_way_ui_partition_and_runtime(self):
        groups = ci.partition()
        expected = {
            'ui-a': [
                'testEmptyEditorScreenshotAttachment',
                'testFourBarSeededFixtureScreenshotAttachment',
                'testDrawerAndAllThreeProductionPresetsAreReachable',
                'testEdgePositionedAllQualityRadialScreenshotFixture',
                'testPrimaryRadialScreenshotFixture',
            ],
            'ui-b': [
                'testKnobValueCapsulesAreOutsideActualDialsAndFingerDragStillWorks',
                'testFingerMusicRegionTapDoesNotEditOrCreateHistory',
                'testSnapShowsBothFullLabelsInsideOriginalGutterCell',
            ],
            'ui-c': [
                'testActualSessionPlayPauseAndChordMuteControls',
                'testChordMuteCenterAndPaddingRemainTappableInBothStates',
                'testKeyboardRowsStayBelowChromeAndFollowSemitoneRegister',
                'testCaptureNormalizationAppliesOrientationWithoutForcingLandscape',
            ],
            'ui-d': [
                'testEverySettingsPopupStaysNearItsOwnInvokingControl',
                'testLaunchShowsEmptyEditorAndLocksLandscape',
                'testSettingsIconCenterAndPaddingPresentProductionPopups',
            ],
        }
        self.assertEqual(groups, expected)
        assigned = [method for methods in groups.values() for method in methods]
        self.assertEqual(len(assigned), 15)
        self.assertEqual(len(assigned), len(set(assigned)))
        self.assertEqual(set(groups), {'ui-a', 'ui-b', 'ui-c', 'ui-d'})
        self.assertTrue({
            'testEmptyEditorScreenshotAttachment',
            'testFourBarSeededFixtureScreenshotAttachment',
            'testEdgePositionedAllQualityRadialScreenshotFixture',
            'testPrimaryRadialScreenshotFixture',
        }.issubset(groups['ui-a']))
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'tests.log'
            for lane, methods in groups.items():
                lines = [f"Test Case '-[codaUITests.CodaLaunchTests {m}]' passed (1.000 seconds)." for m in methods]
                log.write_text('\n'.join(lines))
                self.assertEqual(len(ci.runtime(lane, log)), len(methods))
                log.write_text('\n'.join(lines).replace('codaUITests.CodaLaunchTests', 'codaUITests.UnexpectedTests'))
                with self.assertRaises(ValueError):
                    ci.runtime(lane, log)
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

    def test_unit_runtime_matches_source_and_rejects_missing_unexpected_duplicate_failed_or_skipped_cases(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'tests.log'
            inventory = ci.unit_inventory()
            text = ''.join(
                f"Test Case '-[{class_name} {name}]' passed (0.001 seconds).\n"
                for class_name, name in inventory.elements()
            )
            objc_cases = {
                ('AudioAdapterTests', 'testPerformancePublicationLifecycleAndActualOfflineAudio'),
                ('AudioAdapterTests', 'testActualSourceNodeOfflineRenderAndRepeatedTeardown'),
            }
            self.assertTrue(objc_cases.issubset(inventory))
            self.assertIn("Test Case '-[AudioAdapterTests testActualSourceNodeOfflineRenderAndRepeatedTeardown]'", text)
            log.write_text(text)
            runtime_cases = ci.runtime('unit', log)
            self.assertEqual(len(runtime_cases), sum(inventory.values()))
            runtime_ids = {case['id'] for case in runtime_cases}
            self.assertTrue({f'{class_name}/{method}' for class_name, method in objc_cases}.issubset(runtime_ids))
            mutations = (
                '\n'.join(text.splitlines()[1:]),
                text + "Test Case '-[CodaMusicTests.MusicModelTests testUnexpected]' passed (0.001 seconds).\n",
                text + text.splitlines(keepends=True)[0],
                text.replace(" passed ", " skipped ", 1),
                text.replace(" passed ", " failed ", 1),
            )
            for label, changed in zip(('missing', 'unexpected', 'duplicate', 'skipped', 'failed'), mutations):
                log.write_text(changed)
                with self.subTest(case=label), self.assertRaises(ValueError):
                    ci.runtime('unit', log)
            without_objc = '\n'.join(
                line for line in text.splitlines() if '-[AudioAdapterTests ' not in line
            )
            log.write_text(without_objc)
            with self.assertRaises(ValueError):
                ci.runtime('unit', log)
            wrong_objc_identity = text.replace(
                '-[AudioAdapterTests ', '-[CodaAudioTests.AudioAdapterTests '
            )
            log.write_text(wrong_objc_identity)
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
        with self.assertRaises(ValueError):
            ci.verify('not-read-before-gating', {**good, 'unexpected': 'success'})

    def test_exact_sha_run_attempt_toolchain_and_payload_provenance(self):
        identity = {'GITHUB_SHA': 'a'*40, 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1'}
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, identity):
            root = Path(tmp)
            for lane in ci.LANES:
                folder = root / f'coda-internal-{lane}'
                folder.mkdir()
                (folder / 'payload').write_text(lane)
                if lane == 'unit':
                    log_lines = [
                        f"Test Case '-[{class_name} {method}]' passed (0.001 seconds)."
                        for class_name, method in ci.unit_inventory().elements()
                    ]
                elif lane in ci.UI_LANES:
                    log_lines = [
                        f"Test Case '-[codaUITests.CodaLaunchTests {method}]' passed (0.001 seconds)."
                        for method in ci.partition()[lane]
                    ]
                else:
                    log_lines = []
                tests = []
                if lane == 'unit' or lane in ci.UI_LANES:
                    (folder / 'tests.log').write_text('\n'.join(log_lines) + '\n')
                    tests = ci.runtime(lane, folder / 'tests.log')
                evidence = {**identity, 'lane': lane, 'toolchain': 'Xcode 27.2; iOS SDK 27.2',
                            'arch': 'arm64', 'configuration': ci.configuration(lane),
                            'tests': tests,
                            'files': {p.name: ci.digest(p) for p in folder.iterdir() if p.is_file()}}
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
            (path.parent / 'payload').write_text('archive')
            unit_path = root / 'coda-internal-unit/provenance.json'
            unit_original = json.loads(unit_path.read_text())
            unit_path.write_text(json.dumps({**unit_original, 'tests': []}))
            with self.assertRaises(ValueError):
                ci.verify(root, results)
            unit_path.write_text(json.dumps({key: value for key, value in unit_original.items() if key != 'tests'}))
            with self.assertRaises(ValueError):
                ci.verify(root, results)
            unit_path.write_text(json.dumps(unit_original))
            unit_folder = unit_path.parent
            unit_log = unit_folder / 'tests.log'
            unit_text = unit_log.read_text()
            unit_log.write_text('')
            unit_original['files']['tests.log'] = ci.digest(unit_log)
            unit_path.write_text(json.dumps(unit_original))
            with self.assertRaises(ValueError):
                ci.verify(root, results)
            unit_log.write_text('\n'.join(unit_text.splitlines()[1:]) + '\n')
            unit_original['files']['tests.log'] = ci.digest(unit_log)
            unit_path.write_text(json.dumps(unit_original))
            with self.assertRaises(ValueError):
                ci.verify(root, results)
            unit_log.unlink()
            unit_original['files'].pop('tests.log')
            unit_path.write_text(json.dumps(unit_original))
            with self.assertRaises(ValueError):
                ci.verify(root, results)

    def test_workflow_uses_five_runner_slots_with_shortest_ui_shard_delayed(self):
        workflow = (ROOT / '.github/workflows/unsigned-ipa.yml').read_text()
        self.assertEqual(ci.LANES, {'native', 'unit', 'ui-a', 'ui-b', 'ui-c', 'ui-d', 'archive'})
        immediate = workflow.split('\n  simulator:\n')[1].split('\n  simulator_delayed:\n')[0]
        delayed = workflow.split('\n  simulator_delayed:\n')[1].split('\n  publish:\n')[0]
        self.assertIn('lane: [unit, ui-a, ui-b, ui-c]', immediate)
        self.assertIn('max-parallel: 4', immediate)
        self.assertNotIn('needs:', immediate)
        self.assertIn('steps: &simulator-steps', immediate)
        self.assertIn('needs: [native]', delayed)
        self.assertIn('lane: [ui-d]', delayed)
        self.assertIn('steps: *simulator-steps', delayed)
        self.assertNotIn('always()', delayed)
        self.assertNotIn('if:', delayed)
        self.assertIn('name: native + archive', workflow)
        native = workflow.split('\n  native:\n')[1].split('\n  simulator:\n')[0]
        self.assertIn('Build and test portable DSP core', native)
        self.assertIn('Archive unsigned device app', native)
        self.assertLess(native.index('Build and test portable DSP core'),
                        native.index('Archive unsigned device app'))
        self.assertIn('fail-fast: false', workflow)
        self.assertIn('cancel-in-progress: true', workflow)
        self.assertEqual(workflow.count('runs-on: xcode-27'), 3)  # native + four immediate + one delayed
        self.assertIn('--output-dir build/artifacts/archive', workflow)
        self.assertIn('record archive build/artifacts/archive', workflow)
        self.assertIn('path: build/artifacts/archive/', workflow)
        self.assertIn('path: build/artifacts/native/', workflow)
        self.assertIn('name: Archive unsigned device app', workflow)
        self.assertNotIn('\n  archive:\n', workflow)
        self.assertIn('"$CI_LANE" != "ui-a"', workflow)
        self.assertIn('incoming/coda-internal-archive/App.ipa', workflow)
        self.assertIn('incoming/coda-internal-archive/App-verification.txt', workflow)
        release = workflow.split('\n  publish:\n')[1]
        self.assertIn('needs: [native, simulator, simulator_delayed]', release)
        for lane in ('native', 'simulator', 'simulator_delayed'):
            self.assertIn(f"needs.{lane}.result == 'success'", release)
        self.assertIn('"archive":"' + '$' + '{{ needs.native.result }}"', release)
        self.assertIn('"ui-d":"' + '$' + '{{ needs.simulator_delayed.result }}"', release)
        for lane in ('unit', 'ui-a', 'ui-b', 'ui-c'):
            self.assertIn(f'"{lane}":"' + '$' + '{{ needs.simulator.result }}"', release)
        self.assertIn('python3 scripts/ci_evidence.py verify incoming', release)
        self.assertEqual(workflow.count('name: coda-unsigned-ipa\n'), 1)
        self.assertNotIn('name: coda-unsigned-ipa\n', workflow.split('\n  publish:\n')[0])
        self.assertIn('ref: ${{ github.sha }}', release)
        self.assertNotIn('continue-on-error', workflow)


if __name__ == '__main__':
    unittest.main()
