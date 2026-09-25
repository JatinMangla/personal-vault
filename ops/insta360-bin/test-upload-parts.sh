#!/usr/bin/env bash
# Fixtures for tg-upload-parts.sh, against a fake channel.
#
# WHY. tg-upload-parts.sh writes a ledger row, and the ledger is what lets
# tg-prune delete the original from the camera card. A row for a file that is
# not fully retrievable would let the only copy be deleted. So the properties
# under test are the ones that guard that:
#   - a clean run records exactly one row: card hash, name, size, part ids in order
#   - a part that fails its round trip is re-uploaded ALONE, and the row uses the
#     good copy's id, while the failed id is reported for deletion
#   - a part that never verifies records NOTHING
#   - a file not matching its card fingerprint uploads nothing
#   - a file already in the ledger uploads nothing
#
# telegram-upload, the id resolver and the fetcher are stubs over a directory
# standing in for the channel: message <id> is the file channel/<id>__<name>.
# The script under test is the SHIPPED one, run as a subprocess.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TOOL="$HERE/tg-upload-parts.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/channel" "$T/work" "$T/media"
echo 100 > "$T/next_id"
: > "$T/fail_ids"          # message ids whose fetch fails (a transient failure)
: > "$T/corrupt_names"     # part names that always come back altered
: > "$T/bad_hashes"        # CONTENT that is never served back, whatever the id -
                           # what Telegram actually did on 2026-09-25

# --- stubs ---------------------------------------------------------------------

cat > "$T/bin/telegram-upload" <<EOF
#!/usr/bin/env bash
f="\${@: -1}"; id=\$(cat "$T/next_id"); echo \$(( id + 1 )) > "$T/next_id"
cp "\$f" "$T/channel/\${id}__\$(basename "\$f")"
echo "\$(basename "\$f")" >> "$T/uploads"
EOF

cat > "$T/bin/py" <<EOF
#!/usr/bin/env bash
mode="\$(basename "\$1")"; shift
while [[ "\$1" == --* ]]; do
  if [[ "\$1" == --into ]]; then into="\$2"; fi
  shift 2
