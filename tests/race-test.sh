#!/usr/bin/env bash
# Stage the late-run race (homelab#2079) for real and check both arms of
# .github/workflows/race-probe.yml.
#
#   1. base branch race-base/$TAG at $BASE_SHA; head branch race-probe/$TAG
#      = $BASE_SHA plus one commit; open a PR head -> base
#   2. its race-probe run must pass: fixed AND control (the control works
#      while the PR exists, so its later failure is the race, not a broken job)
#   3. SQUASH-MERGE it into race-base, delete the head branch, wait until
#      refs/pull/N/merge is gone
#   4. the merge fires race-probe's pull_request `closed` run; once that has
#      finished, re-run it, so it certainly starts with the branch gone
#
# What makes it the homelab#2077 race: a pull_request run CREATED after the
# squash merge. Its sha is the squash commit, which does not contain the
# PR's commits, and its merge ref is gone, so a default checkout cannot reach
# them. The `closed` run is created after the merge every time; a re-run
# keeps its sha. Two shapes that do NOT reproduce it (tried 2026-11-10):
#   - close without merging: the test merge commit stays fetchable by sha
#     (run 42875520650);
#   - re-run the run from while the PR was open: a re-run keeps the old
#     test merge sha, still fetchable (run 42875923046).
# Merging into a throwaway base branch keeps main untouched; both branches
# are deleted afterwards.
#   5. fixed must pass having scanned >= 1 commit; control must fail with
#      'unknown revision', which shows the race was really staged
#
# Env: GH_TOKEN (contents, pull-requests and actions write), REPO (owner/name),
# BASE_SHA (the code under test), TAG (unique per run).
# Prints RACE-TEST-COMPLETE as its last line only if every check passed.
set -euo pipefail

: "${GH_TOKEN:?}" "${REPO:?}" "${BASE_SHA:?}" "${TAG:?}"
BRANCH="race-probe/$TAG"
BASE="race-base/$TAG"
WAIT=${RACE_TEST_WAIT_SECONDS:-900}
PR=""

fail() { echo "::error::$*"; exit 1; }

