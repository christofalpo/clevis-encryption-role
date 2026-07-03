#!/usr/bin/env bash
# =============================================================================
# harness-unlock-o.sh — validate the DURABLE-open behaviour of clevis-encryption:
#   `clevis luks unlock -o "--allow-discards"` must land allow_discards on the
#   mapper at open time (the clevis-unlock-data.sh.j2 array logic), and the
#   configure-disk live-apply must enable it via the `clevis luks pass -s |
#   cryptsetup refresh` chain (with token-JWE fallback).  Mirrors the exact
#   commands the role ships.
#
# Vendored into the Molecule scenario from the KvalitetsIT luks-zfs-trim-test rig
# (the source-agnostic clevis harness).  Self-contained: needs only LUKS2 + a
# local Tang + clevis, NO ZFS.  Uses a dedicated loopback file so it never
# touches the role's crypt-loop0 mapper.  Winner check = `dmsetup table`.
# Exit 0 iff every assertion passes (and prints FAIL=0).
# =============================================================================
set -uo pipefail
KEYFILE=/root/k.key; IMG=/var/tmp/unlock-o.img; NAME=crypt-uotest; TANG_PORT=7500
PASS=0; FAIL=0
ok(){ printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad(){ printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
info(){ printf '  ..... %s\n' "$*"; }
banner(){ printf '\n== %s ==\n' "$*"; }
has_discard(){ dmsetup table "$NAME" 2>/dev/null | grep -q allow_discards; }
has_flag(){ cryptsetup status "$NAME" 2>/dev/null | grep -q "$1"; }
close(){ cryptsetup close "$NAME" 2>/dev/null || true; }

[ "$(id -u)" -eq 0 ] || { echo FATAL root; exit 2; }

banner "SETUP: dedicated loopback LUKS2 + local Tang + clevis bind"
# Always use a dedicated loop file — never the role's data disk.
truncate -s 600M "$IMG"
DEV=$(losetup -f --show "$IMG")
info "loop device = $DEV"
head -c 64 /dev/urandom > "$KEYFILE"; chmod 600 "$KEYFILE"
cryptsetup luksFormat --type luks2 --batch-mode --pbkdf pbkdf2 --pbkdf-force-iterations 1000 "$DEV" "$KEYFILE"

# tang 15 (Debian 13) ships binaries in the tang-common package under /usr/libexec
# (off $PATH), so locate tangd-keygen robustly: PATH, then tang/tang-common file
# lists, then a direct search.
keygen=$(command -v tangd-keygen 2>/dev/null || true)
[ -n "$keygen" ] || keygen=$(dpkg -L tang tang-common 2>/dev/null | grep -m1 '/tangd-keygen$' || true)
[ -n "$keygen" ] || keygen=$(find /usr/libexec /usr/lib /usr/bin -name tangd-keygen 2>/dev/null | head -n1)
mkdir -p /var/db/tang
ls /var/db/tang/*.jwk >/dev/null 2>&1 || { [ -n "$keygen" ] && "$keygen" /var/db/tang >/dev/null 2>&1; }
systemctl restart tangd.socket 2>/dev/null || true; sleep 1
p=$(systemctl show tangd.socket -p Listen --value 2>/dev/null | grep -oE '[0-9]+ \(Stream\)$' | grep -oE '^[0-9]+' | head -1); [ -n "$p" ] && TANG_PORT="$p"
curl -sf "http://127.0.0.1:$TANG_PORT/adv" >/dev/null 2>&1 && ok "tang up on :$TANG_PORT" || bad "tang not reachable on :$TANG_PORT"
clevis luks bind -y -d "$DEV" -k "$KEYFILE" tang "{\"url\":\"http://127.0.0.1:$TANG_PORT\"}" >/tmp/bind.err 2>&1 \
  && ok "clevis bound" || bad "clevis bind failed: $(tr -d '\n'</tmp/bind.err)"
slot=$(clevis luks list -d "$DEV" 2>/dev/null | head -1 | cut -d: -f1 | tr -d ' '); info "clevis slot = ${slot:-none}"

# ---------------------------------------------------------------------------
# TEST 1 — the EXACT array logic from clevis-unlock-data.sh.j2, single option.
banner "TEST 1: clevis luks unlock -o (OPEN_OPTS='--allow-discards')"
close
OPEN_OPTS="--allow-discards"
unlock_args=(-d "$DEV" -n "$NAME")
[ -n "$OPEN_OPTS" ] && unlock_args+=(-o "$OPEN_OPTS")
if clevis luks unlock "${unlock_args[@]}" >/tmp/u1.err 2>&1; then
  has_discard && ok "T1 opened WITH allow_discards" || bad "T1 opened but NO allow_discards"
else
  bad "T1 clevis luks unlock failed: $(tr -d '\n'</tmp/u1.err)"
fi

# ---------------------------------------------------------------------------
# TEST 2 — multi-word OPEN_OPTS (discard + perf flags), array word-splitting.
banner "TEST 2: clevis luks unlock -o (multi-word: --allow-discards + perf flags)"
close
OPEN_OPTS="--allow-discards --perf-no_read_workqueue --perf-no_write_workqueue"
unlock_args=(-d "$DEV" -n "$NAME")
[ -n "$OPEN_OPTS" ] && unlock_args+=(-o "$OPEN_OPTS")
if clevis luks unlock "${unlock_args[@]}" >/tmp/u2.err 2>&1; then
  has_discard && ok "T2 allow_discards present" || bad "T2 NO allow_discards"
  has_flag no_read_workqueue  && ok "T2 no_read_workqueue present"  || bad "T2 NO no_read_workqueue"
  has_flag no_write_workqueue && ok "T2 no_write_workqueue present" || bad "T2 NO no_write_workqueue"
else
  bad "T2 clevis luks unlock failed: $(tr -d '\n'</tmp/u2.err)"
fi

# ---------------------------------------------------------------------------
# TEST 3 — empty OPEN_OPTS must add NO -o and open without discard.
banner "TEST 3: OPEN_OPTS='' opens without -o (no discard)"
close
OPEN_OPTS=""
unlock_args=(-d "$DEV" -n "$NAME")
[ -n "$OPEN_OPTS" ] && unlock_args+=(-o "$OPEN_OPTS")
if clevis luks unlock "${unlock_args[@]}" >/tmp/u3.err 2>&1; then
  has_discard && bad "T3 unexpectedly has allow_discards" || ok "T3 opened without discard (as expected)"
else
  bad "T3 clevis luks unlock failed: $(tr -d '\n'</tmp/u3.err)"
fi

# ---------------------------------------------------------------------------
# TEST 4 — configure-disk live-apply: clevis luks pass -s | cryptsetup refresh,
# with the token-JWE decrypt fallback (the role's exact chain).
banner "TEST 4: live refresh enables allow_discards on the open mapper"
has_discard && bad "T4 precondition: already has discard" || info "T4 precondition ok (no discard)"
applied=""
if [ -n "$slot" ]; then
  if clevis luks pass -d "$DEV" -s "$slot" 2>/tmp/p.err \
       | cryptsetup refresh --allow-discards --key-file - "$NAME" 2>/tmp/r.err; then
    applied="clevis-pass"
  fi
fi
if [ -z "$applied" ]; then
  tid=$(cryptsetup luksDump "$DEV" 2>/dev/null | awk -F: '/^[[:space:]]+[0-9]+: clevis/{gsub(/[^0-9]/,"",$1); print $1; exit}')
  info "T4 falling back to token-JWE decrypt (tid=${tid:-none})"
  if [ -n "$tid" ]; then
    cryptsetup token export --token-id "$tid" "$DEV" 2>/dev/null \
      | jose fmt -j- -Og jwe -o- 2>/dev/null | jose jwe fmt -i- -c 2>/dev/null \
      | clevis decrypt 2>/dev/null \
      | cryptsetup refresh --allow-discards --key-file - "$NAME" 2>/tmp/r2.err && applied="clevis-token"
  fi
fi
if [ -n "$applied" ] && has_discard; then ok "T4 refresh enabled allow_discards via $applied"
else bad "T4 refresh did not land allow_discards (pass-err=[$(tr -d '\n'</tmp/p.err 2>/dev/null)] refresh-err=[$(tr -d '\n'</tmp/r.err 2>/dev/null)])"; fi

# ---------------------------------------------------------------------------
banner "RESULT"
echo "  PASS=$PASS FAIL=$FAIL"
close
losetup -d "$DEV" 2>/dev/null || true
rm -f "$IMG" "$KEYFILE"
echo "=== HARNESS-UNLOCK-O COMPLETE rc=$([ "$FAIL" -eq 0 ] && echo 0 || echo 1) ==="
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
