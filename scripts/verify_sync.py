# SPDX-License-Identifier: LGPL-3.0-only
"""Run tagged bridge/app sync tests in fresh owned HTTPS fixture processes.

The existing core fixture owns its endpoint, temporary CA, credentials and data.
No device trust/test mode or OS certificate store is changed by this host runner.
"""

import argparse
import os
from pathlib import Path
import subprocess
import shutil
import sys


def invocation(program, arguments):
    if os.name == "nt" and Path(program).suffix.lower() in {".bat", ".cmd"}:
        def literal(value):
            return "'" + value.replace("'", "''") + "'"
        command = "& " + " ".join(literal(value) for value in [program, *arguments])
        return ["pwsh", "-NoProfile", "-Command", command + "; exit $LASTEXITCODE"]
    return [program, *arguments]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dart", required=True)
    parser.add_argument("--flutter", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    runner = root / "third_party" / "vxcore" / "tests" / "run_webdav_test.py"
    environment = dict(os.environ)
    if os.name == "nt" and not environment.get("OPENSSL"):
        git = shutil.which("git")
        if git:
            # Some Windows toolchains ship a working binary with a missing
            # build-machine default openssl.cnf. Git supplies its matching config.
            for parent in Path(git).resolve().parents:
                candidate = parent / "usr" / "bin" / "openssl.exe"
                if candidate.is_file():
                    environment["OPENSSL"] = str(candidate)
                    break
    suites = [
        (root / "packages" / "vxcore_bridge", args.dart,
         ["test", "--tags", "webdav-integration", "--concurrency=1"]),
        (root / "apps" / "vnote_mobile", args.flutter,
         ["test", "--no-pub", "--tags", "webdav-integration", "--concurrency=1"]),
    ]
    for directory, program, arguments in suites:
        # Only executable/test arguments are printed by their tools. Fixture
        # secrets stay in the inherited child environment, never command lines.
        command = [sys.executable, str(runner), "--", *invocation(program, arguments)]
        result = subprocess.run(command, cwd=directory, env=environment, check=False)
        if result.returncode:
            return result.returncode if result.returncode > 0 else 128 - result.returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())