cleanup() {
  [ -n "$PR" ] && gh pr close "$PR" --repo "$REPO" >/dev/null 2>&1 || true
  gh api -X DELETE "repos/$REPO/git/refs/heads/$BRANCH" >/dev/null 2>&1 || true
  gh api -X DELETE "repos/$REPO/git/refs/heads/$BASE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Poll until the command prints something non-empty; print that.
wait_for() {
  local what=$1; shift
  local deadline=$((SECONDS + WAIT)) out
  while :; do
    out=$("$@" 2>/dev/null || true)
    [ -n "$out" ] && { echo "$out"; return 0; }
    [ "$SECONDS" -ge "$deadline" ] && fail "timed out after ${WAIT}s waiting for $what"
    sleep 10
  done
}

# race-probe runs for the probe commit other than $1 (newest first).
probe_run() {
  gh run list --repo "$REPO" --workflow race-probe.yml --commit "$PROBE_SHA" \
    --event pull_request --json databaseId \
    --jq "[.[] | select(.databaseId != ${1:-0})][0].databaseId // empty"
}

# Print the run id once attempt $2 of run $1 has completed.
attempt_done() {
  gh run view "$1" --repo "$REPO" --json attempt,status \
    --jq "select(.attempt == $2 and .status == \"completed\") | \"done\""
}

job_field() {  # run, job name, field -> value
  gh run view "$1" --repo "$REPO" --json jobs \
    --jq ".jobs[] | select(.name == \"$2\") | .$3"
}

job_log() {  # run, job name -> log without colour codes
  gh run view "$1" --repo "$REPO" --log --job "$(job_field "$1" "$2" databaseId)" \
    | sed 's/\x1b\[[0-9;]*m//g'
}

echo "== 1. throwaway PR from $BASE_SHA"
gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$BASE" -f sha="$BASE_SHA" >/dev/null
gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$BASE_SHA" >/dev/null
PROBE_SHA=$(gh api -X PUT "repos/$REPO/contents/race-probe/$TAG.txt" \
  -f message="race-probe $TAG (throwaway, closed by race-test)" \
  -f content="$(printf 'race-probe %s\n' "$TAG" | base64)" \
  -f branch="$BRANCH" --jq .commit.sha)
PR=$(gh pr create --repo "$REPO" --base "$BASE" --head "$BRANCH" \
  --title "race-probe $TAG (throwaway)" \
  --body "Opened by the race-test workflow; it squash-merges this PR into its own throwaway base branch and deletes both branches." \
  | grep -oE '[0-9]+$')
echo "PR #$PR, probe commit $PROBE_SHA"

echo "== 2. first run, PR open"
OPEN_RUN=$(wait_for "the race-probe run" probe_run)
wait_for "run $OPEN_RUN attempt 1" attempt_done "$OPEN_RUN" 1 >/dev/null
for job in fixed control; do
  c=$(job_field "$OPEN_RUN" "$job" conclusion)
  echo "attempt 1 $job: $c"
  [ "$c" = success ] || fail "attempt 1: $job is '$c', expected success (PR still open)"
done

echo "== 3. squash-merge into $BASE, delete the head branch, wait for the merge ref to go"
gh api -X PUT "repos/$REPO/pulls/$PR/merge" -f merge_method=squash --jq .sha
# delete_branch_on_merge may have removed it already.
gh api -X DELETE "repos/$REPO/git/refs/heads/$BRANCH" >/dev/null 2>&1 || true
merge_ref_gone() {
  [ -z "$(git ls-remote "https://github.com/$REPO" "refs/pull/$PR/merge")" ] && echo gone
}
wait_for "refs/pull/$PR/merge to disappear" merge_ref_gone >/dev/null
[ -n "$(git ls-remote "https://github.com/$REPO" "refs/pull/$PR/head")" ] \
  || fail "refs/pull/$PR/head is gone too; the fix depends on it surviving"
git ls-remote "https://github.com/$REPO" "refs/heads/$BRANCH" | grep -q . \
  && fail "branch $BRANCH still exists"
echo "branch and refs/pull/$PR/merge gone, refs/pull/$PR/head present"

echo "== 4. the 'closed' run, re-run with the branch gone"
RUN=$(wait_for "the race-probe run for the merge" probe_run "$OPEN_RUN")
wait_for "run $RUN attempt 1" attempt_done "$RUN" 1 >/dev/null
echo "run $RUN attempt 1 (branch deletion may have raced it): fixed=$(job_field "$RUN" fixed conclusion) control=$(job_field "$RUN" control conclusion)"
gh run rerun "$RUN" --repo "$REPO"
wait_for "run $RUN attempt 2" attempt_done "$RUN" 2 >/dev/null

echo "== 5. both arms"
fixed=$(job_field "$RUN" fixed conclusion)
control=$(job_field "$RUN" control conclusion)
echo "attempt 2 fixed: $fixed, control: $control"

[ "$control" = failure ] || fail "control is '$control', expected failure: the race was not staged"
# Capture first: `job_log | grep -q` dies of SIGPIPE under pipefail on a match.
control_log=$(job_log "$RUN" control)
grep -q 'unknown revision' <<<"$control_log" \
  || fail "control failed, but not on 'unknown revision': the race was not what failed it"

[ "$fixed" = success ] || fail "fixed is '$fixed' after the PR merged: the action does not survive the race"
fixed_log=$(job_log "$RUN" fixed)
scanned=$(grep -oE '[0-9]+ commits? scanned' <<<"$fixed_log" | grep -oE '^[0-9]+' | tail -1)
[ "${scanned:-0}" -ge 1 ] || fail "fixed passed but scanned '${scanned:-nothing}' commits"

echo "RACE-TEST-COMPLETE pr=$PR run=$RUN fixed_commits_scanned=$scanned control=unknown-revision"
