# Manual boot-ordering test (raw QEMU/KVM — portable fallback)

This is a **self-contained, dependency-light** version of the Tier-2 boot-ordering
test. It proves the same thing as the `molecule/vm` scenario — that the role's
data disks are unlocked **at boot** from an **external** Tang over the network,
the decoupled import chain runs, and `allow_discards` survives a reboot — but it
does so with **raw QEMU + a container**, needing **no libvirt, no Vagrant, and no
root**.

## Why this exists alongside `molecule/vm`

The CI Tier-2 test (`molecule/vm`) uses **Vagrant + libvirt/KVM**. That is the
right tool on a workstation or a GitHub runner where libvirt is available, but it
carries real dependencies: `libvirtd`, the `vagrant-libvirt` plugin, membership
of the `libvirt` group, and a second VM for Tang.

This manual harness deliberately keeps **zero** of those dependencies. It uses:

- `qemu-system-x86_64` directly with **user-mode / slirp** networking — the guest
  gets a fixed `10.0.2.15` and reaches the host via `10.0.2.2`, so there are no
  bridges and no libvirt networks — and
- a **container** (docker or podman) for the external Tang, published to host
  loopback.

That makes it the portable fallback for the day this project moves **off GitHub**
(or onto any CI/host without libvirt) — it will run on anything with QEMU + a
container runtime, rootless. It is **not** wired into CI; run it by hand.

> If you have libvirt available, prefer `molecule test -s vm` (see the repo
> README "Testing" section). This harness is the escape hatch, kept current so it
> is ready if the libvirt path ever becomes unavailable.

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
   │  /dev/vdb /dev/vdc  ->  LUKS2 (NBDE-unlock) │
   └─────────────────────────────────────────────┘
        ▲ role applied over SSH (boot 1), then reboot, then verify (boot 2)
```

Tang lives **off the VM** so the unlock genuinely exercises the network path the
boot ordering exists for. No root, no bridges, no libvirt — only a published
container port and QEMU's slirp gateway. Falls back to TCG if `/dev/kvm` is absent
(slow; KVM strongly preferred).

## Run

```bash
manual_test/run.sh test        # full: Tang + build + boot + apply + reboot + verify
manual_test/run.sh up          # just start Tang + boot the VM (then ssh in)
manual_test/run.sh teardown    # stop VM + Tang, remove overlays (keep base cache)
manual_test/run.sh clean       # also remove the cached base image
```

### Requirements (host / control)

- `qemu-system-x86_64`, `qemu-img`, `genisoimage` (or `xorriso`)
- `docker` **or** `podman`
- `ansible-playbook` + the `ansible.posix` collection
- `/usr/share/dict/words` for recovery-passphrase generation
  (Debian/Ubuntu: `apt-get install -y wamerican`; Fedora: `dnf install -y words`)
- access to `/dev/kvm` for acceleration (optional but strongly recommended)

All generated artifacts (base image, overlays, seed ISO, SSH key, serial log)
live under `manual_test/.run/` and are gitignored.

## What it asserts (`verify.yml`, after the reboot)

- `clevis-luks-unlocked.target` is **active** (the public NBDE seam was reached);
- `clevis-unlock-data` succeeded;
- both `crypt-vdb` / `crypt-vdc` mappers are open with **`allow_discards`**
  (durable across the reboot, not just the live-apply);
- `clevis-unlock-data` logged a successful unlock (network unlock from the
  external Tang).

This is an **NBDE-only smoke test** — it proves the unlock + the seam. Assembling
a storage pool on the unlocked mappers is a downstream consumer's job (see
`encrypted_storage_pool` / `proxmox_encrypted_storage`); the full cross-role boot
chain (including a real pool) is covered by `molecule/vm`.

## Files

| File | Purpose |
|---|---|
| `run.sh` | Orchestrator: Tang container, VM build/boot, apply role over SSH, reboot, verify, teardown. |
| `playbook.yml` | The role applied to the VM — also a copy-paste **reference playbook** for real deployments. |
| `verify.yml` | Post-reboot assertions. |
| `cloud-init/` | NoCloud seed: SSH access + apt refresh (no ZFS/DKMS — this role is NBDE-only). |
