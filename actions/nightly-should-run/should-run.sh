#!/usr/bin/env bash
# Nightly should-run: skip a nightly when nothing that matters changed.
# Env: GH_TOKEN, NSR_PATHS, NSR_WORKFLOW, NSR_WORKFLOW_REF, NSR_EVENT, NSR_REPO.
# Optional: GITHUB_OUTPUT, GITHUB_STEP_SUMMARY. Run from the checkout. Fails open: any error gives run=true.
# bash 3.2 safe. Never pipes into `grep -q`.
set -euo pipefail

if [ "${1:-}" = "--self-test" ]; then
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  t=$(mktemp -d)
  mkdir "$t/bin" "$t/src"
  # The fake gh prints the SHAs in $NSR_FAKE_RUNS, one per line (the real one applies --jq).
  cat > "$t/bin/gh" <<'FAKE'
#!/usr/bin/env bash
[ "${NSR_FAKE_FAIL:-}" = 1 ] && exit 1
printf '%s' "${NSR_FAKE_RUNS:-}"
exit 0
FAKE
  chmod +x "$t/bin/gh"
  g() { git -C "$t/src" -c user.email=t@t -c user.name=t "$@"; }
  git init -q "$t/src"
  echo 1 > "$t/src/code.txt"; g add .; g commit -qm code1; A=$(g rev-parse HEAD)
  echo doc > "$t/src/README.md"; g add .; g commit -qm docs
  echo 2 > "$t/src/code.txt"; g commit -qam code2; C=$(g rev-parse HEAD)
  echo more >> "$t/src/README.md"; g commit -qam docs2; D=$(g rev-parse HEAD)
  git clone -q --depth=1 "file://$t/src" "$t/work"
  paths_default="$(printf '.\n:(exclude)*.md\n:(exclude).claude/')"
  export PATH="$t/bin:$PATH" GH_TOKEN=x NSR_REPO=o/r NSR_WORKFLOW_REF=o/r/.github/workflows/nightly.yml@refs/heads/main \
    NSR_PATHS="$paths_default" GITHUB_OUTPUT="$t/out" GITHUB_STEP_SUMMARY="$t/sum"
  fail() { echo "nightly-should-run self-test: $1"; cat "$t/out"; exit 1; }
  check() { # name expected event runs
    : > "$t/out"; : > "$t/sum"
    (cd "$t/work" && NSR_EVENT="$3" NSR_FAKE_RUNS="$4" bash "$self") > "$t/log" 2>&1 || { cat "$t/log"; fail "$1: script failed"; }
    grep -q "^run=$2\$" "$t/out" || { cat "$t/log"; fail "$1: expected run=$2"; }
    grep -q "^reason=." "$t/out" || fail "$1: no reason"
    [ -s "$t/sum" ] || fail "$1: no summary line"
  }
  check dispatch true workflow_dispatch "$D"
  check no-previous-run true schedule ""
  check same-sha false schedule "$D"
  check docs-only false schedule "$C"
  check code-changed true schedule "$A"
  check unknown-sha true schedule "0000000000000000000000000000000000000001"
  : > "$t/out"; : > "$t/sum"
  (cd "$t/work" && NSR_EVENT=schedule NSR_FAKE_FAIL=1 bash "$self") > "$t/log" 2>&1 || fail "api error: script failed"
  grep -q "^run=true\$" "$t/out" || fail "api error: expected run=true"
  rm -rf "$t"
  echo "nightly-should-run self-test: ok"
  exit 0
fi

out="${GITHUB_OUTPUT:-/dev/null}"
sum="${GITHUB_STEP_SUMMARY:-/dev/null}"

finish() { # run reason
  printf 'run=%s\nreason=%s\n' "$1" "$2" >> "$out"
  printf 'Nightly should run: %s (%s)\n' "$1" "$2" >> "$sum"
  echo "run=$1: $2"
  exit 0
}

[ "${NSR_EVENT:-}" = "workflow_dispatch" ] && finish true "manual run (workflow_dispatch)"

wf="${NSR_WORKFLOW:-}"
if [ -z "$wf" ]; then # owner/repo/.github/workflows/file.yml@ref
  wf="${NSR_WORKFLOW_REF:-}"; wf="${wf%%@*}"; wf="${wf##*/}"
fi
[ -n "$wf" ] || finish true "workflow file unknown, running"

# Last completed run that tested something: success or failure. Cancelled and skipped runs are passed over.
runs=$(gh api "repos/${NSR_REPO}/actions/workflows/${wf}/runs?branch=main&status=completed&per_page=10" \
  --jq '.workflow_runs[] | select(.conclusion == "success" or .conclusion == "failure") | .head_sha') \
  || finish true "could not read earlier runs, running"
last="${runs%%$'\n'*}"
[ -n "$last" ] || finish true "no earlier completed run, running"

head=$(git rev-parse HEAD) || finish true "git rev-parse failed, running"
short=$(printf '%s' "$last" | cut -c1-8)
[ "$last" = "$head" ] && finish false "main is unchanged since the last completed run ($short)"

git fetch -q --depth=1 origin "$last" || finish true "could not fetch $short, running"

set -f
# shellcheck disable=SC2206
paths=(${NSR_PATHS:-.})
set +f
[ "${#paths[@]}" -gt 0 ] || paths=(.)

rc=0
git diff --quiet "$last" HEAD -- "${paths[@]}" || rc=$?
case $rc in
  0) finish false "nothing that matters changed since the last completed run ($short)" ;;
  1) finish true "files changed since the last completed run ($short)" ;;
  *) finish true "git diff failed, running" ;;
esac
