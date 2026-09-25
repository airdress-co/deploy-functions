#!/usr/bin/env bash
# Run `airdress fn deploy --ci` once, keep what it printed, and expose it.
#
# Every decision is the CLI's: which functions changed, whether a newer
# commit supersedes this run, the base version, signing, publish, promote,
# the wait, and the write-back into each manifest. This script only turns
# the Action's inputs into flags, saves the JSON the CLI prints, and records
# its exit status so the write-back of the functions that did deploy is
# still committed when another one failed. A later step fails the job.
#
# Environment:
#   MACHINE_KEY_FILE, SIGNING_KEY_FILE   paths from write-secrets.sh
#   OPERATOR         optional; https://<fqdn> or an FQDN
#   MAP              the map file path
#   SIGNER_MACHINE   optional; defaults (in the CLI) to the enrolled machine
#   BRANCH           optional; defaults (in the CLI) to GITHUB_REF_NAME
#   BASE             optional; deploy what changed since this commit
#   ALL, PLAN        "true" or "false"
#   RUNNER_TEMP, GITHUB_OUTPUT   set by the runner
#
# Outputs: result (path of the CLI's JSON), exit-code, deployed.
set -uo pipefail

die() {
  echo "::error title=airdress deploy::$*" >&2
  exit 1
}

: "${RUNNER_TEMP:?RUNNER_TEMP is not set}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
: "${MACHINE_KEY_FILE:?MACHINE_KEY_FILE is not set}"
: "${SIGNING_KEY_FILE:?SIGNING_KEY_FILE is not set}"

bool() {
  case "$2" in
    true | false) ;;
    *) die "input $1 must be true or false, not '$2'" ;;
  esac
}
bool all "${ALL:-false}"
bool plan "${PLAN:-false}"

args=(functions deploy --ci --output json
  --machine-key "$MACHINE_KEY_FILE"
  --signing-key "$SIGNING_KEY_FILE")
[[ -n "${MAP:-}" ]] && args+=(--map "$MAP")
[[ -n "${SIGNER_MACHINE:-}" ]] && args+=(--signer-machine "$SIGNER_MACHINE")
[[ -n "${BRANCH:-}" ]] && args+=(--branch "$BRANCH")
if [[ "${ALL:-false}" == true ]]; then
  args+=(--all)
elif [[ -n "${BASE:-}" ]]; then
  args+=(--since "$BASE")
fi
[[ "${PLAN:-false}" == true ]] && args+=(--plan)

if [[ -n "${OPERATOR:-}" ]]; then
  export AIRDRESS_OPERATOR_URL="$OPERATOR"
fi
# Nothing on a runner can answer a prompt; the CLI never asks in CI mode,
# and this keeps it from waiting if that ever changed.
exec </dev/null

result="$RUNNER_TEMP/airdress-deployed.json"
echo "airdress ${args[*]}"
airdress "${args[@]}" >"$result"
code=$?

# The CLI prints a JSON array on stdout (one object per function), also
# when a function fails. A run that stopped before any function (no
# operator, an unreadable key) prints none; say so rather than guess.
if jq -e 'type == "array"' "$result" >/dev/null 2>&1; then
  deployed="$(jq -c '[.[] | {function, operator, previous, version, outcome}]' "$result")"
  jq -r '.[] | "\(.function) on \(.operator): \(.outcome)" +
    (if .message then " — \(.message)" else "" end) +
    ((.notes // []) | map("\n  " + .) | join(""))' "$result"
else
  echo "::error title=airdress deploy::the CLI exited $code and printed no result; its reason is in the log above"
  printf '[]\n' >"$result"
  deployed="[]"
fi

{
  echo "result=$result"
  echo "exit-code=$code"
  echo "deployed=$deployed"
} >>"$GITHUB_OUTPUT"
exit 0
