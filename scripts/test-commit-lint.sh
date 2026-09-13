#!/usr/bin/env bash
#
# Self-test for the deterministic commit-message gate.
#
# The gate itself is `omni-dev git commit message lint` (see
# .github/workflows/commit-check.yml), configured by
# .omni-dev/commit-rules.yaml + .omni-dev/scopes.yaml. A linter that accepts
# everything looks exactly like a linter that works, so this script feeds it
# one message per rule that MUST be rejected, plus messages that MUST be
# accepted, and fails if any of them lands on the wrong side.
#
# Two of the fixtures double as configuration-load assertions, because
# omni-dev silently falls back to its built-in defaults when
# commit-rules.yaml is missing or malformed:
#
#   error.subject-length  76 characters — over our 72 limit, under the
#                         built-in default of 80.
#   error.missing-scope   no scope — an error only because we set
#                         require_scope, which defaults to false.
#
# Usage:
#   scripts/test-commit-lint.sh            # omni-dev from $PATH
#   OMNI_DEV=/path/to/omni-dev scripts/test-commit-lint.sh
#
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

OMNI_DEV=${OMNI_DEV:-omni-dev}
if ! command -v "$OMNI_DEV" >/dev/null 2>&1; then
  echo "error: omni-dev not found (looked for '$OMNI_DEV')." >&2
  echo "       Install it or set OMNI_DEV=/path/to/omni-dev." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required to read the lint report." >&2
  exit 1
fi

fixtures=tests/testdata/commit-lint

# Every rule the gate can fail on needs a fixture that provokes it, and every
# distinct accepted form needs one that proves it still passes. Deleting any
# of them is a silent loss of coverage, so the list is asserted by name rather
# than discovered by glob — a glob is satisfied by whichever file survives.
required_fixtures="
error.format
error.unknown-type
error.unknown-scope
error.missing-scope
error.subject-length
error.blank-line-after-subject
error.scope-comma-format
warning.forbidden-footer
info.lowercase-description
info.no-trailing-period
ok.subject-only
ok.multi-scope
ok.body-and-footer
ok.breaking-marker
"

failures=0

stderr_file=$(mktemp)
trap 'rm -f "$stderr_file"' EXIT

# Records one self-test failure and keeps going, so a single broken rule
# does not hide the state of the others.
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

for name in $required_fixtures; do
  if [ ! -f "$fixtures/$name.txt" ]; then
    fail "$name.txt is missing from $fixtures — a rule lost its coverage"
  fi
done

# omni-dev falls back to its built-in defaults, with only a tracing warning,
# when commit-rules.yaml cannot be read or parsed. Assert the values it
# actually resolved rather than inferring them. The output format is stable
# because the workflow pins the omni-dev version; if it ever changes, this
# fails loudly, which is the safe direction.
resolved=$(printf 'fix(ci): probe the resolved configuration\n' |
  "$OMNI_DEV" git commit message lint --stdin --verbose --context-dir .omni-dev/ 2>/dev/null |
  grep -F 'subject_max_len=' || true)
expected_config='subject_max_len=72, require_scope=true, types=10'
case "$resolved" in
  *"$expected_config"*) ;;
  '') fail "omni-dev reported no resolved rule configuration at all" ;;
  *)  fail "resolved config is [$(echo "$resolved" | tr -s ' ')], expected [$expected_config]" ;;
esac

for fixture in "$fixtures"/*.txt; do
  base=$(basename "$fixture" .txt)
  severity=${base%%.*}
  rule=${base#*.}

  case "$severity" in
    ok)      expected_exit=0 ;;
    info)    expected_exit=0 ;;
    warning) expected_exit=2 ;;
    error)   expected_exit=1 ;;
    *)
      fail "$base: filename must start with ok./info./warning./error."
      continue
      ;;
  esac

  actual_exit=0
  report=$("$OMNI_DEV" git commit message lint \
    --stdin --strict --output json --context-dir .omni-dev/ \
    <"$fixture" 2>"$stderr_file") || actual_exit=$?

  # Anything other than a parseable report means the lint did not run, which
  # is a failure of this fixture rather than a reason to abandon the suite.
  if ! printf '%s' "$report" | jq -e . >/dev/null 2>&1; then
    fail "$base: lint produced no parseable JSON report (exit $actual_exit)"
    cat "$stderr_file" >&2
    continue
  fi

  if [ "$actual_exit" -ne "$expected_exit" ]; then
    fail "$base: exit $actual_exit, expected $expected_exit"
    echo "$report" >&2
    cat "$stderr_file" >&2
    continue
  fi

  # Lists the rule ids the current $report reports at severity $1, sorted
  # and comma-joined, so it can be compared against the fixture's filename.
  rules_at() {
    printf '%s' "$report" |
      jq -r --arg sev "$1" \
        '[.commits[].issues[] | select(.severity == $sev) | .rule] | unique | join(",")'
  }
  total_issues=$(printf '%s' "$report" | jq -r '[.commits[].issues[]] | length')

  if [ "$severity" = "ok" ]; then
    if [ "$total_issues" -ne 0 ]; then
      fail "$base: expected a clean report, got $total_issues issue(s)"
      echo "$report" >&2
    fi
    continue
  fi

  got=$(rules_at "$severity")
  if [ "$got" != "$rule" ]; then
    fail "$base: $severity rules were [$got], expected [$rule]"
    echo "$report" >&2
    continue
  fi

  # A lower-severity fixture must not be smuggling a higher-severity issue
  # past us: that would make its exit code right for the wrong reason.
  case "$severity" in
    warning)
      [ -z "$(rules_at error)" ] || fail "$base: unexpected error-severity issues"
      ;;
    info)
      [ -z "$(rules_at error)" ] || fail "$base: unexpected error-severity issues"
      [ -z "$(rules_at warning)" ] || fail "$base: unexpected warning-severity issues"
      ;;
  esac
done

if [ "$failures" -ne 0 ]; then
  echo "commit-lint self-test: $failures failure(s)" >&2
  exit 1
fi

echo "commit-lint self-test: all fixtures behaved as specified"
