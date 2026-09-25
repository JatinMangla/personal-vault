#!/usr/bin/env bash
# Fixtures for parts_fallback() and ensure_stignore() in tg-archive.sh.
#
# WHY. parts_fallback() decides when the drain stops re-uploading a file whole
# and archives it as verified parts instead, and what happens if even that
# fails. Getting the threshold wrong either wastes hours re-uploading into the
# same unservable blocks, or sends healthy files down the slow path. Getting
# the failure branch wrong could stall the whole drain on one file. So:
#   - below PARTS_AFTER failures nothing happens
#   - at PARTS_AFTER the parts uploader runs; on success the file STAYS staged
#     (tg-upload.sh clears it by hash next pass) and its count is reset
#   - if parts fail too, the file moves to .hold and its count is reset
#   - counts are per exact filename, not a pattern
#   - ensure_stignore adds the three scratch patterns once, never twice
#
# Functions are EXTRACTED FROM THE SHIPPED SCRIPT, not copied.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
eval "$(sed -n '/^parts_fallback() {/,/^}/p; /^ensure_stignore() {/,/^}/p' "$HERE/tg-archive.sh")"
for fn in parts_fallback ensure_stignore; do
  declare -f "$fn" >/dev/null || { echo "FATAL: could not extract $fn()" >&2; exit 1; }
done

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
log() { :; }
err() { :; }

# Globals the extracted functions read. The linter cannot see that use.
# shellcheck disable=SC2034
{
  STAGING_DIR="$T/staging"
  HOLD_DIR="$STAGING_DIR/.hold"
  CHECK2_FAILS="$T/check2-failures"
  PARTS_AFTER=2
  PARTS_UPLOADER="$T/parts"
}
mkdir -p "$STAGING_DIR"

# Stub: records each call; succeeds unless the file name is listed in $T/deny.
cat > "$T/parts" <<EOF
#!/usr/bin/env bash
echo "\$(basename "\$1")" >> "$T/parts-calls"
! grep -qxF "\$(basename "\$1")" "$T/deny" 2>/dev/null
EOF
chmod +x "$T/parts"

pass=0; fail=0
ck() {
  if [[ "$2" == "$3" ]]; then
    echo "  PASS  $1"; pass=$((pass + 1))
  else
    echo "  FAIL  $1"; echo "        want: $3"; echo "        got:  $2"; fail=$((fail + 1))
  fi
}
reset() {
  rm -rf "$STAGING_DIR" "$T/parts-calls" "$T/deny" "$CHECK2_FAILS"
  mkdir -p "$STAGING_DIR"
  for n in A B C; do echo "$n" > "$STAGING_DIR/VID_$n.insv"; done
}
calls() { cat "$T/parts-calls" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

echo "no failures recorded"
reset
parts_fallback "$STAGING_DIR"/*.insv
ck "parts never called" "$(calls)" ""

echo "below the threshold"
reset; echo VID_A.insv > "$CHECK2_FAILS"
parts_fallback "$STAGING_DIR"/*.insv
ck "one failure is not enough" "$(calls)" ""

echo "at the threshold, parts succeed"
reset; printf '%s\n' VID_A.insv VID_B.insv VID_A.insv > "$CHECK2_FAILS"
parts_fallback "$STAGING_DIR"/*.insv
ck "only the twice-failed file goes to parts" "$(calls)" "VID_A.insv"
ck "it stays staged for tg-upload.sh to clear" "$([[ -f "$STAGING_DIR/VID_A.insv" ]] && echo yes)" "yes"
ck "its count is reset" "$(grep -cx VID_A.insv "$CHECK2_FAILS" || true)" "0"
ck "other counts are kept" "$(grep -cx VID_B.insv "$CHECK2_FAILS" || true)" "1"

echo "at the threshold, parts fail too"
reset; printf '%s\n' VID_C.insv VID_C.insv > "$CHECK2_FAILS"; echo VID_C.insv > "$T/deny"
parts_fallback "$STAGING_DIR"/*.insv
ck "parts attempted" "$(calls)" "VID_C.insv"
ck "moved out of staging" "$([[ -e "$STAGING_DIR/VID_C.insv" ]] && echo still || echo gone)" "gone"
ck "into .hold, intact" "$(cat "$HOLD_DIR/VID_C.insv")" "C"
ck "the others are untouched" "$(ls "$STAGING_DIR" | tr '\n' ' ')" "VID_A.insv VID_B.insv "
ck "its count is reset" "$(grep -cx VID_C.insv "$CHECK2_FAILS" || true)" "0"

echo "counts are per exact name"
reset; printf '%s\n' XVID_A.insv XVID_A.insv VID_A.insv.bak VID_A.insv.bak > "$CHECK2_FAILS"
parts_fallback "$STAGING_DIR"/*.insv
ck "look-alike names never count" "$(calls)" ""

echo "ensure_stignore"
reset; echo '/.roundtrip' > "$STAGING_DIR/.stignore"
ensure_stignore; ensure_stignore
ck "adds the missing patterns once" "$(tr '\n' ' ' < "$STAGING_DIR/.stignore")" "/.roundtrip /.parts.* /.hold "

echo
echo "passed=$pass failed=$fail"
(( fail == 0 ))
