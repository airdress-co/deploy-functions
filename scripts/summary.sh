#!/usr/bin/env bash
# Write the job summary: one row per function the CLI reported, in the
# order it reported them, and below the table what the CLI said about the
# ones that did not deploy.
#
# Environment:
#   RESULT                the CLI's JSON (from deploy.sh); may be missing
#   PLAN                  "true" when the run was a plan
#   GITHUB_STEP_SUMMARY   set by the runner
set -euo pipefail

: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is not set}"
result="${RESULT:-}"

{
  if [[ "${PLAN:-false}" == true ]]; then
    echo "## Airdress functions: plan (nothing was written)"
  else
    echo "## Airdress functions"
  fi
  echo

  if [[ -z "$result" || ! -s "$result" ]] || ! jq -e 'type == "array"' "$result" >/dev/null 2>&1; then
    echo "The deploy did not run, or printed no result. The job log says why."
    exit 0
  fi
  if jq -e 'length == 0' "$result" >/dev/null; then
    echo "The CLI found no function to deploy."
    exit 0
  fi

  # Cells are escaped so a message with a pipe cannot break the table.
  jq -r '
    def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
    def code: if . == null or . == "" then "—" else "`" + (cell) + "`" end;
    def secs: if . == null then "—" else ((. / 100 | round) / 10 | tostring) + " s" end;
    "| Function | Operator | Previous | New | Outcome | Load time |",
    "|---|---|---|---|---|---|",
    (.[] | "| \(.function | cell) | \(.operator | cell) | \(.previous | code) | \(.version | code) | \(.outcome | code) | \(.elapsedMs | secs) |")
  ' "$result"

  details="$(jq -r '
    .[] | select(.message != null or ((.notes // []) | length) > 0 or .writeBack != null)
    | "- **\(.function)** (`\(.outcome)`"
      + (if .step then ", at \(.step)" else "" end) + ")"
      + (if .message then ": \(.message)" else "" end)
      + (if .writeBack then "\n  - wrote the served version into `\(.writeBack)`" else "" end)
      + ((.notes // []) | map("\n  - " + .) | join(""))
  ' "$result")"
  if [[ -n "$details" ]]; then
    echo
    echo "### Details"
    echo
    echo "$details"
  fi
} >>"$GITHUB_STEP_SUMMARY"
