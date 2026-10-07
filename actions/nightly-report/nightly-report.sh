#!/usr/bin/env bash
# Nightly report: open, update and close "Nightly: <check>" issues.
# Env: GH_TOKEN, NR_RESULTS, NR_LABELS, NR_RUN_URL, NR_SHA, NR_REPO. Optional: GITHUB_OUTPUT.
# bash 3.2 safe. Never pipes into `grep -q`.
set -euo pipefail

if [ "${1:-}" = "--self-test" ]; then
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  t=$(mktemp -d)
  mkdir "$t/bin"
  cat > "$t/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "gh $*" >> "$NR_CALLS"
if [ "$1 $2" = "issue list" ]; then
  case "$*" in *'Nightly: green-one'*) echo 7 ;; *'Nightly: red-old'*) echo 9 ;; esac
fi
exit 0
FAKE
  chmod +x "$t/bin/gh"
  printf 'l1\nl2\nboom\n' > "$t/red.log"
  export PATH="$t/bin:$PATH" NR_CALLS="$t/calls" GH_TOKEN=x NR_LABELS="bug,agent:claude" \
    NR_RUN_URL=http://run NR_SHA=abc123 NR_REPO=o/r GITHUB_OUTPUT="$t/out"
  : > "$t/calls"; : > "$t/out"
  NR_RESULTS="$(printf 'green-one|pass|\nred-new|fail|%s\nred-old|fail|%s\nclean|pass|' "$t/red.log" "$t/red.log")" bash "$self"
  calls=$(cat "$t/calls")
  fail() { echo "nightly-report self-test: $1"; echo "$calls"; exit 1; }
  grep -q "issue close 7" <<<"$calls" || fail "green-one was not closed"
  grep -q "issue create --title Nightly: red-new" <<<"$calls" || fail "red-new was not created"
  grep -q "issue comment 9" <<<"$calls" || fail "red-old was not commented"
  if grep -q "issue close 9" <<<"$calls"; then fail "red-old closed"; fi
  if grep -q "Nightly: clean" <<<"$calls" && grep -q "issue create --title Nightly: clean" <<<"$calls"; then fail "clean created"; fi
  grep -q "red.log" "$t/out" || fail "logs output missing"
  rm -rf "$t"
  echo "nightly-report self-test: ok"
  exit 0
fi

: "${NR_RESULTS:?results is empty}"
labels="${NR_LABELS:-}"
sha="${NR_SHA:-unknown}"
short=$(printf '%s' "$sha" | cut -c1-8)
work=$(mktemp -d)
rows="$work/rows"

# Normalize to lines: check|status|log
first=$(printf '%s' "$NR_RESULTS" | tr -d ' \n\t' | cut -c1)
if [ "$first" = "[" ]; then
  printf '%s' "$NR_RESULTS" | jq -r '.[] | "\(.check)|\(.status)|\(.log // "")"' > "$rows"
else
  printf '%s\n' "$NR_RESULTS" > "$rows"
fi

label_args=(--label nightly)
oldifs=$IFS; IFS=,
for l in $labels; do [ -n "$l" ] && label_args+=(--label "$l"); done
IFS=$oldifs

open_issue() { # title -> number or empty
  gh issue list --state open --label nightly --search "\"$1\" in:title" \
    --json number,title --jq ".[] | select(.title == \"$1\") | .number" | head -1
}

logs=""
while IFS='|' read -r check status log; do
  [ -n "$check" ] || continue
  title="Nightly: $check"
  case "$status" in pass|success|ok) status=pass ;; *) status=fail ;; esac
  if [ -n "${log:-}" ] && [ -f "$log" ]; then logs="$logs$log"$'\n'; fi
  n=$(open_issue "$title" || true)
  if [ "$status" = pass ]; then
    if [ -n "$n" ]; then
      gh issue comment "$n" --body "Green on $sha: $NR_RUN_URL"
      gh issue close "$n" --reason completed
    fi
    continue
  fi
  body="$work/body.md"
  {
    echo "Nightly check \`$check\` failed on \`$short\`: $NR_RUN_URL"
    echo
    if [ -n "${log:-}" ] && [ -f "$log" ]; then
      echo "Failing tail of \`$log\`:"
      echo
      echo '```'
      tail -n 40 "$log" | cut -c1-300 | tail -c 3500
      echo '```'
    else
      echo "No log file was saved for this check."
    fi
  } > "$body"
  if [ -n "$n" ]; then
    gh issue comment "$n" --body-file "$body"
  else
    gh issue create --title "$title" --body-file "$body" "${label_args[@]}"
  fi
done < "$rows"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "logs<<NR_EOF"; printf '%s' "$logs"; echo "NR_EOF"; } >> "$GITHUB_OUTPUT"
fi
rm -rf "$work"
