# cdowin/.github

Default issue forms and the pull request template for every repo owned by `cdowin`. A repo that has its own `.github/ISSUE_TEMPLATE/` or PR template uses its own files instead.

The process lives in `cdowin/signalandecho` (README and skill `work-intake`). This repo is public: never put private text here.

`actions/` holds shared composite actions that public repos can call (a public repo cannot use an action from a private one): `cdowin/.github/actions/nightly-should-run@main` and `cdowin/.github/actions/nightly-report@main`.

`nightly-report` inputs: `results` (`check|status|log` lines or JSON), `needs-json` (`${{ toJSON(needs) }}` from a separate report job; a cancelled or timed-out job becomes a failure), `needs-ignore`, `logs-dir`, `items-file` (`check/item|status|log` lines; one issue per failing item), `max-issues` (default 10), `labels` (default `bug`; `nightly` is always added, and `status:ready` when the repo has it; no agent label), `artifact-name`, `token`.

## studio-ci: one CI shape for every studio repo

`.github/workflows/studio-ci.yml` is a reusable workflow with 3 jobs: `fast` (every PR, draft or ready, and push), `heavy` (skipped with no `heavy` command and on a draft PR) and `gate` (needs both; a skipped lane passes, a failed or cancelled one fails it, with 1 exception: on a draft PR with a `heavy` command the gate fails with "draft: heavy lane not run; mark the PR ready to run it", so auto-merge cannot land on the draft run; with no `heavy` command a draft's gate passes on fast alone). Branch protection requires the gate only. The caller owns triggers and concurrency. A repo's `ci.yml`:

```yaml
name: ci
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  push:
    branches: [main]
  workflow_dispatch:
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
jobs:
  ci:
    uses: cdowin/.github/.github/workflows/studio-ci.yml@studio-ci-v2
    with:
      fast: ./bin/check
      # heavy: ./bin/e2e   # why it cannot be fast
```

Inputs: `fast` (command, required), `heavy` (command, default empty), `fast-runs-on` and `heavy-runs-on` (JSON label arrays as strings, default `'["ubuntu-latest"]'`), `setup` (command run before each lane), `timeout-fast` (10), `timeout-heavy` (60), `checkout-fetch-depth` (1).

Lane rule: every check goes in `fast` by default. A check goes in `heavy` only with a 1-line comment in the caller saying why it cannot be fast. A repo with a `heavy` lane sees a red gate on every draft PR by design; it goes green when the PR is marked ready. The nightly stays as it is, with `nightly-should-run` and `nightly-report`.

What it is and why, for people: [wiki](https://github.com/cdowin/.github/wiki).
