#!/usr/bin/env bash
# Nightly report: open, update and close "Nightly: <check>" and "Nightly: <check>: <item>" issues.
# Env: GH_TOKEN, NR_RESULTS, NR_NEEDS, NR_ITEMS_FILE, NR_MAX_ISSUES, NR_LOGS_DIR, NR_LABELS,
#      NR_RUN_URL, NR_SHA, NR_REPO. Optional: GITHUB_OUTPUT.
# bash 3.2 safe. Never pipes into `grep -q`.
set -euo pipefail

if [ "${1:-}" = "--self-test" ]; then
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  t=$(mktemp -d)
  mkdir "$t/bin" "$t/logs"
  cat > "$t/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "gh $*" >> "$NR_CALLS"
prev=""
for a in "$@"; do [ "$prev" = "--body-file" ] && cat "$a" >> "$NR_CALLS"; prev="$a"; done
if [ "$1 $2" = "issue list" ]; then
  printf '7\tNightly: green-one\n9\tNightly: red-old\n11\tNightly: integration: s-fixed\n12\tNightly: integration: s-bad-old\n13\tNightly: integration: other failures\n'
fi
exit 0
FAKE
  chmod +x "$t/bin/gh"
  printf 'l1\nl2\nboom\n' > "$t/red.log"
  printf 'tail of build\n' > "$t/logs/build.log"
  export PATH="$t/bin:$PATH" NR_CALLS="$t/calls" GH_TOKEN=x NR_LABELS="bug" \
    NR_RUN_URL=http://run NR_SHA=abc123 NR_REPO=o/r GITHUB_OUTPUT="$t/out" NR_MAX_ISSUES=10
  fail() { echo "nightly-report self-test: $1"; echo "$calls"; exit 1; }
  has() { grep -F -q -- "$1" <<<"$calls"; }
  run() { : > "$t/calls"; : > "$t/out"; "$@" bash "$self"; calls=$(cat "$t/calls"); }

  # 1. Old interface: results only.
  NR_RESULTS="$(printf 'green-one|pass|\nred-new|fail|%s\nred-old|fail|%s\nclean|pass|' "$t/red.log" "$t/red.log")" \
    NR_NEEDS="" NR_ITEMS_FILE="" NR_LOGS_DIR="" run env
  has "issue close 7" || fail "green-one was not closed"
  has "issue create --title Nightly: red-new" || fail "red-new was not created"
  has "issue comment 9" || fail "red-old was not commented"
  has "issue close 9" && fail "red-old closed"
  has "issue create --title Nightly: clean" && fail "clean created"
  grep -q "red.log" "$t/out" || fail "logs output missing"

  # 2. needs-json: cancelled and failure fail, skipped is ignored, success passes.
  needs='{"build":{"result":"cancelled","outputs":{}},"unit":{"result":"failure"},"site":{"result":"skipped"},"green-one":{"result":"success"}}'
  NR_RESULTS="" NR_NEEDS="$needs" NR_ITEMS_FILE="" NR_LOGS_DIR="$t/logs" run env
  has "issue create --title Nightly: build" || fail "cancelled build was not filed"
  has "timed out or cancelled" || fail "cancel reason missing"
  has "issue create --title Nightly: unit" || fail "failed unit was not filed"
  has "Nightly: site" && fail "skipped job was reported"
  has "issue close 7" || fail "needs success did not close"
  grep -q "build.log" "$t/out" || fail "logs-dir log not picked up"
  NR_RESULTS="" NR_NEEDS="$needs" NR_NEEDS_IGNORE="build,unit" NR_ITEMS_FILE="" NR_LOGS_DIR="" run env
  has "Nightly: build" && fail "ignored job was reported"
  has "Nightly: unit" && fail "ignored job was reported"

  # 3. items: failing items filed up to the cap, rest in one summary, passing closes.
  { echo 'integration/s-fixed|pass|'
    echo 'integration/s-bad-old|fail|'
    echo 'integration/s-bad-1|fail|'"$t/red.log"
    echo 'integration/s-bad-2|fail|'
    echo 'integration/s-bad-3|fail|'
    echo 'integration/s-bad-4|fail|'; } > "$t/items"
  NR_RESULTS="integration|fail|" NR_NEEDS="" NR_ITEMS_FILE="$t/items" NR_MAX_ISSUES=3 NR_LOGS_DIR="" run env
  has "issue close 11" || fail "passing item did not close"
  has "issue comment 12" || fail "open item issue not commented"
  has "issue create --title Nightly: integration: s-bad-1" || fail "item issue not created"
  has "issue create --title Nightly: integration: other failures" && fail "summary created although open issue 13 exists"
  has "issue comment 13" || fail "summary not updated"
  has "issue create --title Nightly: integration:" || fail "no item created"
  has "issue create --title Nightly: integration " && fail "check-level issue filed beside item issues"
  n=$(grep -c "issue create" <<<"$calls" || true)
  [ "$n" -le 3 ] || fail "cap exceeded ($n creates)"

  # 4. items all passing closes the summary.
  printf 'integration/a|pass|\n' > "$t/items2"
  NR_RESULTS="" NR_NEEDS="" NR_ITEMS_FILE="$t/items2" NR_MAX_ISSUES=3 NR_LOGS_DIR="" run env
  has "issue close 13" || fail "summary not closed when nothing overflows"

  rm -rf "$t"
  echo "nightly-report self-test: ok"
  exit 0
