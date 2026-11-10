# secret-scan-action

gitleaks secret scanning for every `dvystrcil` repo, as one composite action
instead of a copy of the same workflow in 100+ repos.

```yaml
# .github/workflows/secret-scan.yml
name: secret-scan
on:
  pull_request:
  push:
    branches: [main]

jobs:
  gitleaks:
    runs-on: homelab-runner        # or this repo's ARC scale set / ubuntu-latest
    permissions:
      contents: read
      pull-requests: read          # gitleaks-action lists PR commits via the API
    steps:
      - uses: dvystrcil/secret-scan-action@v1
```

The action does its own checkout. Do not add an `actions/checkout` step before it.
The repo's own `.gitleaks.toml` (allowlists, extended rules) is still read from the
checked-out tree.

## What it does

1. `actions/checkout` at **the PR's head SHA** (`github.sha` on push), `fetch-depth: 0`.
2. `gitleaks/gitleaks-action`, which scans `<first PR commit>^..<head>` on a PR and
   the pushed range on `main`.

## Why the checkout is not the default

A `pull_request` run can start **after** the PR merged. homelab#2077 merged 20 s
after it was opened, and its scan started 25 s after that. By then the head branch
was auto-deleted and `refs/pull/N/merge` was gone, so a default checkout fell back
to `main`. gitleaks-action then ran `git log <head>^..<head>` on a commit the clone
did not have, failed with `unknown revision`, and scanned 0 bytes
([homelab#2079](https://github.com/dvystrcil/homelab/issues/2079)).

`refs/pull/N/head` survives the merge and the branch deletion, so checking out the
head SHA scans the PR's real commits however late the run starts. Reproduced live
for homelab#2079:

| run | checkout | branch + merge ref | result |
|---|---|---|---|
| old workflow, re-run | default | deleted | `unknown revision`, 0 bytes scanned |
| fixed workflow, re-run | PR head SHA | deleted | 2 commits scanned, pass |

## License

[MIT](LICENSE)

## Releasing

Consumers pin `@v1`, so **moving `v1` is the release** to every repo. Merging to
`main` releases nothing.

```bash
# first release only: v0.0.0 -> v1.0.0, creates v1
gh workflow run release.yaml --repo dvystrcil/secret-scan-action -f bump=major
# after that
gh workflow run release.yaml --repo dvystrcil/secret-scan-action -f bump=patch
```

Every release first runs the late-run race test (`race-test.yml`, called by
`release.yaml`); if it fails, `v1` does not move. It also runs on any PR that
touches `action.yml` or the test, and on demand:
`gh workflow run race-test.yml --repo dvystrcil/secret-scan-action`.

The test stages the race for real (`tests/race-test.sh`):

1. It opens a throwaway PR (`race-probe/*`) from the code under test.
   `race-probe.yml` passes on it in both arms.
2. It closes the PR, deletes the branch, and waits until `refs/pull/N/merge` is gone.
3. It re-runs the probe, so the run starts after its PR is gone.
4. The re-run must show:
   - **fixed** (this commit's action) passes, having scanned at least 1 commit.
   - **control** (the template before the fix) fails with `unknown revision`.
     This is the proof that the race really was staged.

It needs the CICD App token from the in-cluster Infisical, so it runs on
`secret-scan-action-runner` (argocd-projects `arc/arc-deploy-runners.yaml`,
arc-isolated tier). Fork PRs need approval for every external contributor and
get no secrets, so they skip it.

**Rollback:** `git tag -f v1 <previous sha> && git push --force origin refs/tags/v1`.

## Rollout

`homelab/bin/gitleaks-rollout.py` writes the caller above into repos that have no
secret scanning, and its daily sweep (`secret-scan-fleet-rollout.yaml`) works
through them a few at a time.
