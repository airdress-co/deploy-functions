#!/usr/bin/env bash
# Drive scripts/commit-write-back.sh against throwaway git repositories:
# a bare "origin" and a clone standing in for the runner's checkout, with a
# manifest the CLI has just rewritten. No network, no operator.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../scripts/commit-write-back.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

pass=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() {
  echo "ok - $*"
  pass=$((pass + 1))
}

OLD="sha256:1111111111111111111111111111111111111111111111111111111111111111"
NEW="sha256:2222222222222222222222222222222222222222222222222222222222222222"

manifest() {
  cat <<EOF
apiVersion: airdress.co/v1alpha1
kind: Function
metadata:
  name: $1
spec:
  runtime: js-source/v1
  source:
    version: "$2"
    signers:
      - machine: "0b7e3c1a-5d2f-4c1e-9a07-3f6b2d8e4c10"
  enabled: true
EOF
}

# setup <name>: $origin (bare) and $repo (a clone on main), holding
# functions/relay/function.yaml at OLD, then rewritten to NEW the way the
# CLI does, with $result naming it.
setup() {
  local d="$work/$1"
  origin="$d/origin.git"
  repo="$d/repo"
  git init --quiet --bare --initial-branch=main "$origin"
  git init --quiet --initial-branch=main "$d/seed"
  mkdir -p "$d/seed/functions/relay" "$d/seed/functions/digest"
  manifest relay "$OLD" >"$d/seed/functions/relay/function.yaml"
  manifest digest "$OLD" >"$d/seed/functions/digest/function.yaml"
  echo "readme" >"$d/seed/README.md"
  git -C "$d/seed" add -A
  git -C "$d/seed" commit --quiet -m init
  git -C "$d/seed" push --quiet "$origin" main
  git clone --quiet "$origin" "$repo"
  sed -i.bak "s|$OLD|$NEW|" "$repo/functions/relay/function.yaml"
  rm -f "$repo/functions/relay/function.yaml.bak"
  result="$d/deployed.json"
  cat >"$result" <<EOF
[
  {"function":"relay","operator":"op.example","previous":"$OLD","version":"$NEW",
   "outcome":"deployed","elapsedMs":1234,"writeBack":"$repo/functions/relay/function.yaml"},
  {"function":"digest","operator":"op.example","previous":"$OLD","version":null,
   "outcome":"skipped","message":"nothing under function.json or src/ changed"}
]
EOF
  summary="$d/summary.md"
  : >"$summary"
}

run() {
  # run <mode> [extra env...]: runs the script in $repo; sets $out and $code.
  local mode="$1"
  shift
  set +e
  out="$(cd "$repo" && env MODE="$mode" RESULT="$result" GITHUB_REF_NAME=main \
    GITHUB_REF_TYPE=branch GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 \
    GITHUB_STEP_SUMMARY="$summary" "$@" bash "$script" 2>&1)"
  code=$?
  set -e
}

origin_version() {
  git -C "$origin" show "main:functions/relay/function.yaml" | sed -n 's/^    version: //p'
}

# --- off: prints the line, commits nothing -------------------------------
setup off
run off
[[ $code -eq 0 ]] || fail "off exited $code: $out"
grep -qF "functions/relay/function.yaml: spec.source.version: \"$NEW\"" <<<"$out" ||
  fail "off did not print the line: $out"
[[ "$(git -C "$repo" rev-list --count HEAD)" -eq 1 ]] || fail "off committed"
ok "off prints the line to commit and commits nothing"

# --- commit: one commit, as the bot, pushed ------------------------------
setup commit
run commit
[[ $code -eq 0 ]] || fail "commit exited $code: $out"
[[ "$(origin_version)" == "\"$NEW\"" ]] || fail "origin does not serve NEW: $(origin_version)"
msg="$(git -C "$origin" log -1 --format=%s main)"
[[ "$msg" == "functions: serve $NEW for relay" ]] || fail "message: $msg"
who="$(git -C "$origin" log -1 --format='%an <%ae>' main)"
[[ "$who" == "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>" ]] ||
  fail "author: $who"
[[ "$(git -C "$origin" diff --name-only main~1 main)" == "functions/relay/function.yaml" ]] ||
  fail "the commit touches more than the manifest"
ok "commit pushes one commit, as github-actions[bot], touching only the manifest"