done
case "\$mode" in
  resolve)
    for n in "\$@"; do
      id=\$(ls "$T/channel" | awk -F'__' -v n="\$n" '\$2 == n { print \$1 }' | sort -n | tail -1)
      if [[ -n "\$id" ]]; then printf '%s\t%s\n' "\$n" "\$id"; fi
    done ;;
  fetchpar)
    # Like tg-fetch-par.py: fetch every id, skip the ones that fail, and exit
    # non-zero at the end if any did. A failed file is simply absent.
    rc=0
    for id in "\$@"; do
      src=\$(ls "$T/channel"/"\$id"__* 2>/dev/null | head -1)
      if [[ -z "\$src" ]] || grep -qx "\$id" "$T/fail_ids" \
         || grep -qx "\$(sha256sum "\$src" | cut -d' ' -f1)" "$T/bad_hashes"; then
        rc=1; continue
      fi
      name=\${src##*__}
      cp "\$src" "\$into/\$name"
      if grep -qx "\$name" "$T/corrupt_names"; then printf 'X' >> "\$into/\$name"; fi
    done
    exit \$rc ;;
esac
EOF
chmod +x "$T/bin/telegram-upload" "$T/bin/py"

FILE="$T/media/VID_test.insv"
head -c 3670016 /dev/urandom > "$FILE"          # 3.5 MiB -> 4 parts at 1 MiB
HASH="$(sha256sum "$FILE" | cut -d' ' -f1)"
SIZE="$(stat -c %s "$FILE")"
printf '%s  %s\n' "$HASH" "VID_test.insv" > "$T/manifest.sha256"

cat > "$T/env" <<EOF
TG_CHANNEL=-100123
MANIFEST=$T/manifest.sha256
WORK_DIR=$T/work
TG_CONFIG=$T/cfg.json
EOF

run() {
  : > "$T/uploads"
  TG_ENV_FILE="$T/env" PIPX_PY="$T/bin/py" TG_RESOLVER="$T/resolve" \
    TG_PAR_FETCHER="$T/fetchpar" TG_UPLOAD_CMD="$T/bin/telegram-upload" \
    PART_MIB=1 MAX_ROUNDS="${ROUNDS:-4}" bash "$TOOL" "$FILE" > "$T/out" 2>&1
}

reset() {
  rm -f "$T/channel"/* "$T/work/uploaded.sha256"
  echo 100 > "$T/next_id"; : > "$T/fail_ids"; : > "$T/corrupt_names"; : > "$T/bad_hashes"
}

# Rejoin the channel messages the ledger row points at, in order, and hash
# them: the end-to-end proof that the row describes a restorable file.
rejoin_from_ledger() {
  local id
  for id in $(awk '{ for (i = 4; i <= NF; i++) print $i }' "$T/work/uploaded.sha256"); do
    cat "$T/channel/${id}__"*
  done | sha256sum | cut -d' ' -f1
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

echo "clean run"
reset; rc=0; run || rc=$?
ck "exits 0" "$rc" "0"
ck "one ledger row, ids in part order" "$(cat "$T/work/uploaded.sha256")" "$HASH VID_test.insv $SIZE 100 101 102 103"
ck "four uploads, one per part" "$(wc -l < "$T/uploads")" "4"
ck "original untouched" "$(sha256sum "$FILE" | cut -d' ' -f1)" "$HASH"
ck "part scratch removed" "$(ls -A "$T/media")" "VID_test.insv"
ck "ledger ids rejoin to the original" "$(rejoin_from_ledger)" "$HASH"

echo "a part whose CONTENT is never served (2026-09-25's failure)"
reset
# The bytes of aligned part .02 (2 MiB..3 MiB) fail whatever message holds them.
dd if="$FILE" bs=1M skip=2 count=1 status=none | sha256sum | cut -d' ' -f1 > "$T/bad_hashes"
rc=0; ROUNDS=5 run || rc=$?
ck "exits 0" "$rc" "0"
ck "part .02 was reshaped" "$(grep -c 'reshaped VID_test.insv.02' "$T/out")" "1"
ck "reshaped part now starts 4 KiB later" "$(grep -c 'now starts at byte 2101248' "$T/out")" "1"
ck "row: .00 and .03 kept, .01 and .02 redone" \
   "$(cut -d' ' -f4- "$T/work/uploaded.sha256")" "100 105 106 103"
ck "ledger ids rejoin to the original" "$(rejoin_from_ledger)" "$HASH"
ck "both failed copies listed for deletion" "$(grep -c 'channel): 102 104$' "$T/out")" "1"

echo "one part fails its round trip once"
reset; echo 102 > "$T/fail_ids"; rc=0; run || rc=$?
ck "exits 0" "$rc" "0"
ck "row uses the re-upload's id" "$(cat "$T/work/uploaded.sha256")" "$HASH VID_test.insv $SIZE 100 101 104 103"
ck "only the failed part re-uploaded" "$(tail -1 "$T/uploads")" "VID_test.insv.02"
ck "five uploads in total" "$(wc -l < "$T/uploads")" "5"
ck "failed id listed for deletion" "$(grep -c 'safe to delete from the channel): 102' "$T/out")" "1"

echo "a part that never comes back intact"
reset; echo "VID_test.insv.01" > "$T/corrupt_names"; rc=0; ROUNDS=3 run || rc=$?
ck "exits non-zero" "$(( rc != 0 ))" "1"
ck "NOTHING recorded" "$(cat "$T/work/uploaded.sha256" 2>/dev/null || echo none)" "none"
ck "says the file stays unarchived" "$(grep -c 'NOTHING recorded' "$T/out")" "1"

echo "file does not match its card fingerprint"
reset; printf '%s  %s\n' "$(printf '0%.0s' {1..64})" "VID_test.insv" > "$T/manifest.sha256"
rc=0; run || rc=$?
ck "refuses" "$(( rc != 0 ))" "1"
ck "uploads nothing" "$(wc -l < "$T/uploads")" "0"
printf '%s  %s\n' "$HASH" "VID_test.insv" > "$T/manifest.sha256"

echo "file already in the ledger"
reset; echo "$HASH VID_test.insv $SIZE 7" > "$T/work/uploaded.sha256"
rc=0; run || rc=$?
ck "refuses" "$(( rc != 0 ))" "1"
ck "uploads nothing" "$(wc -l < "$T/uploads")" "0"
ck "ledger unchanged" "$(wc -l < "$T/work/uploaded.sha256")" "1"

echo
echo "passed=$pass failed=$fail"
(( fail == 0 ))
