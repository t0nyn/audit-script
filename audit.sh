#!/usr/bin/env bash
set -euo pipefail

cd /app

# Check that the Dockerfile does not create non-dependency files
echo "Checking Dockerfile for non-dependency file creation..."

if [[ ! -f "Dockerfile" ]]; then
  echo "WARNING: No Dockerfile found at /app/Dockerfile; skipping non-dependency file check." >&2
else
  python3 << 'PYEOF'
import re, sys

ALLOWED_BASENAMES = {
    # Rust
    "cargo.toml", "cargo.lock",
    # Node / JS
    "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
    ".npmrc", ".yarnrc", ".yarnrc.yml",
    # Python
    "requirements.txt", "pipfile", "pipfile.lock", "pyproject.toml",
    "setup.py", "setup.cfg", "poetry.lock", "constraints.txt",
    # Ruby
    "gemfile", "gemfile.lock",
    # Go
    "go.mod", "go.sum",
    # Java / JVM
    "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle",
    "settings.gradle.kts", "gradle.properties", "gradlew", "gradlew.bat",
    # .NET / C#
    "nuget.config", "packages.config", "directory.build.props",
    "directory.packages.props",
    # PHP
    "composer.json", "composer.lock",
    # Swift / CocoaPods
    "podfile", "podfile.lock", "package.swift", "package.resolved",
    # Elixir / Erlang
    "mix.exs", "mix.lock", "rebar.config", "rebar.lock",
    # Clojure
    "project.clj", "deps.edn", "shadow-cljs.edn",
    # R
    "description", "renv.lock",
    # Dart / Flutter
    "pubspec.yaml", "pubspec.lock",
}

ALLOWED_EXTENSIONS = {
    ".gemspec", ".cabal", ".csproj", ".fsproj", ".vbproj", ".sln", ".toml",
}

def is_dependency_file(path: str) -> bool:
    basename = path.rstrip("/").split("/")[-1].lower()
    if basename in ALLOWED_BASENAMES:
        return True
    _, _, ext = basename.rpartition(".")
    if ext and f".{ext}" in ALLOWED_EXTENSIONS:
        return True
    if re.match(r"requirements.*\.txt$", basename):
        return True
    return False

COPY_RE = re.compile(r"^\s*COPY\b", re.IGNORECASE)
ADD_RE = re.compile(
    r"^\s*ADD\s+(?:--\S+\s+)*(.+?)\s+(\S+)\s*$",
    re.IGNORECASE,
)
# Use negative lookahead (?!=) to avoid matching >= (version specifiers like pip install "pkg>=1.0")
REDIRECT_RE = re.compile(r"(?:>>?(?!=)|tee\s+)\s*([^\s;|&><]+)")
TOUCH_RE = re.compile(r"\btouch\s+((?:[^\s;|&><]+\s*)+)")

violations = []

with open("Dockerfile") as fh:
    lines = fh.read().splitlines()

i = 0
while i < len(lines):
    logical = lines[i].rstrip()
    while logical.endswith("\\"):
        i += 1
        if i >= len(lines):
            break
        logical = logical[:-1] + " " + lines[i].rstrip()

    # Flag any COPY command
    if COPY_RE.match(logical):
        violations.append(f"Line {i+1}: COPY command detected")
    # Check ADD for non-dependency files
    elif ADD_RE.match(logical):
        tokens = [t for t in logical.split()[1:] if not t.startswith("--")]
        if len(tokens) >= 2:
            for src in tokens[:-1]:
                src_base = src.rstrip("/").split("/")[-1]
                if src_base in (".", "..") or src.endswith("/"):
                    violations.append(f"Line {i+1}: ADD copies entire directory '{src}' (may include non-dependency files)")
                elif not is_dependency_file(src_base):
                    violations.append(f"Line {i+1}: ADD copies non-dependency file '{src}'")
    elif re.match(r"^\s*RUN\b", logical, re.IGNORECASE):
        shell_part = re.sub(r"^\s*RUN\s+", "", logical, flags=re.IGNORECASE)
        
        # Check shell redirections (>, >>, tee)
        for m in REDIRECT_RE.finditer(shell_part):
            dest = m.group(1).strip("'\"")
            dest_base = dest.rstrip("/").split("/")[-1]
            if dest_base and not is_dependency_file(dest_base):
                violations.append(f"Line {i+1}: RUN writes non-dependency file '{dest}' via shell redirection")
        
        # Check touch commands
        for m in TOUCH_RE.finditer(shell_part):
            for touched_file in m.group(1).split():
                dest_base = touched_file.rstrip("/").split("/")[-1]
                if dest_base and not is_dependency_file(dest_base):
                    violations.append(f"Line {i+1}: RUN creates non-dependency file '{touched_file}' via touch")

    i += 1