fi

results="${NR_RESULTS:-}"
needs="${NR_NEEDS:-}"
items_file="${NR_ITEMS_FILE:-}"
max_issues="${NR_MAX_ISSUES:-10}"
logs_dir="${NR_LOGS_DIR:-}"
# No agent label: any agent can take a nightly issue. Default is bug (with nightly).
labels="${NR_LABELS:-}"
sha="${NR_SHA:-unknown}"
short=$(printf '%s' "$sha" | cut -c1-8)
work=$(mktemp -d)
rows="$work/rows"     # check|status|log|reason
irows="$work/irows"   # check|item|status|log
: > "$rows"; : > "$irows"

if [ -z "$results" ] && [ -z "$needs" ] && [ -z "$items_file" ]; then
  echo "nightly-report: give results, needs-json or items-file" >&2
  exit 1
fi

# results: lines check|status|log, or a JSON array.
if [ -n "$results" ]; then
  first=$(printf '%s' "$results" | tr -d ' \n\t' | cut -c1)
  if [ "$first" = "[" ]; then
    printf '%s' "$results" | jq -r '.[] | "\(.check)|\(.status)|\(.log // "")|"' >> "$rows"
  else
    printf '%s\n' "$results" | awk -F'|' 'NF{print $1 "|" $2 "|" $3 "|"}' >> "$rows"
  fi
fi

# needs-json: each needed job's result. cancelled -> fail, skipped ignored. results win on a clash.
if [ -n "$needs" ]; then
  printf '%s' "$needs" | jq -r 'to_entries[] | "\(.key)|\(.value.result)"' | while IFS='|' read -r job res; do
    [ -n "$job" ] || continue
    case ",${NR_NEEDS_IGNORE:-}," in *",$job,"*) continue ;; esac
    if awk -F'|' -v j="$job" '$1==j{f=1} END{exit !f}' "$rows"; then continue; fi
    log=""
    if [ -n "$logs_dir" ] && [ -f "$logs_dir/$job.log" ]; then log="$logs_dir/$job.log"; fi
    case "$res" in
      success) echo "$job|pass|$log|" ;;
      skipped) ;;
      cancelled) echo "$job|fail|$log|timed out or cancelled" ;;
      *) echo "$job|fail|$log|job $res" ;;
    esac
  done >> "$rows"
fi

# items-file: lines check/item|status|log
if [ -n "$items_file" ] && [ -f "$items_file" ]; then
  while IFS='|' read -r key status log; do
    case "$key" in ''|'#'*) continue ;; esac
    case "$key" in
      */*) check="${key%%/*}"; item="${key#*/}" ;;
      *) check="$key"; item="" ;;
    esac
    case "$status" in pass|success|ok) status=pass ;; *) status=fail ;; esac
    if [ -z "$item" ]; then echo "$check|$status|${log:-}|" >> "$rows"
    else echo "$check|$item|$status|${log:-}" >> "$irows"; fi
  done < "$items_file"
