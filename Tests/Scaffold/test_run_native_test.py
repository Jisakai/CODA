import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("native_runner", Path(__file__).parents[2] / "scripts/run_native_test.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

class NativeRunnerTests(unittest.TestCase):
    def test_actual_children(self):
        for source, expected in [("pass", 0), ("raise SystemExit(3)", 3)]:
            with self.subTest(source=source):
                self.assertEqual(runner.main([sys.executable, "-c", source], diagnose=False), expected)

    def test_actual_abort(self):
        source = "import ctypes, os; ctypes.CDLL('kernel32').SetErrorMode(2) if os.name == 'nt' else None; os.abort()"
        result = runner.main([sys.executable, "-c", source], diagnose=False)
        self.assertNotEqual(result, 0)
        if sys.platform != "win32":
            self.assertEqual(result, 134)

    def test_actual_timeout(self):
        self.assertEqual(runner.main([sys.executable, "-c", "import time; time.sleep(5)"], timeout=.05, diagnose=False), 124)

    def test_debugger_cannot_mask_failure(self):
        original = runner.subprocess.run
        def invoke(command, **kwargs):
            if command[0] == "lldb":
                raise OSError("diagnostic unavailable")
            return original(command, **kwargs)
        with patch.object(runner.shutil, "which", return_value="lldb"), patch.object(runner.subprocess, "run", side_effect=invoke):
            self.assertEqual(runner.main([sys.executable, "-c", "raise SystemExit(3)"]), 3)

if __name__ == "__main__":
    unittest.main()
