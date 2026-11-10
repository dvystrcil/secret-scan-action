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

Consumers reference `@v1`, so **moving `v1` is the release** to every repo. Merging to
`main` releases nothing.

**Pinning ([homelab D-042](https://github.com/dvystrcil/homelab/blob/main/architecture/ways-of-working.md)):**
callers use this action by tag, never by SHA, so a fix ships by moving `v1`. Inside,
`actions/checkout` and `gitleaks-action` are pinned to commit SHAs, because their tags
are outside our control. Renovate bumps those SHAs here, and they reach callers on
the next release.

```bash
# first release only: v0.0.0 -> v1.0.0, creates v1
gh workflow run release.yaml --repo dvystrcil/secret-scan-action -f bump=major
# after that
gh workflow run release.yaml --repo dvystrcil/secret-scan-action -f bump=patch
```

If the checkout step changes, redo the late-run reproduction before releasing:
open a throwaway PR, let its scan pass, close it with `--delete-branch`, confirm
`git ls-remote origin 'refs/pull/<n>/*'` shows only `head`, then re-run the scan.
It must still check out the PR head and scan a non-zero number of commits.

**Rollback:** `git tag -f v1 <previous sha> && git push --force origin refs/tags/v1`.

## Rollout

`homelab/bin/gitleaks-rollout.py` writes the caller above into repos that have no
secret scanning, and its daily sweep (`secret-scan-fleet-rollout.yaml`) works
through them a few at a time.