fi

label_args=(--label nightly)
oldifs=$IFS; IFS=,
for l in $labels; do [ -n "$l" ] && label_args+=(--label "$l"); done
IFS=$oldifs

# One list call: open nightly issues as number<TAB>title.
open_list="$work/open.tsv"
gh issue list --state open --label nightly --limit 500 --json number,title \
  --jq '.[] | "\(.number)\t\(.title)"' > "$open_list" 2>/dev/null || : > "$open_list"
open_issue() { # title -> number or empty
  awk -F'\t' -v t="$1" '$2==t{print $1; exit}' "$open_list"
}

logs=""
body="$work/body.md"

write_body() { # what, log, reason
  {
    echo "Nightly $1 failed on \`$short\`: $NR_RUN_URL"
    echo
    if [ -n "${3:-}" ]; then echo "Reason: $3"; echo; fi
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
      echo "Failing tail of \`$2\`:"
      echo
      echo '```'
      tail -n 40 "$2" | cut -c1-300 | tail -c 3500
      echo '```'
    else
      echo "No log file was saved."
    fi
  } > "$body"
}

file_issue() { # title, number-or-empty
  if [ -n "$2" ]; then gh issue comment "$2" --body-file "$body"
  else gh issue create --title "$1" --body-file "$body" "${label_args[@]}"; fi
}

close_green() { # number
  gh issue comment "$1" --body "Green on $sha: $NR_RUN_URL"
  gh issue close "$1" --reason completed
}

# Checks that have failing items: their items carry the report.
failing_checks=" "
while IFS='|' read -r check item status log; do
  [ "$status" = fail ] && failing_checks="$failing_checks$check "
done < "$irows"

# Check level.
while IFS='|' read -r check status log reason; do
  [ -n "$check" ] || continue
  case "$status" in pass|success|ok) status=pass ;; *) status=fail ;; esac
  if [ -n "${log:-}" ] && [ -f "$log" ]; then logs="$logs$log"$'\n'; fi
  title="Nightly: $check"
  n=$(open_issue "$title" || true)
  if [ "$status" = pass ]; then
    [ -n "$n" ] && close_green "$n"
    continue
  fi
  case "$failing_checks" in *" $check "*) continue ;; esac
  write_body "check \`$check\`" "${log:-}" "${reason:-}"
  file_issue "$title" "$n"
done < "$rows"

# Item level. Failing items file one issue each up to max-issues; the rest go in one summary per check.
filed=0
overflow="$work/overflow"
: > "$overflow"
while IFS='|' read -r check item status log; do
  [ -n "$check" ] || continue
  title="Nightly: $check: $item"
  n=$(open_issue "$title" || true)
  if [ "$status" = pass ]; then
    [ -n "$n" ] && close_green "$n"
    continue
  fi
  if [ -n "${log:-}" ] && [ -f "$log" ]; then logs="$logs$log"$'\n'; fi
  if [ -n "$n" ] || [ "$filed" -lt "$max_issues" ]; then
    # An item that already has an open issue is always updated; new ones count against the cap.
    [ -n "$n" ] || filed=$((filed + 1))
    write_body "item \`$check/$item\`" "${log:-}" ""
    file_issue "$title" "$n"
  else
    echo "$check|$item" >> "$overflow"
  fi
done < "$irows"

# Summary issue per check that has items.
for check in $(awk -F'|' '{print $1}' "$irows" | sort -u); do
  title="Nightly: $check: other failures"
  n=$(open_issue "$title" || true)
  list=$(awk -F'|' -v c="$check" '$1==c{print "- `" $1 "/" $2 "`"}' "$overflow")
  if [ -n "$list" ]; then
    {
      echo "More failing items of \`$check\` than the cap of $max_issues issues on \`$short\`: $NR_RUN_URL"
      echo
      echo "$list"
    } > "$body"
    file_issue "$title" "$n"
  elif [ -n "$n" ]; then
    close_green "$n"
  fi
done

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "logs<<NR_EOF"; printf '%s' "$logs"; echo "NR_EOF"; } >> "$GITHUB_OUTPUT"
fi
rm -rf "$work"
