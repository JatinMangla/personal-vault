#!/usr/bin/env bash
# Fixtures for restore.sh, against a fake channel.
#
# WHY. restore.sh is the only thing that reads the archive back, and it is run
# when everything else is gone. The properties pinned here are the ones a
# restore is judged on:
#   - with a ledger it fetches BY ID, never the whole channel, and verifies
#     every file against the card hash in the ledger - PASS needs no manifest
#   - split files rejoin in order; a ledger row without ids is found by name
#   - a corrupt or unfetchable file is FAIL, never a quiet pass
#   - groups bound scratch space and still restore everything
#   - --list works offline from the ledger
#   - re-running into a full directory is NOTHING DONE, not PASS
#   - without a ledger, the whole-channel path still works as before
#
# telegram-download, tg-fetch-par.py and tg-resolve-ids.py are stubs over a
# directory standing in for the channel: message <id> is channel/<id>__<name>.
# The script under test is the SHIPPED restore.sh, run as a subprocess.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TOOL="$HERE/restore.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/channel"
: > "$T/calls"

cat > "$T/bin/telegram-download" <<EOF
#!/usr/bin/env bash
echo "telegram-download" >> "$T/calls"
for f in "$T/channel"/*; do cp "\$f" "./\${f##*__}"; done
EOF

cat > "$T/bin/py" <<EOF
#!/usr/bin/env bash
mode="\$(basename "\$1")"; shift
echo "\$mode" >> "$T/calls"
while [[ "\$1" == --* ]]; do
  if [[ "\$1" == --into ]]; then into="\$2"; fi
  shift 2
done
case "\$mode" in
  resolve)
    for n in "\$@"; do
      ids=\$(ls "$T/channel" | awk -F'__' -v n="\$n" '\$2 == n || index(\$2, n ".") == 1 { print \$1 }' | sort -n | tr '\n' ' ')
      if [[ -n "\$ids" ]]; then printf '%s\t%s\n' "\$n" "\${ids% }"; fi
    done ;;
  fetchpar)
    rc=0
    for id in "\$@"; do
      src=\$(ls "$T/channel"/"\$id"__* 2>/dev/null | head -1)
      if [[ -z "\$src" ]]; then rc=1; continue; fi
      cp "\$src" "\$into/\${src##*__}"
    done
    exit \$rc ;;
esac
EOF
chmod +x "$T/bin/telegram-download" "$T/bin/py"

# --- an archive: one whole file, one split into 3, one legacy row -------------

mk() { head -c "$2" /dev/urandom > "$T/$1"; }
mk A.insv 5000
mk B.insv 9000
mk C.insv 3000
split -b 3000 -d -a 2 "$T/B.insv" "$T/B.insv."        # B.insv.00 .01 .02
cp "$T/A.insv" "$T/channel/10__A.insv"
cp "$T/B.insv.00" "$T/channel/11__B.insv.00"
cp "$T/B.insv.01" "$T/channel/12__B.insv.01"
cp "$T/B.insv.02" "$T/channel/13__B.insv.02"
cp "$T/C.insv" "$T/channel/14__C.insv"
cp "$T/A.insv" "$T/channel/15__manifest-20260925.sha256"   # a manifest copy

h() { sha256sum "$T/$1" | cut -d' ' -f1; }
cat > "$T/ledger" <<EOF
$(h A.insv) A.insv 5000 10
$(h B.insv) B.insv 9000 11 12 13
$(h C.insv) C.insv 3000
EOF

run() {  # run <dest> [args...]
  local dest="$1"; shift
  : > "$T/calls"
  PATH="$T/bin:$PATH" TG_ENV_FILE=/nonexistent PIPX_PY="$T/bin/py" \
    TG_PAR_FETCHER="$T/fetchpar" TG_RESOLVER="$T/resolve" \
    TG_CHANNEL=-100123 TG_CONFIG="$T/ledger" \
    bash "$TOOL" --into "$dest" "$@" > "$T/out" 2>&1
}

pass=0; fail=0
ck() {
  if [[ "$2" == "$3" ]]; then
    echo "  PASS  $1"; pass=$((pass + 1))
  else
    echo "  FAIL  $1"; echo "        want: $3"; echo "        got:  $2"; fail=$((fail + 1))
    sed 's/^/        | /' "$T/out"
  fi
}
result() { grep -o 'RESULT: [A-Z ()]*' "$T/out" | head -1 | sed 's/ *$//'; }

echo "ledger mode: fetch by id, verify against the ledger"
rc=0; run "$T/d1" --ledger "$T/ledger" || rc=$?
ck "exits 0" "$rc" "0"
ck "PASS without any manifest" "$(result)" "RESULT: PASS"
ck "3 files verified" "$(grep -c 'verified: ' "$T/out")" "3"
ck "split file rejoined byte-identical" "$(sha256sum < "$T/d1/B.insv" | cut -d' ' -f1)" "$(h B.insv)"
ck "legacy row found by name" "$(grep -c resolve "$T/calls")" "1"
ck "never downloads the whole channel" "$(grep -c telegram-download "$T/calls")" "0"
ck "manifest copy is not restored" "$({ compgen -G "$T/d1/manifest*" || true; } | wc -l)" "0"

echo "re-run into the same directory"
rc=0; run "$T/d1" --ledger "$T/ledger" || rc=$?
ck "NOTHING DONE, not PASS" "$(result)" "RESULT: NOTHING DONE"

echo "groups keep scratch bounded and still restore everything"
rc=0; RESTORE_GROUP_BYTES=6000 run "$T/d2" --ledger "$T/ledger" || rc=$?
ck "PASS" "$(result)" "RESULT: PASS"
ck "three separate fetches" "$(grep -c fetchpar "$T/calls")" "3"

echo "one file named"
rc=0; run "$T/d3" --ledger "$T/ledger" B.insv || rc=$?
ck "PASS" "$(result)" "RESULT: PASS"
ck "only that file written" "$(ls "$T/d3")" "B.insv"

echo "a corrupted part"
printf 'X' >> "$T/channel/12__B.insv.01"
rc=0; run "$T/d4" --ledger "$T/ledger" || rc=$?
ck "exits non-zero" "$(( rc != 0 ))" "1"
ck "FAIL" "$(result)" "RESULT: FAIL"
ck "names the file" "$(grep -c 'HASH MISMATCH: B.insv' "$T/out")" "1"
cp "$T/B.insv.01" "$T/channel/12__B.insv.01"

echo "a message Telegram will not serve"
mv "$T/channel/10__A.insv" "$T/gone"
rc=0; run "$T/d5" --ledger "$T/ledger" || rc=$?
ck "FAIL" "$(result)" "RESULT: FAIL"
ck "the other files still verify" "$(grep -c 'verified: ' "$T/out")" "2"
mv "$T/gone" "$T/channel/10__A.insv"

echo "--list is offline"
: > "$T/calls"
PATH="$T/bin:$PATH" TG_ENV_FILE=/nonexistent PIPX_PY="$T/bin/py" \
  bash "$TOOL" --list --ledger "$T/ledger" > "$T/out" 2>&1
ck "lists the ledger" "$(grep -cE '^  [ABC]\.insv$' "$T/out")" "3"
ck "touches no network" "$(wc -l < "$T/calls")" "0"

echo "no ledger: the whole-channel path still works"
printf '%s  %s\n' "$(h A.insv)" A.insv "$(h B.insv)" B.insv "$(h C.insv)" C.insv > "$T/manifest"
rc=0; run "$T/d6" --whole-channel --manifest "$T/manifest" || rc=$?
ck "PASS" "$(result)" "RESULT: PASS"
ck "used telegram-download" "$(grep -c telegram-download "$T/calls")" "1"

echo
echo "passed=$pass failed=$fail"
(( fail == 0 ))
