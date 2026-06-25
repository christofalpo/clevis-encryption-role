#!/usr/bin/env bash
# =============================================================================
# tests/vm/run.sh — Tier-2 VM test: prove the clevis-encryption role's REAL boot
# ordering and network unlock, which a container cannot.
#
# Topology (Option B — unprivileged, GitHub-runner friendly):
#   - an EXTERNAL Tang in a container on an isolated podman/docker network,
#     published to host loopback (127.0.0.1:7500);
#   - a throwaway Debian 13 VM under QEMU/KVM with two blank data disks, reaching
#     Tang over the network via QEMU's slirp gateway (10.0.2.2 -> host loopback);
#   - the role is applied over SSH by tests/vm/playbook.yml, then the VM is
#     REBOOTED and tests/vm/verify.yml asserts the boot chain actually fired.
#
# No root, no bridges, no libvirt: only a published container port + QEMU slirp.
# Falls back to TCG if /dev/kvm is unavailable (slow — KVM strongly preferred).
#
# Usage:
#   ./run.sh test       # full: tang + build + boot + apply + reboot + verify   (default)
#   ./run.sh build      # download base image, make disks, build seed ISO
#   ./run.sh up         # start Tang + boot the VM (no ansible)
#   ./run.sh teardown   # stop VM + Tang, remove overlays/seed (keep base cache)
#   ./run.sh clean      # teardown + remove the base-image cache
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
RUNDIR="$HERE/.run"            # all generated artifacts (gitignored)
mkdir -p "$RUNDIR"

# ── tunables (env-overridable) ───────────────────────────────────────────────
IMG_URL="${IMG_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2}"
BASE="$RUNDIR/base-debian13.qcow2"
OS="$RUNDIR/os.qcow2"; DB="$RUNDIR/data-b.qcow2"; DC="$RUNDIR/data-c.qcow2"
SEED="$RUNDIR/seed.iso"; SERIAL="$RUNDIR/serial.log"
KEY="$RUNDIR/id_vm"; VAULTPASS="$RUNDIR/vault-pass"; RECKEY="$RUNDIR/recovery-key.txt"
INV="$RUNDIR/inventory"; QPID="$RUNDIR/qemu.pid"
MEM="${MEM:-3072}"; SMP="${SMP:-4}"
SSH_PORT="${SSH_PORT:-2222}"          # host -> guest:22
TANG_PORT="${TANG_PORT:-7500}"        # host loopback -> tang container
TANG_URL_GUEST="http://10.0.2.2:${TANG_PORT}"   # how the guest reaches Tang
NET="clevis-test-net"; TANG_NAME="clevis-tang"
SSH_WAIT="${SSH_WAIT:-240}"           # seconds to wait for SSH after a boot
PREP_WAIT="${PREP_WAIT:-600}"         # seconds to wait for cloud-init (zfs-dkms)
CHAIN_WAIT="${CHAIN_WAIT:-210}"       # seconds to wait for the boot chain to settle post-reboot

RT=""        # container runtime (docker|podman), resolved in deps()
ACCEL="tcg"  # kvm|tcg, resolved in deps()

