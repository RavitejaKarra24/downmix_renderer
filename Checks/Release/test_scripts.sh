#!/usr/bin/env bash
# Isolated orchestration checks. Never build/launch/kill the real app or touch audio.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/downmix-release-check.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
FIXTURE="$TEST_DIR/repo"
mkdir -p "$FIXTURE/Scripts" "$TEST_DIR/bin" "$TEST_DIR/outside"
cp "$ROOT/Scripts/compile_and_run.sh" "$ROOT/Scripts/check_release.sh" \
  "$ROOT/Scripts/package_zip.sh" "$ROOT/Scripts/check_whitespace.sh" "$FIXTURE/Scripts/"
printf 'APP_NAME=DownmixFixture\nMARKETING_VERSION=1.0.0\nBUILD_NUMBER=1\n' > "$FIXTURE/version.env"
export TEST_LOG="$TEST_DIR/events" CHECK_RESULT=0 UI_RESULT=0 PACKAGE_RESULT=0
cat > "$FIXTURE/Scripts/check.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf 'check\n' >> "$TEST_LOG"
exit "$CHECK_RESULT"
SCRIPT
cat > "$FIXTURE/Scripts/check_ui.sh" <<'SCRIPT'
#!/usr/bin/env bash
[[ "$*" == --rendered ]] || exit 99
printf 'ui\n' >> "$TEST_LOG"
exit "$UI_RESULT"
SCRIPT
cat > "$FIXTURE/Scripts/package_app.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf 'package\n' >> "$TEST_LOG"
exit "$PACKAGE_RESULT"
SCRIPT
for command in pkill open pgrep; do
  printf '#!/usr/bin/env bash\nprintf "%s\\n" >> "$TEST_LOG"\nexit 0\n' "$command" > "$TEST_DIR/bin/$command"
done
chmod +x "$FIXTURE/Scripts/"*.sh "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH"
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_events() {
  local actual
  actual="$(tr '\n' ' ' < "$TEST_LOG")"
  [[ "$actual" == "$1" ]] || fail "expected '$1', got '$actual'"
}
run_relaunch() { (cd "$TEST_DIR/outside" && "$FIXTURE/Scripts/compile_and_run.sh" --test); }
: > "$TEST_LOG"
CHECK_RESULT=7
if run_relaunch > "$TEST_DIR/log" 2>&1; then fail 'failed check accepted'; fi
expect_events 'check '
CHECK_RESULT=0
UI_RESULT=8
: > "$TEST_LOG"
if run_relaunch > "$TEST_DIR/log" 2>&1; then fail 'failed UI accepted'; fi
expect_events 'check ui '
UI_RESULT=0
PACKAGE_RESULT=9
: > "$TEST_LOG"
if run_relaunch > "$TEST_DIR/log" 2>&1; then fail 'failed package accepted'; fi
expect_events 'check ui package '
PACKAGE_RESULT=0
: > "$TEST_LOG"
run_relaunch > "$TEST_DIR/log" 2>&1
expect_events 'check ui package pkill pkill pkill pkill open pgrep '
# A UI failure in the supported archive command must preserve the prior download.
printf 'previous archive\n' > "$FIXTURE/DownmixFixture.zip"
cp "$FIXTURE/DownmixFixture.zip" "$TEST_DIR/previous.zip"
UI_RESULT=8
: > "$TEST_LOG"
if "$FIXTURE/Scripts/package_zip.sh" > "$TEST_DIR/log" 2>&1; then fail 'archive accepted failed UI'; fi
expect_events 'check ui '
cmp "$FIXTURE/DownmixFixture.zip" "$TEST_DIR/previous.zip" || fail 'previous archive replaced'
# Hosted whitespace checks must find committed errors in a clean checkout.
cd "$FIXTURE"
git init -q
git config user.email fixture@example.invalid
git config user.name Fixture
printf 'clean\n' > example.md
git add example.md
git commit -qm clean
BASE="$(git rev-parse HEAD)"
"$FIXTURE/Scripts/check_whitespace.sh" '' "$BASE"
printf 'bad whitespace  \n' >> example.md
git add example.md
git commit -qm bad
HEAD="$(git rev-parse HEAD)"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail 'fixture should be clean'
if "$FIXTURE/Scripts/check_whitespace.sh" "$BASE" "$HEAD" > "$TEST_DIR/log" 2>&1; then
  fail 'committed whitespace escaped range check'
fi
if "$FIXTURE/Scripts/check_whitespace.sh" 0000000000000000000000000000000000000000 "$HEAD" > "$TEST_DIR/log" 2>&1; then
  fail 'initial-push whitespace escaped full-tree check'
fi
echo 'Release script checks passed (failed gates preserve app/download; correct suite from any cwd; clean-checkout whitespace).'
