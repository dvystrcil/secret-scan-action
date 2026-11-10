#!/usr/bin/env bash
# Stage the late-run race (homelab#2079) for real and check both arms of
# .github/workflows/race-probe.yml.
#
#   1. branch race-probe/$TAG at $BASE_SHA plus one commit; open a PR
#   2. its race-probe run must pass: fixed AND control (the control works
#      while the PR exists, so its later failure is the race, not a broken job)
#   3. close the PR, delete the branch, wait until refs/pull/N/merge is gone
#   4. re-run the probe: a pull_request run starting after its PR is gone
#   5. fixed must pass having scanned >= 1 commit; control must fail with
#      'unknown revision', which shows the race was really staged
#
# Env: GH_TOKEN (contents, pull-requests and actions write), REPO (owner/name),
# BASE_SHA (the code under test), TAG (unique per run).
# Prints RACE-TEST-COMPLETE as its last line only if every check passed.
set -euo pipefail

: "${GH_TOKEN:?}" "${REPO:?}" "${BASE_SHA:?}" "${TAG:?}"
BRANCH="race-probe/$TAG"
WAIT=${RACE_TEST_WAIT_SECONDS:-900}
PR=""

fail() { echo "::error::$*"; exit 1; }

cleanup() {
  [ -n "$PR" ] && gh pr close "$PR" --repo "$REPO" >/dev/null 2>&1 || true
  gh api -X DELETE "repos/$REPO/git/refs/heads/$BRANCH" >/dev/null 2>&1 || true
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

probe_run() {
  gh run list --repo "$REPO" --workflow race-probe.yml --commit "$PROBE_SHA" \
    --event pull_request --json databaseId --jq '.[0].databaseId // empty'
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
gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$BASE_SHA" >/dev/null
PROBE_SHA=$(gh api -X PUT "repos/$REPO/contents/race-probe/$TAG.txt" \
  -f message="race-probe $TAG (throwaway, closed by race-test)" \
  -f content="$(printf 'race-probe %s\n' "$TAG" | base64)" \
  -f branch="$BRANCH" --jq .commit.sha)
PR=$(gh pr create --repo "$REPO" --base main --head "$BRANCH" \
  --title "race-probe $TAG (throwaway)" \
  --body "Opened by the race-test workflow; it closes this PR and deletes the branch itself." \
  | grep -oE '[0-9]+$')
echo "PR #$PR, probe commit $PROBE_SHA"

echo "== 2. first run, PR open"
RUN=$(wait_for "the race-probe run" probe_run)
wait_for "run $RUN attempt 1" attempt_done "$RUN" 1 >/dev/null
for job in fixed control; do
  c=$(job_field "$RUN" "$job" conclusion)
  echo "attempt 1 $job: $c"
  [ "$c" = success ] || fail "attempt 1: $job is '$c', expected success (PR still open)"
done

echo "== 3. close, delete branch, wait for the merge ref to go"
gh pr close "$PR" --repo "$REPO" >/dev/null
gh api -X DELETE "repos/$REPO/git/refs/heads/$BRANCH" >/dev/null
merge_ref_gone() {
  [ -z "$(git ls-remote "https://github.com/$REPO" "refs/pull/$PR/merge")" ] && echo gone
}
wait_for "refs/pull/$PR/merge to disappear" merge_ref_gone >/dev/null
[ -n "$(git ls-remote "https://github.com/$REPO" "refs/pull/$PR/head")" ] \
  || fail "refs/pull/$PR/head is gone too; the fix depends on it surviving"
git ls-remote "https://github.com/$REPO" "refs/heads/$BRANCH" | grep -q . \
  && fail "branch $BRANCH still exists"
echo "branch and refs/pull/$PR/merge gone, refs/pull/$PR/head present"

echo "== 4. re-run run $RUN after the PR is gone"
gh run rerun "$RUN" --repo "$REPO"
wait_for "run $RUN attempt 2" attempt_done "$RUN" 2 >/dev/null

echo "== 5. both arms"
fixed=$(job_field "$RUN" fixed conclusion)
control=$(job_field "$RUN" control conclusion)
echo "attempt 2 fixed: $fixed, control: $control"

[ "$control" = failure ] || fail "control is '$control', expected failure: the race was not staged"
job_log "$RUN" control | grep -q 'unknown revision' \
  || fail "control failed, but not on 'unknown revision': the race was not what failed it"

[ "$fixed" = success ] || fail "fixed is '$fixed' after the PR is gone: the action does not survive the race"
scanned=$(job_log "$RUN" fixed | grep -oE '[0-9]+ commits? scanned' | grep -oE '^[0-9]+' | tail -1)
[ "${scanned:-0}" -ge 1 ] || fail "fixed passed but scanned '${scanned:-nothing}' commits"

echo "RACE-TEST-COMPLETE pr=$PR run=$RUN fixed_commits_scanned=$scanned control=unknown-revision"
