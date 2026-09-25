#!/usr/bin/env bash
# End-to-end fixtures for tg-upload.sh's Check #2, against a fake channel.
#
# WHY. Check #2 gates deleting footage from staging and recording it in the
# ledger - and the ledger is what later lets tg-prune delete it from the card.
# Since 2026-09-25 it judges each file on its own round trip: verified files
# are recorded and cleared, failures stay staged and are logged for
# tg-archive.sh's parts fallback. Pinned here, running the SHIPPED tg-upload.sh
# and verify-batch.sh end to end:
#   - a clean batch records and clears every file, and exits 0
#   - one unservable file: the other is recorded and cleared, the bad one stays
#     staged, is logged in check2-failures, and the run exits non-zero
#   - a corrupted round trip is treated exactly like an unservable one
#   - nothing served at all: nothing recorded, nothing cleared
#   - retries use the parallel fetcher, and never the whole channel
#
# Stubs: telegram-upload, telegram-download, the resolver and both fetchers
# work over channel/<id>__<name>. The one-at-a-time fetcher stops at its first
# failure and the parallel one carries on, as the real ones do. `df` reports
# the scratch directory on /mnt/media, as on the VM, so the root-filesystem
# guard is exercised rather than bypassed.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sut"
cp "$HERE/tg-upload.sh" "$HERE/verify-batch.sh" "$T/sut/"
for s in tg-resolve-ids.py tg-fetch-ids.py tg-fetch-par.py; do : > "$T/sut/$s"; done

cat > "$T/bin/df" <<'EOF'
#!/usr/bin/env bash
p="${*: -1}"; m=/mnt/media; [[ "$p" == / ]] && m=/
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 900000000 0 800000000 0%% %s\n' "$m"
EOF

cat > "$T/bin/telegram-upload" <<EOF
#!/usr/bin/env bash
f="\${@: -1}"; id=\$(cat "$T/next_id"); echo \$(( id + 1 )) > "$T/next_id"
cp "\$f" "$T/channel/\${id}__\$(basename "\$f")"
EOF

cat > "$T/bin/telegram-download" <<EOF
#!/usr/bin/env bash
echo whole-channel >> "$T/calls"; exit 1
EOF

cat > "$T/bin/py" <<EOF
#!/usr/bin/env bash
mode="\$(basename "\$1")"; shift
echo "\$mode" >> "$T/calls"
while [[ "\${1:-}" == --* ]]; do
  if [[ "\$1" == --into ]]; then into="\$2"; fi
  shift 2
done
serve() {  # serve <id>: copy one message into \$into, honouring dead/corrupt
  local src name
  src=\$(ls "$T/channel"/"\$1"__* 2>/dev/null | head -1)
  [[ -n "\$src" ]] || return 1
  name=\${src##*__}
  if grep -qxF "\$name" "$T/dead" 2>/dev/null; then return 1; fi
  cp "\$src" "\$into/\$name"
  if grep -qxF "\$name" "$T/corrupt" 2>/dev/null; then printf X >> "\$into/\$name"; fi
}
case "\$mode" in
  tg-resolve-ids.py)
    for n in "\$@"; do
      id=\$(ls "$T/channel" | awk -F'__' -v n="\$n" '\$2 == n { print \$1 }' | sort -n | tail -1)
      if [[ -n "\$id" ]]; then printf '%s\t%s\n' "\$n" "\$id"; fi
    done ;;
  tg-fetch-ids.py)
    for id in "\$@"; do serve "\$id" || exit 1; done ;;
  tg-fetch-par.py)
    rc=0; for id in "\$@"; do serve "\$id" || rc=1; done; exit \$rc ;;
esac
EOF
chmod +x "$T/bin/"*

setup() {
  rm -rf "$T/staging" "$T/work" "$T/channel"
  mkdir -p "$T/staging" "$T/work" "$T/channel"
  echo 500 > "$T/next_id"; : > "$T/calls"; : > "$T/dead"; : > "$T/corrupt"
  head -c 4000 /dev/urandom > "$T/staging/VID_A.insv"
  head -c 6000 /dev/urandom > "$T/staging/VID_B.insv"
  ( cd "$T/staging" && sha256sum VID_A.insv VID_B.insv ) > "$T/manifest.sha256"
  echo '{}' > "$T/cfg.json"
  cat > "$T/env" <<EOF
STAGING_DIR=$T/staging
MANIFEST=$T/manifest.sha256
WORK_DIR=$T/work
TG_CHANNEL=-100123
TG_CONFIG=$T/cfg.json
GUARD_MARGIN_GB=0
EOF
}

run() {
  PATH="$T/bin:$PATH" TG_ENV_FILE="$T/env" PIPX_PY="$T/bin/py" \
    TG_PAR_FETCH=1 TG_FETCH_RETRY_DELAYS="0 0" \
    bash "$T/sut/tg-upload.sh" > "$T/out" 2>&1
}

pass=0; fail=0
ck() {
  if [[ "$2" == "$3" ]]; then
    echo "  PASS  $1"; pass=$((pass + 1))
  else
    echo "  FAIL  $1"; echo "        want: $3"; echo "        got:  $2"; fail=$((fail + 1))
    sed 's/^/        | /' "$T/out" | tail -25
  fi
}
ledger_names() { awk '{ print $2 }' "$T/work/uploaded.sha256" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'; }
staged() { ( cd "$T/staging" && ls -1 ./*.insv 2>/dev/null | sed 's#^\./##' | tr '\n' ' ' | sed 's/ $//' ); }
fails() { sort "$T/work/check2-failures" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

echo "clean batch"
setup; rc=0; run || rc=$?
ck "exits 0" "$rc" "0"
ck "both recorded" "$(ledger_names)" "VID_A.insv VID_B.insv"
ck "staging cleared" "$(staged)" ""
ck "no failures logged" "$(fails)" ""

echo "one file Telegram will not serve"
setup; echo VID_B.insv > "$T/dead"; rc=0; run || rc=$?
ck "exits non-zero" "$(( rc != 0 ))" "1"
ck "the good file is recorded" "$(ledger_names)" "VID_A.insv"
ck "the good file is cleared, the bad one stays" "$(staged)" "VID_B.insv"
ck "the bad one is logged for the parts fallback" "$(fails)" "VID_B.insv"
ck "retries used the parallel fetcher" "$(grep -c tg-fetch-par.py "$T/calls")" "3"
ck "never the whole channel" "$(grep -c whole-channel "$T/calls")" "0"
ck "says PARTIAL" "$(grep -c 'PARTIAL: 1 verified' "$T/out")" "1"

echo "a corrupted round trip"
setup; echo VID_A.insv > "$T/corrupt"; rc=0; run || rc=$?
ck "exits non-zero" "$(( rc != 0 ))" "1"
ck "only the intact file is recorded" "$(ledger_names)" "VID_B.insv"
ck "the corrupted one stays staged" "$(staged)" "VID_A.insv"
ck "and is logged" "$(fails)" "VID_A.insv"

echo "nothing served at all"
setup; printf '%s\n' VID_A.insv VID_B.insv > "$T/dead"; rc=0; run || rc=$?
ck "exits non-zero" "$(( rc != 0 ))" "1"
ck "nothing recorded" "$(ledger_names)" ""
ck "nothing cleared" "$(staged)" "VID_A.insv VID_B.insv"
ck "both logged" "$(fails)" "VID_A.insv VID_B.insv"

echo
echo "passed=$pass failed=$fail"
(( fail == 0 ))
