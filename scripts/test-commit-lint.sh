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

# Every rule the gate can fail on needs a fixture that provokes it. Deleting
# a fixture is a silent loss of coverage, so the list is asserted, not
# discovered.
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
"

failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

for name in $required_fixtures; do
  if [ ! -f "$fixtures/$name.txt" ]; then
    fail "$name.txt is missing from $fixtures — a rule lost its coverage"
  fi
done

if ! ls "$fixtures"/ok.*.txt >/dev/null 2>&1; then
  fail "no ok.*.txt fixtures — nothing proves the gate accepts a good message"
fi

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
    <"$fixture" 2>&1) || actual_exit=$?

  if [ "$actual_exit" -ne "$expected_exit" ]; then
    fail "$base: exit $actual_exit, expected $expected_exit"
    echo "$report" >&2
    continue
  fi

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
