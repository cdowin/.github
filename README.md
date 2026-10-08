# cdowin/.github

Default issue forms and the pull request template for every repo owned by `cdowin`. A repo that has its own `.github/ISSUE_TEMPLATE/` or PR template uses its own files instead.

The process lives in `cdowin/signalandecho` (README and skill `work-intake`). This repo is public: never put private text here.

`actions/` holds shared composite actions that public repos can call (a public repo cannot use an action from a private one): `cdowin/.github/actions/nightly-should-run@main` and `cdowin/.github/actions/nightly-report@main`.

`nightly-report` inputs: `results` (`check|status|log` lines or JSON), `needs-json` (`${{ toJSON(needs) }}` from a separate report job; a cancelled or timed-out job becomes a failure), `needs-ignore`, `logs-dir`, `items-file` (`check/item|status|log` lines; one issue per failing item), `max-issues` (default 10), `labels` (default `bug`; `nightly` is always added; no agent label), `artifact-name`, `token`.