say(){ printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die(){ printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

SSH_OPTS=(-i "$KEY" -p "$SSH_PORT"
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o IdentitiesOnly=yes -o IdentityAgent=none      # ignore the caller's ssh-agent:
  -o LogLevel=ERROR -o ConnectTimeout=5)            # an agent full of keys hits sshd MaxAuthTries
vm_ssh(){ ssh "${SSH_OPTS[@]}" debian@127.0.0.1 "$@"; }

# ── dependency + capability detection ────────────────────────────────────────
deps(){
  command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not found (install qemu-system-x86 / qemu-kvm)"
  command -v qemu-img >/dev/null          || die "qemu-img not found (install qemu-utils)"
  command -v genisoimage >/dev/null || command -v xorriso >/dev/null || die "need genisoimage or xorriso"
  command -v ansible-playbook >/dev/null  || die "ansible-playbook not found"
  command -v ssh >/dev/null && command -v ssh-keygen >/dev/null || die "ssh/ssh-keygen not found"
  command -v wget >/dev/null || command -v curl >/dev/null || die "need wget or curl to fetch the image"
  if   command -v docker >/dev/null; then RT=docker
  elif command -v podman >/dev/null; then RT=podman
  else die "need docker or podman for the Tang container"; fi
  [ -r /usr/share/dict/words ] || die "controller needs /usr/share/dict/words for passphrase generation (Debian/Ubuntu: apt-get install -y wamerican ; Fedora: dnf install -y words)"
  if [ -w /dev/kvm ]; then ACCEL=kvm; else ACCEL=tcg; warn "/dev/kvm not writable -> using TCG (SLOW). On GitHub runners ensure KVM is enabled."; fi
  say "runtime=$RT  accel=$ACCEL  qemu=$(qemu-system-x86_64 --version | head -1 | grep -oE '[0-9.]+' | head -1)"
}

iso(){ if command -v genisoimage >/dev/null; then genisoimage "$@"; else xorriso -as genisoimage "$@"; fi; }

# ── external Tang on an isolated network, published to host loopback ─────────
tang_up(){
  say "starting external Tang ($RT, network $NET, 127.0.0.1:${TANG_PORT})"
  "$RT" network create "$NET" >/dev/null 2>&1 || true
  "$RT" rm -f "$TANG_NAME" >/dev/null 2>&1 || true
  "$RT" run -d --name "$TANG_NAME" --network "$NET" \
    -p "127.0.0.1:${TANG_PORT}:${TANG_PORT}" debian:trixie-slim \
    bash -c 'set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq tang socat >/dev/null
      kg=$(command -v tangd-keygen || find /usr/lib /usr/libexec -name tangd-keygen 2>/dev/null | head -1)
      td=$(command -v tangd      || find /usr/lib /usr/libexec -name tangd 2>/dev/null | head -1)
      mkdir -p /var/db/tang
      ls /var/db/tang/*.jwk >/dev/null 2>&1 || "$kg" /var/db/tang
      exec socat TCP-LISTEN:'"${TANG_PORT}"',fork,reuseaddr "EXEC:$td /var/db/tang"' >/dev/null
  say "waiting for Tang /adv ..."
  local i
  for i in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:${TANG_PORT}/adv" >/dev/null 2>&1; then say "Tang is up."; return 0; fi
    sleep 1
  done
  "$RT" logs "$TANG_NAME" 2>&1 | tail -20 || true
  die "Tang did not come up on 127.0.0.1:${TANG_PORT}"
}

# ── build the VM disks + cloud-init seed ─────────────────────────────────────
build(){
  deps
  [ -f "$KEY" ] || ssh-keygen -t ed25519 -N '' -f "$KEY" -C clevis-vm-test >/dev/null
  if [ ! -f "$BASE" ]; then
    say "downloading Debian 13 genericcloud image (cached)"
    if command -v wget >/dev/null; then wget -q -O "$BASE.part" "$IMG_URL"; else curl -fsSL -o "$BASE.part" "$IMG_URL"; fi
    mv "$BASE.part" "$BASE"
  else say "base image cached ($BASE)"; fi

  say "creating OS overlay + two 1.5G data disks"
  rm -f "$OS" "$DB" "$DC"
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$OS" 10G
  qemu-img create -q -f qcow2 "$DB" 1536M
  qemu-img create -q -f qcow2 "$DC" 1536M

  say "building cloud-init seed (injecting SSH key)"
  local pub; pub="$(cat "$KEY.pub")"
  sed "s|__SSH_PUBKEY__|${pub}|" "$HERE/cloud-init/user-data.tmpl" > "$RUNDIR/user-data"
  cp "$HERE/cloud-init/meta-data" "$RUNDIR/meta-data"
  rm -f "$SEED"
  iso -quiet -output "$SEED" -volid cidata -joliet -rock "$RUNDIR/user-data" "$RUNDIR/meta-data"
  say "build complete."
}

# ── boot / reboot the VM ─────────────────────────────────────────────────────
qemu_boot(){
  : > "$SERIAL"
  say "booting VM (accel=$ACCEL, ${MEM}MB/${SMP}cpu; ssh on 127.0.0.1:${SSH_PORT})"
  qemu-system-x86_64 \
    -machine type=q35,accel="$ACCEL" -cpu host -m "$MEM" -smp "$SMP" \
    -drive file="$OS",if=virtio,format=qcow2 \
    -drive file="$DB",if=virtio,format=qcow2,discard=unmap,detect-zeroes=unmap \
    -drive file="$DC",if=virtio,format=qcow2,discard=unmap,detect-zeroes=unmap \
    -drive file="$SEED",media=cdrom \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -display none -serial "file:$SERIAL" -daemonize -pidfile "$QPID"
  say "qemu pid=$(cat "$QPID")"
}

wait_ssh(){
  say "waiting for SSH (up to ${1:-$SSH_WAIT}s) ..."
  local i
  for i in $(seq 1 "${1:-$SSH_WAIT}"); do
    if vm_ssh true >/dev/null 2>&1; then say "SSH up."; return 0; fi
    sleep 1
  done
  tail -40 "$SERIAL" || true
  die "VM SSH did not come up"
}

# ── full test ────────────────────────────────────────────────────────────────
do_test(){
  deps
  trap teardown EXIT INT TERM
  tang_up
  build
  qemu_boot
  wait_ssh

  say "waiting for cloud-init platform prep (zfs-dkms build, up to ${PREP_WAIT}s)"
  vm_ssh "sudo cloud-init status --wait" || warn "cloud-init status --wait returned non-zero"
  vm_ssh "lsmod | grep -q zfs && echo 'zfs module loaded' || (sudo modprobe zfs && echo 'zfs modprobed')" \
    || die "ZFS kernel module not available in the VM (DKMS build failed) — see $SERIAL"

  printf 'clevis-vm ansible_host=127.0.0.1 ansible_port=%s ansible_user=debian ansible_ssh_private_key_file=%s ansible_python_interpreter=/usr/bin/python3 ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o IdentityAgent=none"\n' \
    "$SSH_PORT" "$KEY" > "$INV"
  head -c 32 /dev/urandom | base64 > "$VAULTPASS"; chmod 600 "$VAULTPASS"
  rm -f "$RECKEY" "$RECKEY.bak"          # force a fresh provisioning run each time

  # tang_servers defaults to http://10.0.2.2:${TANG_PORT} in playbook.yml; only
  # override if a non-default TANG_PORT is in use (pass valid JSON, not key=val).
  local tang_eopt=()
  [ "$TANG_PORT" = "7500" ] || tang_eopt=(-e "{\"tang_servers\":[{\"url\":\"$TANG_URL_GUEST\"}]}")

  say "applying the role over SSH (tests/vm/playbook.yml)"
  ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i "$INV" "$HERE/playbook.yml" \
    -e "clevis_recovery_key_path=$RECKEY" \
    -e "clevis_vault_password_file=$VAULTPASS" \
    "${tang_eopt[@]}"

  say "REBOOTING the VM to exercise the real boot chain"
  vm_ssh "sudo systemctl reboot" || true
  sleep 8                                  # let sshd go down before we poll it
  wait_ssh

  # sshd comes up at multi-user.target, but the unlock -> import -> pool-check ->
  # ready.target chain is NOT ordered before multi-user and has retry delays, so
  # it can still be running when SSH is back. Wait for it to settle before
  # asserting (active = done; otherwise verify.yml reports the real failure).
  say "waiting for the boot chain to settle (ready.target, up to ${CHAIN_WAIT}s)"
  local i st
  for i in $(seq 1 "$((CHAIN_WAIT / 3))"); do
    st=$(vm_ssh systemctl is-active encrypted-storage-ready.target 2>/dev/null || true)
    [ "$st" = active ] && { say "boot chain settled (ready.target active after ~$((i * 3))s)"; break; }
    sleep 3
  done
  say "boot-2 chain status + clevis-unlock-data journal:"
  vm_ssh 'for u in clevis-unlock-data.service encrypted-storage-import.service encrypted-storage-pool-check.service encrypted-storage-ready.target; do printf "  %-40s %s\n" "$u" "$(systemctl is-active "$u" 2>/dev/null)"; done; echo "--- clevis-unlock-data journal ---"; journalctl -b -u clevis-unlock-data.service --no-pager | tail -25' || true

  say "verifying boot-time unlock + ordering (tests/vm/verify.yml)"
  ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i "$INV" "$HERE/verify.yml"

  say "VM BOOT-ORDERING TEST PASSED ✅"
}

# ── lifecycle ────────────────────────────────────────────────────────────────
vm_kill(){ [ -f "$QPID" ] && kill "$(cat "$QPID")" 2>/dev/null || true; rm -f "$QPID"; }
teardown(){
  local rc=$?
  trap - EXIT
  say "teardown"
  vm_kill
  [ -n "$RT" ] && { "$RT" rm -f "$TANG_NAME" >/dev/null 2>&1 || true; "$RT" network rm "$NET" >/dev/null 2>&1 || true; }
  rm -f "$OS" "$DB" "$DC" "$SEED" "$RUNDIR/user-data" "$RUNDIR/meta-data"
  return "$rc"
}
clean(){ deps; teardown || true; rm -f "$BASE"; say "removed base-image cache"; }
up(){ deps; trap teardown EXIT; tang_up; build; qemu_boot; wait_ssh; say "VM up. ssh: ssh ${SSH_OPTS[*]} debian@127.0.0.1 ; Ctrl-C to tear down."; sleep infinity; }

case "${1:-test}" in
  test)     do_test ;;
  build)    build ;;
  up)       up ;;
  teardown) RT="$(command -v docker >/dev/null && echo docker || echo podman)"; teardown ;;
  clean)    clean ;;
  *) echo "usage: $0 {test|build|up|teardown|clean}"; exit 1 ;;
esac
