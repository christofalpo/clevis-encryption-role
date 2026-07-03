#!/usr/bin/env bash
# =============================================================================
# harness-tang-roundtrip.sh — validate the clevis<->tang CRYPTO + NETWORK layer
# WITHOUT any block device, LUKS, or root capability.
#
#   clevis encrypt tang | clevis decrypt must round-trip using the IP family the
#   role pinned in its curlrc (read via CURL_HOME), and must FAIL when curl is
#   forced onto a family that cannot reach the Tang server.  This is the exact
#   path clevis-{encrypt,decrypt}-tang take — both call `curl -sfg` WITHOUT -q,
#   so they read $CURL_HOME/.curlrc.  This is the subject of the network branch:
#   the LUKS keyslot layer is tested separately (the rootful `default` scenario).
#
# Args:  $1 = role's CURL_HOME dir (default /etc/clevis/curl)
#        $2 = Tang URL            (default http://127.0.0.1:7500, IPv4-only here)
# Exit 0 iff every assertion passes (and prints FAIL=0).
# =============================================================================
set -uo pipefail
CURL_HOME_ROLE="${1:-/etc/clevis/curl}"
TANG_URL="${2:-http://127.0.0.1:7500}"
PASS=0; FAIL=0
ok(){ printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad(){ printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
info(){ printf '  ..... %s\n' "$*"; }
SECRET="tang-roundtrip-$$"

roundtrip() { # $1 = CURL_HOME dir ; round-trips $SECRET through clevis+tang
  local ch="$1" jwe dec
  # Feed stdin with printf '%s' (NOT a <<< here-string): a here-string appends a
  # trailing newline, and clevis decrypt exits non-zero on the trailing byte of
  # the JWE even though it emits the correct plaintext — a false failure.
  jwe=$(printf '%s' "$SECRET" | CURL_HOME="$ch" clevis encrypt tang "{\"url\":\"$TANG_URL\"}" -y 2>/tmp/rt_e.err) || return 1
  dec=$(printf '%s' "$jwe" | CURL_HOME="$ch" clevis decrypt 2>/tmp/rt_d.err) || return 2
  [ "$dec" = "$SECRET" ]
}

info "role curlrc ($CURL_HOME_ROLE/.curlrc): [$(tr '\n' ' ' < "$CURL_HOME_ROLE/.curlrc" 2>/dev/null)]"

# 1. POSITIVE — the family the role pinned must reach Tang and round-trip.
if roundtrip "$CURL_HOME_ROLE"; then
  ok "round-trip OK using the role-pinned family"
else
  bad "round-trip FAILED with role curlrc: $(head -1 /tmp/rt_e.err /tmp/rt_d.err 2>/dev/null | tr '\n' ' ')"
fi

# 2. NEGATIVE CONTROL — force the OPPOSITE family.  Tang here is IPv4-only, so
#    --ipv6 must break the advertisement fetch.  If it instead succeeds, clevis
#    is NOT reading the curlrc (CURL_HOME mechanism broken) — a real failure.
wrong=$(mktemp -d); printf -- '--ipv6\n' > "$wrong/.curlrc"
if roundtrip "$wrong"; then
  bad "negative control: --ipv6 unexpectedly succeeded — curlrc/CURL_HOME not honored"
else
  ok "negative control: --ipv6 cannot reach IPv4-only Tang (the pin is decisive)"
fi
rm -rf "$wrong"

echo "  PASS=$PASS FAIL=$FAIL"
echo "=== HARNESS-TANG-ROUNDTRIP COMPLETE rc=$([ "$FAIL" -eq 0 ] && echo 0 || echo 1) ==="
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
