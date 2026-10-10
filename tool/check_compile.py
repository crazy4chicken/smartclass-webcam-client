#!/usr/bin/env python3
"""Type-check the whole project with Flutter's frontend server.

Why this exists
---------------
`flutter analyze` and `flutter test` cannot run in an agent shell on this
machine: the Dart VM cannot create subprocess pipes there, so they die with
`ProcessException: All pipe instances are busy` (errno 231). See
`docs/agents/handover.md` section 1.

The frontend server itself, however, can be driven directly from Python. A
single-shot compile is the same type-check `flutter build` performs, so an
error reported here is an error `flutter` would report too.

**This compiles; it does not run.** It proves a file type-checks. It proves
nothing about whether its assertions pass — that still needs `flutter test` on
the user's own terminal. Never let "compiled OK" stand in for "tests pass".

Usage
-----
    python tool/check_compile.py                    # lib/main.dart + all of test/ and tool/
    python tool/check_compile.py test/agent/agent_coordinator_test.dart

An entry whose program has no `main` is reported as `lib ` rather than as a
failure. That is the `tool/verify_*.dart` family — they are libraries that
`verify_pure.dart` imports, and not having an entry point is what a library is.

Takes about five minutes, because each entry is a separate full compile.
"""

import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _flutter_root():
    """The Flutter SDK, from the environment or from `flutter` on PATH."""
    env = os.environ.get("FLUTTER_ROOT")
    if env and os.path.isdir(env):
        return env
    exe = shutil.which("flutter")
    if exe:
        return os.path.dirname(os.path.dirname(os.path.abspath(exe)))
    raise SystemExit("cannot find the Flutter SDK: put `flutter` on PATH or set FLUTTER_ROOT")


FL = _flutter_root()
SDK = os.path.join(FL, "bin", "cache", "dart-sdk")
FS = os.path.join(SDK, "bin", "snapshots", "frontend_server_aot.dart.snapshot")
RT = os.path.join(SDK, "bin", "dartaotruntime" + (".exe" if os.name == "nt" else ""))
PATCHED = os.path.join(
    FL, "bin", "cache", "artifacts", "engine", "common", "flutter_patched_sdk"
) + os.sep
PKG = os.path.join(ROOT, ".dart_tool", "package_config.json")
OUT = os.path.join(ROOT, ".dart_tool", "check_compile")

if not os.path.isfile(PKG):
    raise SystemExit("no %s: run `flutter pub get` once (in your own terminal)" % PKG)

os.makedirs(OUT, exist_ok=True)

entries = list(sys.argv[1:]) or ["lib/main.dart"]
for base in ("test", "tool"):
    for dirpath, _dirs, names in os.walk(os.path.join(ROOT, base)):
        for name in sorted(names):
            if not name.endswith(".dart"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, name), ROOT)
            if rel.replace("\\", "/") not in entries:
                entries.append(rel)

failures = []
report = []
for entry in entries:
    out_dill = os.path.join(OUT, entry.replace("\\", "_").replace("/", "_") + ".dill")
    platform_uri = "file:///" + os.path.join(PATCHED, "platform_strong.dill").replace("\\", "/").lstrip("/")
    args = [
        RT,
        FS,
        "--sdk-root",
        PATCHED,
        "--target=flutter",
        "--platform=" + platform_uri,
        "--packages=" + PKG,
        "--output-dill=" + out_dill,
        "--no-print-incremental-dependencies",
        "-Ddart.vm.profile=false",
        "-Ddart.vm.product=false",
        "--enable-asserts",
        "--track-widget-creation",
        entry,
    ]
    started = time.time()
    proc = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, errors="replace")
    blob = (proc.stdout or "") + (proc.stderr or "")
    took = time.time() - started

    if "No 'main' method found" in blob:
        # A library, not a program. Not having an entry point is the point.
        report.append("lib  %-58s %5.1fs" % (entry, took))
        continue

    if proc.returncode == 0 and "Error:" not in blob and "Unhandled exception" not in blob:
        report.append("OK   %-58s %5.1fs" % (entry, took))
        continue

    report.append("FAIL %-58s %5.1fs" % (entry, took))
    failures.append((entry, blob))

print("\n".join(report))
print("---")
print("compiled: %d, failed: %d" % (len(entries), len(failures)))
for entry, blob in failures:
    print("")
    print("=== %s ===" % entry)
    for line in [ln for ln in blob.splitlines() if ln.strip()][:40]:
        print("   " + line)

sys.exit(1 if failures else 0)
