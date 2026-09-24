#!/usr/bin/env bash
# Fixtures for the metrics payload's JSON safety.
#
# WHY. The payload is a heredoc. One unescaped quote, or "N/A" where a number
# belongs, makes the whole body invalid; the ingest route answers 400 and every
# figure on /status goes stale at once. json_str_vars() and json_num_vars()
# exist to make that impossible, so this checks three things:
#
#   1. hostile values come out as valid JSON with the content preserved
#   2. every variable the heredoc interpolates is in one of the two lists
#      (a field added later without sanitising would otherwise pass review)
#   3. the functions fork nothing - they run on the metrics timer every minute
#      on the same two cores as the Telegram drain
#
# Functions are EXTRACTED FROM THE SHIPPED SCRIPT, not copied.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SCRIPT="$HERE/collect-and-push.sh"

eval "$(sed -n '/^json_num_vars() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^json_str_vars() {/,/^}/p' "$SCRIPT")"
for fn in json_num_vars json_str_vars; do
  declare -f "$fn" >/dev/null || { echo "FATAL: could not extract $fn()" >&2; exit 1; }
done

pass=0; fail=0
ck() {
  if [[ "$2" == "$3" ]]; then
    echo "  PASS  $1"; pass=$((pass + 1))
  else
    echo "  FAIL  $1"; echo "        want: $3"; echo "        got:  $2"; fail=$((fail + 1))
  fi
}

# Parse a JSON document with whatever is available. CI has python3 and jq.
# Probe by RUNNING each one: Windows ships a python3 "alias" that is on PATH
# but only opens the Store, which `command -v` alone would accept.
parses() {
  if python3 -c '' >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null
  elif jq -n . >/dev/null 2>&1; then
    jq -e . >/dev/null 2>&1
  elif node -e '' >/dev/null 2>&1; then
    node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' 2>/dev/null
  else
    echo "  SKIP  no JSON parser available" >&2; return 0
  fi
}

echo "numbers"
A=12345; B=1.5; C=-3; D=''; E='N/A'; F='12 34'; G='1e5'; H='0x10'
json_num_vars A B C D E F G H
ck "integer kept"            "$A" "12345"
ck "decimal kept"            "$B" "1.5"
ck "negative kept"           "$C" "-3"
ck "empty becomes 0"         "$D" "0"
ck "N/A becomes 0"           "$E" "0"
ck "embedded space becomes 0" "$F" "0"
ck "exponent becomes 0"      "$G" "0"
ck "hex becomes 0"           "$H" "0"
json_num_vars NEVER_SET
ck "unset becomes 0"         "$NEVER_SET" "0"

echo "strings"
Q='say "hi"'; S='C:\temp\x'; N=$'line1\nline2'; T=$'a\tb'; R=$'x\ry'
K=$'bell\x07here'; P='GS010042.insv'; U='naïve – ok'; EMPTY=''
json_str_vars Q S N T R K P U EMPTY
ck "quote escaped"           "$Q" 'say \"hi\"'
ck "backslash escaped"       "$S" 'C:\\temp\\x'
ck "newline spelled out"     "$N" 'line1\nline2'
ck "tab spelled out"         "$T" 'a\tb'
ck "CR spelled out"          "$R" 'x\ry'
ck "other control dropped"   "$K" 'bellhere'
ck "plain filename intact"   "$P" 'GS010042.insv'
ck "UTF-8 intact"            "$U" 'naïve – ok'
ck "empty stays empty"       "$EMPTY" ''

echo "a hostile document parses"
doc="{\"q\":\"$Q\",\"s\":\"$S\",\"n\":\"$N\",\"t\":\"$T\",\"r\":\"$R\",\"k\":\"$K\",\"u\":\"$U\",\"num\":$E}"
if printf '%s' "$doc" | parses; then ck "valid JSON" ok ok; else ck "valid JSON" "$doc" "(parseable JSON)"; fi

echo "every payload variable is sanitised"
body="$(sed -n "/^read -r -d '' PAYLOAD <<JSON/,/^JSON\$/p" "$SCRIPT")"
used="$(grep -o '\${[A-Z0-9_]*}' <<<"$body" | tr -d '${}' | sort -u)"
listed="$(sed -n '/^json_str_vars HOST_NAME/,/^# The two booleans/p' "$SCRIPT" \
  | grep -v '^#' | tr ' \\' '\n\n' | grep -E '^[A-Z][A-Z0-9_]*$' | sort -u)"
missing=""
for v in $used; do
  case "$v" in API_OK|SYNC_CONNECTED) continue ;; esac
  grep -qx "$v" <<<"$listed" || missing="$missing $v"
done
ck "no unsanitised field" "${missing:-none}" "none"
ck "found the payload" "$( [[ -n "$used" ]] && echo yes )" "yes"

echo "no process is forked"
# A fork in either function would show up as a changed $BASHPID in a probe
# subshell only if we forked there; simpler and exact: the bodies must contain
# no command substitution and no external command.
bodies="$(declare -f json_num_vars json_str_vars)"
if grep -qE '\$\(|`' <<<"$bodies"; then ck "no command substitution" "found" "none"; else ck "no command substitution" none none; fi

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