if violations:
    print(f"WARNING: Dockerfile references {len(violations)} file(s) that may not be dependency files â€” please verify manually:", file=sys.stderr)
    for v in violations:
        print(f"  - {v}", file=sys.stderr)
else:
    print("Dockerfile check passed: no non-dependency file creation detected.")
PYEOF
fi

# Validate required files exist
missing=()
for f in test_patch.diff golden_patch.diff run_script.sh parsing.py; do
  [[ -f "$f" ]] || missing+=("$f")
done
if (( ${#missing[@]} )); then
  echo "ERROR: Missing required file(s): ${missing[*]}" >&2
  exit 1
fi

echo "Applying test patch..."

git apply --ignore-space-change --ignore-whitespace test_patch.diff
echo "Running run_script.sh..."
bash run_script.sh 1> stdout.txt 2> stderr.txt || true
echo "Parsing before.json..."
python3 parsing.py stdout.txt stderr.txt before.json

echo "Applying golden patch..."
git apply --ignore-space-change --ignore-whitespace golden_patch.diff
echo "Running run_script.sh..."
bash run_script.sh 1> stdout.txt 2> stderr.txt || true
echo "Parsing after.json..."
python3 parsing.py stdout.txt stderr.txt after.json

echo "Computing fail-to-pass and pass-to-pass tests..."
if python3 << 'PYEOF'
import json, sys

FAIL_STATUSES = {'FAILED', 'ERROR', 'SKIPPED'}

def normalize(status):
    return 'FAILED' if status in FAIL_STATUSES else status

with open('before.json') as f:
    before = {t['name']: normalize(t['status']) for t in json.load(f)['tests']}
with open('after.json') as f:
    after = {t['name']: normalize(t['status']) for t in json.load(f)['tests']}

f2p = [name for name, status in before.items()
       if status == 'FAILED' and after.get(name) == 'PASSED']

new_passes = [name for name, status in after.items()
              if name not in before and status == 'PASSED']
f2p.extend(new_passes)

# Check for ANY tests appearing or disappearing (regardless of status)
new_tests = [name for name in after.keys() if name not in before]
missing_tests = [name for name in before.keys() if name not in after]

p2f = [name for name, status in before.items()
       if status == 'PASSED' and after.get(name) == 'FAILED']

p2p = [name for name, status in before.items()
       if status == 'PASSED' and after.get(name) == 'PASSED']

# Check for any FAILED tests in after.json
failed_in_after = [name for name, status in after.items() if status == 'FAILED']

with open('/app/fail_to_pass.json', 'w') as f:
    json.dump(f2p, f, indent=2)
with open('/app/pass_to_pass.json', 'w') as f:
    json.dump(p2p, f, indent=2)

print(json.dumps({'fail_to_pass': f2p}, indent=2))
if new_passes:
    print('{} new test(s) appeared and PASSED (counted as fail-to-pass).'.format(len(new_passes)))
print('{} total test(s) went from FAILED to PASSED.'.format(len(f2p)))
print('{} test(s) stayed PASSED (pass-to-pass).'.format(len(p2p)))

if failed_in_after:
    print('ERROR: {} test(s) have FAILED status in after.json:'.format(len(failed_in_after)), file=sys.stderr)
    for t in failed_in_after:
        print('  - {}'.format(t), file=sys.stderr)
    sys.exit(1)

if p2f:
    print('ERROR: {} test(s) went from PASSED to FAILED (regressions):'.format(len(p2f)), file=sys.stderr)
    for t in p2f:
        print('  - {}'.format(t), file=sys.stderr)
    sys.exit(1)

if not f2p:
    print('ERROR: No fail-to-pass tests found.', file=sys.stderr)
    sys.exit(1)

if new_tests:
    print('ERROR: {} test(s) appeared that were not in before.json - test count should remain the same.'.format(len(new_tests)), file=sys.stderr)
    print('Please modify parsing.py to ensure all tests are included in both before.json and after.json.', file=sys.stderr)
    for t in new_tests:
        print('  - {}'.format(t), file=sys.stderr)
    sys.exit(1)

if missing_tests:
    print('ERROR: {} test(s) disappeared that were in before.json but not in after.json - test count should remain the same.'.format(len(missing_tests)), file=sys.stderr)
    print('Please modify parsing.py to ensure all tests are included in both before.json and after.json.', file=sys.stderr)
    for t in missing_tests:
        print('  - {}'.format(t), file=sys.stderr)
    sys.exit(1)
PYEOF
then
  echo "verification_passed"
else
  echo "verification_failed"
  exit 1
fi
echo "Done."