# --- commit: the branch moved elsewhere; rebase once, then push ----------
setup moved
git clone --quiet "$origin" "$work/moved/other"
echo "more" >>"$work/moved/other/README.md"
git -C "$work/moved/other" commit --quiet -am "unrelated change"
git -C "$work/moved/other" push --quiet origin main
echo "untracked build output" >"$repo/stray.txt"
run commit
[[ $code -eq 0 ]] || fail "moved exited $code: $out"
grep -q "pulling with rebase" <<<"$out" || fail "moved did not retry: $out"
[[ "$(origin_version)" == "\"$NEW\"" ]] || fail "moved: origin does not serve NEW"
[[ "$(git -C "$origin" log -2 --format=%s main | tail -1)" == "unrelated change" ]] ||
  fail "moved: the unrelated commit is not under the write-back"
ok "commit retries once after pull --rebase when the branch moved"

# --- commit: the same line changed upstream; write_back_failed -----------
setup conflict
git clone --quiet "$origin" "$work/conflict/other"
sed -i.bak "s|$OLD|sha256:3333|" "$work/conflict/other/functions/relay/function.yaml"
git -C "$work/conflict/other" commit --quiet -am "someone else"
git -C "$work/conflict/other" push --quiet origin main
run commit
[[ $code -eq 1 ]] || fail "conflict exited $code: $out"
grep -q "write_back_failed" <<<"$out" || fail "conflict: no write_back_failed: $out"
grep -qF "spec.source.version: \"$NEW\"" <<<"$out" || fail "conflict: no line: $out"
grep -q "write_back_failed" "$summary" || fail "conflict: summary says nothing"
[[ ! -d "$repo/.git/rebase-merge" && ! -d "$repo/.git/rebase-apply" ]] ||
  fail "conflict: a rebase was left in progress"
ok "commit fails write_back_failed, with the line, when the rebase conflicts"

# --- commit: a protected branch refuses every push -----------------------
setup protected
cat >"$origin/hooks/pre-receive" <<'EOF'
#!/bin/sh
echo "protected branch: changes must be made through a pull request" >&2
exit 1
EOF
chmod +x "$origin/hooks/pre-receive"
run commit
[[ $code -eq 1 ]] || fail "protected exited $code: $out"
grep -q "rejected twice" <<<"$out" || fail "protected: $out"
grep -qF "functions/relay/function.yaml: spec.source.version: \"$NEW\"" <<<"$out" ||
  fail "protected: no line: $out"
ok "commit to a protected branch fails write_back_failed, naming the line"

# --- commit from a detached HEAD -----------------------------------------
setup detached
git -C "$repo" checkout --quiet --detach
run commit
[[ $code -eq 0 ]] || fail "detached exited $code: $out"
[[ "$(origin_version)" == "\"$NEW\"" ]] || fail "detached: origin does not serve NEW"
ok "commit works from a detached HEAD"

# --- pull-request: a branch and a pull request, not a push to main -------
setup pr
mkdir -p "$work/pr/bin"
cat >"$work/pr/bin/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >"$work/pr/gh-args"
echo "https://github.com/example/repo/pull/7"
EOF
chmod +x "$work/pr/bin/gh"
run pull-request PATH="$work/pr/bin:$PATH" GH_TOKEN=dummy
[[ $code -eq 0 ]] || fail "pr exited $code: $out"
[[ "$(origin_version)" == "\"$OLD\"" ]] || fail "pr pushed to main"
git -C "$origin" rev-parse --quiet --verify "refs/heads/airdress-functions/serve-42-1" >/dev/null ||
  fail "pr: no branch"
{ grep -qx -- "--base" "$work/pr/gh-args" && grep -qx "main" "$work/pr/gh-args"; } ||
  fail "pr: gh was not asked for a pull request to main: $(cat "$work/pr/gh-args")"
grep -qx "functions: serve $NEW for relay" "$work/pr/gh-args" || fail "pr: title"
ok "pull-request pushes a branch and opens a pull request to main"

# --- nothing rewritten; a bad mode ---------------------------------------
setup none
echo '[{"function":"relay","operator":"o","previous":null,"version":null,"outcome":"skipped"}]' >"$result"
run commit
{ [[ $code -eq 0 ]] && grep -q "nothing to write back" <<<"$out"; } || fail "none: $code $out"
ok "nothing rewritten, nothing committed"

run sideways
[[ $code -eq 1 ]] || fail "a bad mode exited $code"
ok "an unknown mode is refused"

# --- a tag run has no branch to write to ---------------------------------
setup tag
run commit GITHUB_REF_TYPE=tag
{ [[ $code -eq 1 ]] && grep -q "write_back_failed" <<<"$out"; } || fail "tag: $code $out"
ok "a run for a tag fails write_back_failed"

echo "all $pass passed"
