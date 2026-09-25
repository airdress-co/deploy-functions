#!/usr/bin/env bash
# Commit the served versions the CLI wrote back into the manifests.
#
# After a promote, the CLI rewrites exactly one line of each deployed
# function's manifest, `spec.source.version`, and never commits. The next
# run reads that line at the branch head as its base, so it has to reach
# the branch. This script does only the git part:
#
#   commit        one commit per function, "functions: serve <version> for
#                 <name>", as github-actions[bot], pushed to the branch.
#                 A rejected push is retried once after `git pull --rebase`;
#                 a second failure is write_back_failed.
#   pull-request  the same commits on a new branch, and a pull request to
#                 the deploying branch.
#   off           print the lines to commit, and commit nothing.
#
# A push made with the workflow's GITHUB_TOKEN starts no new workflow run,
# so the default mode does not loop.
#
# Environment:
#   MODE              commit | pull-request | off
#   RESULT            the CLI's JSON (from deploy.sh)
#   BRANCH            the deploying branch; defaults to GITHUB_REF_NAME
#   GH_TOKEN          pull-request mode: a token that may open pull requests
#   GITHUB_REF_TYPE, GITHUB_REF_NAME, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT,
#   GITHUB_STEP_SUMMARY   set by the runner
set -euo pipefail

mode="${MODE:-commit}"
case "$mode" in
  commit | pull-request | off) ;;
  *)
    echo "::error title=airdress write-back::write-back must be commit, pull-request or off, not '$mode'" >&2
    exit 1
    ;;
esac

result="${RESULT:-}"
if [[ -z "$result" || ! -s "$result" ]]; then
  echo "no deploy result; nothing to write back"
  exit 0
fi

# function <TAB> version <TAB> manifest path, for each manifest the CLI
# rewrote.
mapfile -t rows < <(jq -r '.[] | select(.writeBack != null)
  | [.function, (.version // ""), .writeBack] | @tsv' "$result")
if ((${#rows[@]} == 0)); then
  echo "no manifest was rewritten; nothing to write back"
  exit 0
fi

top="$(git rev-parse --show-toplevel)"
names=() versions=() paths=() lines=()
for row in "${rows[@]}"; do
  IFS=$'\t' read -r name version path <<<"$row"
  rel="$path"
  [[ "$rel" == "$top"/* ]] && rel="${rel#"$top"/}"
  names+=("$name")
  versions+=("$version")
  paths+=("$path")
  lines+=("$rel: spec.source.version: \"$version\"")
done

print_lines() {
  local l
  for l in "${lines[@]}"; do echo "  $l"; done
}

write_back_failed() {
  echo "::error title=write_back_failed::$1. These versions are serving, and git does not say so yet; the next deploy of these functions is refused as a stale base until it does. Commit these lines to ${branch:-the branch} by hand:" >&2
  print_lines >&2
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo
      echo "### write_back_failed"
      echo
      echo "$1. These versions are serving; commit these lines by hand:"
      echo
      echo '```text'
      print_lines
      echo '```'
    } >>"$GITHUB_STEP_SUMMARY"
  fi
  exit 1
}

if [[ "$mode" == off ]]; then
  echo "write-back is off; the served versions to commit:"
  print_lines
  echo "::notice title=airdress write-back::write-back is off: ${#lines[@]} manifest line(s) to commit are in the log"
  exit 0
fi

if [[ -z "${BRANCH:-}" && -n "${GITHUB_REF_TYPE:-}" && "$GITHUB_REF_TYPE" != branch ]]; then
  write_back_failed "this run is for a $GITHUB_REF_TYPE, not a branch"
fi
branch="${BRANCH:-${GITHUB_REF_NAME:-}}"
[[ -n "$branch" ]] || write_back_failed "no branch to write back to"

# The identity goes in the environment, which wins over any git config
# and over identity variables a workflow may have set.
as_bot() {
  local name="github-actions[bot]"
  local email="41898282+github-actions[bot]@users.noreply.github.com"
  GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" \
    GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" git "$@"
}

commit_all() {
  local i
  for i in "${!paths[@]}"; do
    git add -- "${paths[$i]}"
    if git diff --cached --quiet -- "${paths[$i]}"; then
      echo "${lines[$i]%%:*} is already committed as it is; skipping"
      continue
    fi
    as_bot commit --quiet \
      -m "functions: serve ${versions[$i]} for ${names[$i]}" -- "${paths[$i]}"
    echo "committed: functions: serve ${versions[$i]} for ${names[$i]}"
  done
}

commit_all || write_back_failed "could not commit the rewritten manifests"

if [[ "$mode" == commit ]]; then
  if git push --quiet origin "HEAD:refs/heads/$branch"; then
    echo "pushed to $branch"
    exit 0
  fi
  echo "the push to $branch was rejected; pulling with rebase and trying once more"
  if ! as_bot pull --quiet --rebase --autostash origin "$branch"; then
    git rebase --abort >/dev/null 2>&1 || true
    write_back_failed "could not rebase onto $branch"
  fi
  if git push --quiet origin "HEAD:refs/heads/$branch"; then
    echo "pushed to $branch after rebasing"
    exit 0
  fi
  write_back_failed "the push to $branch was rejected twice"
fi

# pull-request
head="airdress-functions/serve-${GITHUB_RUN_ID:-$(date +%s)}-${GITHUB_RUN_ATTEMPT:-1}"
git push --quiet origin "HEAD:refs/heads/$head" ||
  write_back_failed "could not push the branch $head"

if ((${#names[@]} == 1)); then
  title="functions: serve ${versions[0]} for ${names[0]}"
else
  title="functions: serve the versions now running (${#names[@]} functions)"
fi
body="$(
  echo "These versions are serving now. This pull request makes the manifests say so."
  echo
  echo '```text'
  print_lines
  echo '```'
  echo
  echo "Merge it before these functions are deployed again: until then the next deploy reads the old version as its base and is refused as stale."
)"
if ! url="$(gh pr create --base "$branch" --head "$head" --title "$title" --body "$body")"; then
  write_back_failed "pushed $head, but could not open a pull request from it"
fi
echo "opened $url"
