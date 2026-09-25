#!/usr/bin/env bash
# A plan run of each example through the Action's own scripts, with no
# operator to answer it.
#
# Each example is copied into a throwaway git repository with an origin,
# as a runner's checkout would be, and deployed with `plan: true` and a
# throwaway machine whose id is the one the examples list as a signer. The
# operators the examples name are under `.example`, which never resolves,
# so every function stops at its first request. That point is the test:
# the CLI parsed the map file, found every function it names, read each
# manifest at the branch head, and accepted this machine as a member of
# each signer set. A broken example stops earlier, with layout_invalid or
# signer_not_this_client.
#
# Needs `airdress` on PATH (scripts/install-cli.sh puts it there) and jq.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

MACHINE="0b7e3c1a-5d2f-4c1e-9a07-3f6b2d8e4c10"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# A machine key is a 32-byte seed, base64url without padding; the signing
# seed is 32 bytes of hex. Both are thrown away with $work.
machine_key="$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')"
signing_key="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
enrollment="{\"operator\":\"https://prod.operator.example\",\"machine_id\":\"$MACHINE\",\"kid\":\"k-test\"}"

check() {
  # check <example> <expected function names, in order>
  local example="$1" expected="$2"
  local d="$work/$example"
  mkdir -p "$d"
  git init --quiet --bare --initial-branch=main "$d/origin.git"
  cp -R "$root/examples/$example" "$d/repo"
  git -C "$d/repo" init --quiet --initial-branch=main
  git -C "$d/repo" add -A
  git -C "$d/repo" commit --quiet -m "the example"
  git -C "$d/repo" remote add origin "$d/origin.git"
  git -C "$d/repo" push --quiet origin main

  export RUNNER_TEMP="$d/runner-temp" GITHUB_OUTPUT="$d/output" GITHUB_STEP_SUMMARY="$d/summary.md"
  mkdir -p "$RUNNER_TEMP"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"

  MACHINE_KEY="$machine_key" MACHINE_ENROLLMENT="$enrollment" SIGNING_KEY="$signing_key" \
    bash "$root/scripts/write-secrets.sh" >/dev/null
  local key seed
  key="$(sed -n 's/^machine-key=//p' "$GITHUB_OUTPUT")"
  seed="$(sed -n 's/^signing-key=//p' "$GITHUB_OUTPUT")"
  [[ "$(stat -c %a "$key" 2>/dev/null || stat -f %Lp "$key")" == 600 ]] || fail "$example: key is not 0600"

  (cd "$d/repo" && MACHINE_KEY_FILE="$key" SIGNING_KEY_FILE="$seed" \
    MAP=airdress.functions.yaml BRANCH=main ALL=true PLAN=true OPERATOR="" \
    bash "$root/scripts/deploy.sh")
  local result code
  result="$(sed -n 's/^result=//p' "$GITHUB_OUTPUT")"
  code="$(sed -n 's/^exit-code=//p' "$GITHUB_OUTPUT")"
  [[ "$code" != 0 ]] || fail "$example: a plan with no operator cannot succeed, yet exited 0"

  local names
  names="$(jq -r '[.[].function] | join(" ")' "$result")"
  [[ "$names" == "$expected" ]] || fail "$example: functions '$names', expected '$expected'"

  local early
  early="$(jq -r '.[] | select(.outcome == "layout_invalid" or .outcome == "signer_not_this_client"
      or .outcome == "signer_unavailable" or .outcome == "superseded")
    | "\(.function): \(.outcome): \(.message)"' "$result")"
  [[ -z "$early" ]] || fail "$example stopped before the operator: $early"
  jq -e 'all(.[]; (.message // "") | test("could not connect|dns|resolve"; "i"))' "$result" >/dev/null ||
    fail "$example: not every function reached its first request: $(jq -c . "$result")"

  RESULT="$result" PLAN=true bash "$root/scripts/summary.sh"
  grep -q '^| Function | Operator | Previous | New | Outcome | Load time |$' "$GITHUB_STEP_SUMMARY" ||
    fail "$example: no summary table"
  [[ "$(grep -c '^|' "$GITHUB_STEP_SUMMARY")" -eq $((2 + $(wc -w <<<"$expected"))) ]] ||
    fail "$example: the summary has the wrong number of rows"

  (cd "$d/repo" && MODE=commit RESULT="$result" BRANCH=main bash "$root/scripts/commit-write-back.sh") |
    grep -q "nothing to write back" || fail "$example: a plan wrote something back"
  [[ -z "$(git -C "$d/repo" status --porcelain)" ]] || fail "$example: a plan changed the checkout"

  echo "ok - $example: $expected"
}

command -v airdress >/dev/null || fail "airdress is not on PATH; run scripts/install-cli.sh first"
check single-function "hello"
check monorepo "relay digest digest"
