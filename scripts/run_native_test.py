"""Bounded native runner; diagnostic reruns never replace the primary failure."""
import shutil
import signal
import subprocess
import sys


def main(command=None, timeout=240, diagnose=True):
    command = sys.argv[1:] if command is None else command
    print("Native command:", command, flush=True)
    try:
        result = subprocess.run(command, timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"Native test timed out after {timeout}s", file=sys.stderr, flush=True)
        return 124
    code = result.returncode
    if not code:
        return 0
    try:
        name = signal.Signals(-code).name if code < 0 else "exit"
    except ValueError:
        name = "unknown"
    print(f"Native failure: returncode={code} signal={name}", file=sys.stderr, flush=True)
    if diagnose and shutil.which("lldb"):
        try:
            subprocess.run(["lldb", "--batch", "-o", "run", "-o", "thread backtrace all", "--", *command], timeout=60)
        except (subprocess.TimeoutExpired, OSError) as error:
            print(f"LLDB diagnostic failed: {error}", file=sys.stderr, flush=True)
    return 128-code if code < 0 else code


if __name__ == "__main__":
    sys.exit(main())
