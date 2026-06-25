# Tier-2 VM boot-ordering test

Proves the one thing the Molecule container scenarios cannot: that the role's
**boot ordering** actually works — the data disks are unlocked at boot from an
**external** Tang over the network, the decoupled import chain runs, and
`allow_discards` survives a reboot.

A container can never test this: there is no initramfs, no real
`network-online.target` sequencing, and no reboot. So this tier boots a real
Debian 13 VM under QEMU/KVM, applies the role, **reboots**, and asserts the live
boot chain.

## Topology (unprivileged, GitHub-runner friendly)

```
        isolated podman/docker network (clevis-test-net)
        ┌───────────────────────────┐
        │  Tang container           │   published to host 127.0.0.1:7500
        │  (socat -> tangd)         │
        └───────────────────────────┘
                    ▲  guest reaches it at 10.0.2.2:7500 (QEMU slirp -> host loopback)
                    │
   ┌────────────────┴───────────────────────────┐
   │  Debian 13 VM (QEMU/KVM, user-mode net)     │
   │  /dev/vdb /dev/vdc  ->  LUKS2 -> ZFS mirror │
   └─────────────────────────────────────────────┘
        ▲ role applied over SSH (boot 1), then reboot, then verify (boot 2)
```

Tang lives **off the VM** so the unlock genuinely exercises the network path the
boot ordering exists for. No root, no bridges, no libvirt — only a published
container port and QEMU's slirp gateway. Falls back to TCG if `/dev/kvm` is
absent (slow; KVM strongly preferred).

## Run

```bash
tests/vm/run.sh test        # full: Tang + build + boot + apply + reboot + verify
tests/vm/run.sh up          # just start Tang + boot the VM (then ssh in)
tests/vm/run.sh teardown    # stop VM + Tang, remove overlays (keep base cache)
tests/vm/run.sh clean       # also remove the cached base image
```

### Requirements (host / control)

- `qemu-system-x86_64`, `qemu-img`, `genisoimage` (or `xorriso`)
- `docker` **or** `podman`
- `ansible-playbook` + the `ansible.posix` collection
- `/usr/share/dict/words` for recovery-passphrase generation
  (Debian/Ubuntu: `apt-get install -y wamerican`; Fedora: `dnf install -y words`)
- access to `/dev/kvm` for acceleration (optional but strongly recommended)

All generated artifacts (base image, overlays, seed ISO, SSH key, serial log)
live under `tests/vm/.run/` and are gitignored.

## What it asserts (`verify.yml`, after the reboot)

- `encrypted-storage-ready.target` is **active** (the boot barrier was reached);
- `clevis-unlock-data`, `encrypted-storage-import`, `encrypted-storage-pool-check`
  all succeeded;
- both `crypt-vdb` / `crypt-vdc` mappers are open with **`allow_discards`**
  (durable across the reboot, not just the live-apply);
- the ZFS pool imported and is `ONLINE`;
- `clevis-unlock-data` logged a successful unlock (network unlock from the
  external Tang).

## Files

| File | Purpose |
|---|---|
| `run.sh` | Orchestrator: Tang container, VM build/boot, apply role over SSH, reboot, verify, teardown. |
| `playbook.yml` | The role applied to the VM — also a copy-paste **reference playbook** for real deployments. |
| `verify.yml` | Post-reboot assertions. |
| `cloud-init/` | NoCloud seed: SSH access + platform prep so ZFS DKMS can build (out of the role's scope). |

CI: `.github/workflows/vm-test.yml` runs this on `ubuntu-latest` (which has KVM).
