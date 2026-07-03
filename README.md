# clevis-encryption

An Ansible role that provisions LUKS2 full-disk encryption on Debian hosts and
binds the unlock key to one or more Tang servers using Clevis Shamir Secret
Sharing (Network-Bound Disk Encryption, **NBDE**). It formats and binds the data
disks, opens them in the booted system after the network is up via a
fail-degraded `clevis-unlock-data.service`, and publishes a public
**`clevis-luks-unlocked.target`** systemd seam.

The role is **NBDE-only**. It ends at "the LUKS mappers are open and
`clevis-luks-unlocked.target` has been reached". It does **not** create, import,
or mount any storage — no ZFS pool, no btrfs, no LVM. Assembling a filesystem on
top of the unlocked mappers is the job of a **separate downstream consumer role**
that orders after the seam (see [Storage](#storage-separate-consumer-role)
below). This split keeps the encryption/unlock layer reusable for any storage
backend instead of being welded to one.

> **Upgrading from a 1.x that created a ZFS pool?** ZFS pool creation moved to a
> consumer role in 2.0. See [Upgrade notes → 2.0](#20--zfs-removed).

## Storage (separate consumer role)

This role owns encryption + unlock only. Storage assembly lives in a downstream
consumer role that composes with it across a single stable systemd seam:

```
clevis_encryption  (this role, NBDE)   LUKS2 + Clevis/Tang; opens crypt-* mappers
   └─ publishes  clevis-luks-unlocked.target   ← the seam ("unlock has run")
        │
        ▼
<storage consumer role>                assemble → check → mount the pool
   └─ publishes  encrypted-storage-ready.target ← the barrier consumers gate on
```

**The seam contract.** A consumer orders its own units
`After=`/`Wants= clevis-luks-unlocked.target` (never the internal
`clevis-unlock-data.service` name), does its `assemble → check` chain against the
`/dev/mapper/crypt-*` devices, and emits its own
`encrypted-storage-ready.target` barrier for higher-level services to gate on.

Two consumer roles implement this contract:

| Consumer role | Backend | Where |
|---|---|---|
| `encrypted_storage_pool` | generic **btrfs / LVM** (mainline, no DKMS) | <https://github.com/KvalitetsIT/encrypted-storage-pool> |
| `proxmox_encrypted_storage` | **ZFS** (Proxmox VE) | in the `proxmox-install` repo |

Pick `encrypted_storage_pool` for a generic btrfs/LVM pool; pick
`proxmox_encrypted_storage` when you want the ZFS-on-LUKS behaviour that earlier
versions of *this* role provided in-tree.

## Why this role exists

The two most widely-used public roles for Clevis/Tang automation
(`linux-system-roles/nbde_client`, `stackhpc/ansible-role-luks`) both target
RHEL/Fedora and use **dracut** for initramfs management.  Proxmox VE runs on
**Debian** and uses **initramfs-tools**.  The boot integration is different
enough that neither role works without significant modification.

This role was written specifically for the Debian/initramfs-tools path and
addresses several real-world problems that are not covered by existing public
automation:

- The correct `crypttab` flag combination for Tang-unlocked data disks
  (`noauto,_netdev,x-systemd.after=network-online.target`) — these disks are
  opened in the booted system by a dedicated fail-degraded unlock service, not
  by `systemd-cryptsetup` in early boot
- A self-contained, network-ordered unlock (`clevis-unlock-data.service`
  runs *after* `network-online.target`) that publishes a public
  `clevis-luks-unlocked.target` seam, deliberately **kept out of** the stock
  early `zfs-import`/`local-fs` graph so a storage consumer can order after the
  unlock without forming the systemd ordering cycle that would otherwise delete
  the unlock job (see [How boot unlock works](#how-boot-unlock-works))
- A clevis-scoped IP-family pin (via a `curlrc`) — the role's primary
  network-handling mechanism — so the Tang `curl` call uses the IPv4/IPv6 family
  that actually serves a valid advertisement on dual-stack hosts
  (`clevis_curl_ip_version`)
- Shamir Secret Sharing (SSS) across multiple Tang servers for HA unlock
  without requiring all servers to be available simultaneously

## Requirements

- Debian 12 (Bookworm) or 13 (Trixie)
- Ansible 2.14+
- `ansible.posix` collection (`ansible-galaxy collection install ansible.posix`)
- Controller must have `ansible-vault` in `PATH` (bundled with ansible-core)
- Controller must have `/usr/share/dict/words` for passphrase generation, or
  set `clevis_vault_password_file` to a pre-existing vault-encrypted key file
- One or more Tang servers reachable from the target host at provisioning time
- Target host must have `gather_facts: true` (the role uses `ansible_devices`)

## Role variables

### Required

| Variable | Description |
|---|---|
| `tang_servers` | List of Tang server objects. Each entry must have a `url` key. See [Tang servers](#tang-servers). |

### Optional

| Variable | Default | Description |
|---|---|---|
| `clevis_encryption_enabled` | `true` | Set `false` to skip the entire role. Useful when the role is included unconditionally in a playbook but encryption is not needed on every host. |
| `clevis_vault_password_file` | `"~/.ansible_vault_pass"` | Path to the Ansible Vault password file on the controller, used to encrypt the per-host recovery key. |
| `clevis_keep_temp_key` | `false` | Retain `/tmp/ansible_luks_key` on the remote host after provisioning. Leave `false` in production. |
| `clevis_luks_open_options` | `"--allow-discards"` | Options passed to `cryptsetup open` when `clevis-unlock-data` opens each mapper at boot (`clevis luks unlock -o`). The durable place to enable discard, since the `noauto` data disks ignore the crypttab `discard` option. Append `--perf-no_read_workqueue --perf-no_write_workqueue` to make dm-crypt perf flags durable too; set `""` for none. |
| `clevis_unlock_retries` | `3` | Boot-time `clevis-unlock-data`: number of Tang unlock attempts per disk before giving up (fail-degraded) and moving on. |
| `clevis_unlock_retry_delay` | `5` | Seconds to wait between boot-time unlock attempts. |
| `clevis_unlock_attempt_timeout` | `20` | Per-attempt timeout (seconds) wrapped around each boot-time `clevis luks unlock`. |
| `clevis_dns_servers` | `[]` | Nameservers to prepend to `/etc/resolv.conf` during provisioning. Useful when Tang is reachable only via an internal DNS zone not in the host's default resolver. Empty = no change. |
| `clevis_curl_ip_version` | `auto` | IP family clevis's curl uses for Tang: `auto` (probe and pin the working family), `ipv4`, `ipv6`, or `dual` (no pin). See [Tang IP family](#tang-ip-family-ipv4--ipv6). |
| `clevis_curl_home` | `/etc/clevis/curl` | Directory used as `CURL_HOME` for clevis's curl calls; the role writes `<clevis_curl_home>/.curlrc` here. |
| `clevis_curl_probe_connect_timeout` | `5` | Per-server connect timeout (seconds) for `auto` reachability probing. |
| `clevis_curl_probe_max_time` | `15` | Per-server total timeout (seconds) for `auto` reachability probing. |
| `clevis_ipv4_only` | `false` | **Deprecated** — superseded by `clevis_curl_ip_version`. When `true` (and `clevis_curl_ip_version` is left at `auto`) it maps to `clevis_curl_ip_version: ipv4`, with a deprecation warning. |
| `clevis_recovery_key_path` | `{{ inventory_dir }}/host_vars/{{ inventory_hostname }}/secrets/luks_recovery_key.txt` | Path on the Ansible controller where the vault-encrypted recovery key is stored. Override when using a non-standard inventory layout or a separate secrets directory. |

> **Storage variables live on the consumer role.** Pool name, topology,
> package install, and "destroy existing" are configured on
> `encrypted_storage_pool` / `proxmox_encrypted_storage`, not here. The pool
> variables this role used to carry were removed in 2.0 — see
> [Upgrade notes → 2.0](#20--zfs-removed) if you have any of them in inventory.

### Tang servers

`tang_servers` is a list of objects with a `url` key:

```yaml
tang_servers:
  - url: "https://tang-prod.example.com"
  - url: "https://tang-backup.example.com"
```

An additional `route` key is accepted and ignored — it is available for use by
other roles or playbooks that need to distinguish internal from external
servers.

The role assembles a Clevis SSS (Shamir Secret Sharing) configuration with
`t: 1` — any single Tang server can unlock the disk independently.  This means
a single Tang server outage does not prevent boot.  To require more than one
server to be available simultaneously, you can override `tang_sss_cfg` directly
with a custom JSON string.

### Tang IP family (IPv4 / IPv6)

Clevis fetches the Tang advertisement (at bind) and POSTs the recovery request
(at every unlock) by shelling out to `curl`.  On a dual-stack host where Tang is
reachable over only one family, that call can pick the wrong one and fail.

**Why curl's own dual-stack logic isn't enough.** curl's Happy Eyeballs races
IPv4 and IPv6 at the **TCP layer** and commits to whichever completes the
handshake first; it never reconsiders based on the HTTP status.  If a Tang load
balancer answers the IPv6 handshake but returns `403` to a non-whitelisted IPv6
client, curl "wins" on IPv6 and then fails — even though IPv4 would have returned
the advertisement.  The family that yields a **valid adv** must be selected
explicitly.

**How the role does it.** Because `clevis-encrypt-tang` / `clevis-decrypt-tang`
call `curl` *without* `-q`, curl reads a config file.  The role writes a
clevis-scoped `curlrc` to `clevis_curl_home` (`/etc/clevis/curl/.curlrc`) and
points curl at it with `CURL_HOME` wherever it drives clevis — at bind, at
rotate/regen, and in the boot-time `clevis-unlock-data` script.  The pin is
therefore confined to clevis and does **not** touch host-global resolution.

`clevis_curl_ip_version` selects the family:

| Value | Behaviour |
|---|---|
| `auto` (default) | At provision time, probe each Tang `/adv` over IPv4 and IPv6 (`curl -fg --ipvN`, so a `403` counts as a failure) and bake the family that returns a valid adv. Chooses `dual` only when every server answers on **both**. If nothing is reachable it warns and **preserves any existing pin** (falling back to `dual` only when no curlrc exists yet), so a transient Tang outage during a routine re-run can't downgrade a known-good pin; the real failure then surfaces at the actual bind/unlock step. |
| `ipv4` | Write `--ipv4` to the curlrc. |
| `ipv6` | Write `--ipv6`. |
| `dual` | Write no family flag; rely on curl's own dual-stack / Happy-Eyeballs logic. Appropriate only when Tang genuinely returns a valid adv on both families. |

This replaces the previous host-global approach (`/etc/gai.conf` IPv4 precedence
+ `net.ipv6.conf.all.disable_ipv6=1` + a `clevis-network-ready.service` gate),
which disabled IPv6 for the entire host and was silently ignored when the host
used `systemd-resolved` (which does its own RFC 6724 sort and never consults
`gai.conf`).  Those artifacts are removed on every run — see
[Upgrade notes](#automatic-legacy-cleanup).

## Tags

| Tag | What it runs |
|---|---|
| `prestage` | Package install + Tang network preconditions (DNS, IP-family probe + curlrc). Idempotent and safe on un-encrypted nodes. Use this to do most of the setup ahead of the destructive LUKS-format step, shortening the actual maintenance window. |
| `provision` | The provisioning block only (LUKS format, Clevis bind). Skipped automatically if the recovery key already exists on the controller. |
| `systemd` | The boot ordering block only (crypttab, systemd drop-ins, the `clevis-luks-unlocked.target` seam). Safe to run against already-encrypted live nodes. Does NOT re-run prestage — combine with `--tags prestage,systemd` if you also want the network gate re-validated. |

### Pre-staging on fresh nodes

```bash
# Apply only the safe-on-un-encrypted-nodes work
ansible-playbook your-playbook.yml --tags prestage
```

This installs packages and applies network preconditions without touching any disks. Later, run the playbook without tags (or with `--tags provision`) to do the actual LUKS format and Clevis bind during a tighter maintenance window.

## Idempotency

- **Provisioning** is guarded by the presence of the vault-encrypted recovery
  key on the controller (`host_vars/<hostname>/secrets/luks_recovery_key.txt`).
  If the file exists, the entire provisioning block is skipped.  Delete the
  file and re-run only if you intend to wipe and re-encrypt the disks.
- **Boot ordering** (`--tags systemd`) is fully idempotent and safe to re-run
  on live systems at any time.

## Recovery key

At the end of a successful first run, a vault-encrypted recovery key is written
to:

```
<inventory_dir>/host_vars/<hostname>/secrets/luks_recovery_key.txt
```

This file should be committed to your inventory repository (it is
vault-encrypted).  It is the **only** recovery path if all Tang servers become
permanently unavailable.  Guard it accordingly.

To decrypt a disk manually using the recovery key:

```bash
ansible-vault decrypt \
  inventories/<customer>/<env>/host_vars/<hostname>/secrets/luks_recovery_key.txt \
  --vault-password-file ~/.ansible_vault_pass \
  --output -
# Use the printed passphrase with:
cryptsetup luksOpen /dev/<device> crypt-<device>
```

## Example playbooks

### NBDE only — unlock the disks, no storage assembly

```yaml
- name: "Encrypt data disks (NBDE only)"
  hosts: my_servers
  become: true
  gather_facts: true

  vars:
    tang_servers:
      - url: "https://tang.example.com"

  tasks:
    - name: "Apply disk encryption"
      ansible.builtin.include_role:
        name: clevis-encryption
      vars:
        clevis_encryption_enabled: true
        clevis_curl_ip_version: auto   # probe IPv4/IPv6 and pin the working family
        clevis_dns_servers:
          - "192.168.1.1"
```

After this run the `/dev/mapper/crypt-*` mappers are opened at boot and
`clevis-luks-unlocked.target` is reached — but nothing is assembled on top of
them. Add a consumer role (below) to get a usable pool.

### Compose with a storage consumer — clevis NBDE + btrfs pool

```yaml
- name: "Encrypt data disks and assemble a btrfs pool on top"
  hosts: my_servers
  become: true
  gather_facts: true

  vars:
    tang_servers:
      - url: "https://tang-prod.example.com"
      - url: "https://tang-backup.example.com"

  roles:
    # 1. NBDE: LUKS2 + Clevis/Tang; opens crypt-* and publishes the seam.
    - role: clevis-encryption

    # 2. Consumer: assembles a btrfs raid1 across the mappers, ordered after
    #    clevis-luks-unlocked.target, and emits encrypted-storage-ready.target.
    #    (github.com/KvalitetsIT/encrypted-storage-pool)
    - role: encrypted_storage_pool
      vars:
        encrypted_storage_pool_backend: btrfs
        encrypted_storage_pool_name: data
        encrypted_storage_pool_topology: mirror
        encrypted_storage_pool_devices: [vdb, vdc]
```

### Compose with a storage consumer — clevis NBDE + ZFS on Proxmox

```yaml
- name: "Encrypt data disks and create a ZFS pool (Proxmox VE)"
  hosts: new_proxmox_hosts
  become: true
  gather_facts: true

  vars:
    tang_servers:
      - url: "https://tang-prod.example.com"

  roles:
    - role: clevis-encryption

    # ZFS-on-LUKS consumer from the proxmox-install repo. Consumes the same seam
    # and emits encrypted-storage-ready.target.
    - role: proxmox_encrypted_storage
      vars:
        proxmox_encrypted_storage_pool_name: data
        proxmox_encrypted_storage_topology: mirror
```

Registering the resulting ZFS pool as a Proxmox VE *storage backend*
(`community.proxmox.proxmox_storage`) is a further concern owned by the
`proxmox_encrypted_storage` role / your Proxmox playbook, not by this role.

### Re-apply boot ordering to existing nodes

```bash
ansible-playbook your-playbook.yml --tags systemd
```

This is safe to run on live systems.  It rewrites crypttab entries and systemd
drop-ins (including the `clevis-luks-unlocked.target` seam) without touching the
LUKS key slots.

## How boot unlock works

The data disks carry `noauto` in `/etc/crypttab`, so `systemd-cryptsetup` does
**not** open them in early boot.  Instead the role installs a self-contained,
network-ordered unlock that runs in the booted system and publishes a public
sync point.  The unlock is deliberately **kept out of** the stock early
`zfs-import`/`local-fs` graph: ordering an early filesystem/import unit after a
network-dependent unlock creates a systemd ordering cycle (`local-fs →
zfs-mount → zfs-import → [net dep] → network-online → networking → local-fs`),
which systemd breaks by *deleting* a job — in practice the unlock job, so nothing
decrypts.  Keeping the unlock chain out of that graph is what lets a downstream
consumer order **after** the unlock seam without re-introducing the cycle:

```
network-online.target
        │
        ▼
clevis-unlock-data.service          retries Tang per disk; distinguishes a
        │                            MISSING DEVICE from a DECRYPT FAILURE;
        │                            opens each mapper with --allow-discards;
        │                            ALWAYS exits 0.  curl reads the role curlrc
        │                            via CURL_HOME, so the pinned IP family is used.
        ▼
clevis-luks-unlocked.target         ◄── THE SEAM. This role ends here.
                                    PUBLIC sync point — "NBDE unlock has run"
                                    (Requires/After clevis-unlock-data.service;
                                    WantedBy=multi-user.target).  Reached even on
                                    a partial (fail-degraded) unlock.
        ┊
        ┊  (a downstream storage consumer role orders After=/Wants= the seam)
        ▼
<consumer> assemble → check → encrypted-storage-ready.target
                                    Owned by encrypted_storage_pool (btrfs/LVM)
                                    or proxmox_encrypted_storage (ZFS):
                                    import/assemble the pool, health-check it, and
                                    emit its own barrier for higher-level services
                                    (e.g. Proxmox pvestatd) to gate on.
```

**Consumer contract.** `clevis-luks-unlocked.target` is the stable, public name a
downstream storage layer orders after (`After=` / `Wants=`) — it means "the NBDE
unlock step has run". Consumers never depend on the internal
`clevis-unlock-data.service` name. For "storage is actually assembled and healthy"
(a stronger property) gate on the consumer's own barrier
(`encrypted-storage-ready.target`), not this one.

The unlock is **fail-degraded**: a disk that is missing, or whose Tang is
unreachable after `clevis_unlock_retries` attempts, is logged and skipped rather
than hanging the boot.  Combined with the `nofail` crypttab flag, the host always
boots to a recoverable state — if Tang is down the mappers simply do not open,
the consumer's health check fails, and its `encrypted-storage-ready.target` is
not reached, so services gated on it stay stopped until you intervene.

## Compatibility

| Distribution | Initramfs | Tested |
|---|---|---|
| Debian 12 (Bookworm) | initramfs-tools | Yes |
| Debian 13 (Trixie) | initramfs-tools | Yes |
| Ubuntu 22.04+ | initramfs-tools | Likely works, not tested |
| RHEL / Fedora | dracut | **Not supported** — use `linux-system-roles/nbde_client` |

## Upgrade notes

### 2.0 — ZFS removed

As of 2.0 this role is **NBDE-only**. Everything to do with creating, importing,
or ordering a storage pool was removed and moved to a downstream consumer role
(see [Storage](#storage-separate-consumer-role)). The following variables **no
longer exist** in this role:

| Removed variable | Where it went |
|---|---|
| `clevis_pool_name` | `*_pool_name` on the consumer role |
| `clevis_zfs_pool_topology` | `*_topology` on the consumer role |
| `clevis_ensure_pool` | `*_ensure` / `*_ensure_pool` on the consumer role |
| `clevis_install_zfs_packages` | `*_install_packages` on the consumer role |
| `clevis_destroy_existing` | `*_destroy_existing` on the consumer role |
| `clevis_deploy_storage_units` | consumer role always owns its own boot-ordering units |

**What to do:**

- **Proxmox / ZFS users:** add the `proxmox_encrypted_storage` role (in the
  `proxmox-install` repo) after this one, and move your pool name / topology /
  package / destroy settings onto its `proxmox_encrypted_storage_*` variables.
  For continuity it defaults `pool_name`/`topology` from any still-present
  `clevis_pool_name`/`clevis_zfs_pool_topology`, but set the new names at your
  convenience.
- **Generic btrfs/LVM users:** add the `encrypted_storage_pool` role
  (<https://github.com/KvalitetsIT/encrypted-storage-pool>) after this one.
- The `encrypted-storage-import`/`-pool-check` units and
  `encrypted-storage-ready.target` are now created by the consumer role, not this
  one. This role deploys only the unlock half + the `clevis-luks-unlocked.target`
  seam.

### Automatic legacy cleanup

The role design has changed several times; older versions deployed artifacts the
current design no longer uses. `tasks/cleanup-legacy.yml` removes them on **every**
run (it runs first, under `tags: always`, so it applies under any tag filter and
on a host last touched by any old version). No manual cleanup is required.

Cleanup never blind-deletes a file it cannot prove it wrote — a reusable role must
not clobber a generically-named file an operator or another role legitimately
owns. Removals fall into three safety tiers:

1. **Provably ours by name** — units/symlinks whose name is unique to this role.
   Removed when present.
   - `clevis-network-ready.service` (the old IPv4-preference boot gate) and its
     `clevis-luks-askpass.service.wants/` symlink.
2. **Marker-scoped** — an Ansible block delimited by this role's marker inside a
   shared file. Only the marked block is removed.
   - the `ipv4-only` precedence block in `/etc/gai.conf`.
3. **Content-guarded** — a generic name and/or a foreign service's drop-in
   directory. Removed **only** when the file's content carries this role's
   ownership header *or* a distinctive signature it always wrote; a same-named
   foreign file with neither is preserved (and logged).
   - `networking.service.d/10-override.conf` (an early bring-up drop-in validated
     to **break boot**; guarded on its distinctive
     `… ifupdown2-pre.service sysinit.target` line).
   - `clevis-luks-askpass.service.d/ipv4-only.conf` (gated askpass on the old
     network-ready unit).
   - `/etc/sysctl.d/99-ipv6_disable.conf` (host-global IPv6 disable; also resets
     `disable_ipv6` to `0` on the live kernel — a reboot fully restores IPv6
     addressing on interfaces that had it stripped).

> **The old ZFS-import ordering drop-ins moved with ZFS.** Earlier versions of
> this role wrote `zfs-import-{cache,scan}.service.d/*.conf` and
> `zfs-import@.service.d/after-luks-unlock.conf` drop-ins (the source of an early
> boot ordering cycle). Now that ZFS is out of this role, cleanup of those
> drop-ins is the storage consumer's concern — `proxmox_encrypted_storage`
> content-guards and removes them. This role no longer touches them.

The host-global IPv4-only gate (tier 2 + the sysctl + `clevis-network-ready`) is
superseded by the clevis-scoped `curlrc` — see
[Tang IP family](#tang-ip-family-ipv4--ipv6). If you previously set
`clevis_ipv4_only: true` in inventory, the role still honours it (mapped to
`clevis_curl_ip_version: ipv4` with a deprecation warning) — replace it with
`clevis_curl_ip_version` at your convenience.

> Earlier releases left the `networking.service` drop-in for the operator to
> remove manually (a reusable role shouldn't delete files it can't prove it owns).
> That concern is now resolved *within* the role by the content guard above, so
> the manual runbook step is no longer needed.

## Testing

Testing is layered to match the stack. **Tier 0** is cheap static + device-free
validation that runs on every push; the VM tiers boot progressively more of the
stack and run on a KVM-capable runner (or locally):

| Tier | Layer under test | Where | Needs |
|---|---|---|---|
| 0 | **Repository validation** — `yamllint`, `ansible-lint`, `ansible-core` version syntax-check — **plus** the device-free clevis↔Tang **crypto + IP-family** check | `.yamllint`, `.ansible-lint`, `molecule/network` (`ci.yml`) | any runner (+ Docker for the crypto scenario) |
| 1 | **LUKS keyslot** — `clevis luks bind`/`unlock -o`, crypttab, durable `allow_discards` | `molecule/default` (`vm-tests.yml`) | **Rootless** libvirt/KVM VM (user in `libvirt` group) |
| 2 | **Real boot ordering** — boot-time unlock from an external Tang, the seam, and a downstream consumer assembling a pool across it (reboot-durable) | `molecule/vm` (`vm-tests.yml`) | **Rootless** libvirt/KVM (two VMs: encrypted host + external Tang) |

The `network` scenario (Tier 0) is a
[Molecule](https://ansible.readthedocs.io/projects/molecule/) scenario on the
**Docker** driver (device-free, rootless — a privileged Debian 13 container with
`systemd` as PID 1). Tiers 1–2 (`default`, `vm`) are Molecule scenarios on the
**Vagrant + libvirt/KVM** driver, running real Debian 13 (`debian/trixie64`) VMs.
The split mirrors how clevis works: `clevis encrypt`/`decrypt` round-trip with
Tang over `curl` (the network layer — no disk, no privilege), while binding a key
to a LUKS keyslot needs a real block device. The `network` scenario runs the
**same role** device-free (`clevis_raw_disks: []`), so the network handling — the
subject of `clevis_curl_ip_version` — is testable anywhere. Boot ordering can only
be proven by a real boot + reboot, so it lives in the `vm` tier: two VMs on
Vagrant's NAT network — the encrypted host (`vdb`+`vdc` → LUKS2 → mappers) and a
separate **external** Tang server it unlocks from at boot. Tier 2 pairs this role
(NBDE only) with the **`encrypted_storage_pool`** consumer (a **btrfs** raid1 —
mainline, **no ZFS/DKMS**) to prove the seam works end-to-end across a reboot.
Tang is its own VM because guest↔guest traffic is pure L2 bridging, whereas
guest→host services are blocked by the host firewall.

A **raw-QEMU fallback** of Tier 2 — no libvirt, no Vagrant, no root (user-mode
QEMU networking + a Tang container) — lives in [`manual_test/`](manual_test/) for
portability off GitHub or onto hosts without libvirt. It is run by hand, not in CI.

> **Why `default` is a VM, not a container.** Binding a key to a LUKS keyslot
> needs a real block device. The old Docker version faked one with a
> loopback + `mknod` hack that required a *rootful* runtime (rootless user
> namespaces forbid block-device `mknod`). The Vagrant + libvirt/KVM VM gives a
> genuine virtio disk instead, and runs **rootless** wherever the invoking user
> has system-libvirt access via the `libvirt` group (polkit) — no `sudo`. Vagrant
> auto-creates and tears down its own `vagrant-libvirt` NAT network per run, so
> there is no persistent host network to manage.

### Prerequisites

Tier-0 validation — lint + the device-free crypto scenario:

```bash
pip install ansible-lint yamllint molecule 'molecule-plugins[docker]' ansible
ansible-galaxy collection install community.docker ansible.posix
```

`yamllint .` and `ansible-lint` need no runtime. The `network` scenario needs a
container runtime (Docker, or Podman exposing the Docker-compatible socket via
`DOCKER_HOST`).

Tiers 1–2 (`default`, `vm`) — Vagrant + libvirt/KVM driver:

```bash
pip install molecule 'molecule-plugins[vagrant]' python-vagrant ansible
ansible-galaxy collection install ansible.posix community.general
# Host packages: libvirt + KVM + Vagrant + the vagrant-libvirt plugin, e.g.
#   Fedora: sudo dnf install vagrant vagrant-libvirt libvirt qemu-kvm
#   Debian: sudo apt install vagrant vagrant-libvirt libvirt-daemon-system qemu-kvm
# Add yourself to the libvirt group (log out/in afterwards) so no sudo is needed:
sudo usermod -aG libvirt "$USER"
```

The Tier-2 (`vm`) scenario also pulls the `encrypted_storage_pool` consumer role
into its scenario `roles/` directory (via `molecule/vm/requirements.yml`) so it
can prove the seam against a real downstream consumer.

Two environment variables are required for the VM tiers (see the note below on why):

```bash
# molecule-core 25.12 no longer auto-adds the vagrant driver's modules dir to
# ANSIBLE_LIBRARY, so point at it explicitly (portable across install locations):
export ANSIBLE_LIBRARY="$(python3 -c 'import molecule_plugins.vagrant, os; print(os.path.join(os.path.dirname(molecule_plugins.vagrant.__file__), "modules"))')"
# Use system libvirt (vagrant-libvirt defaults to a session URI that cannot
# provide the DHCP lease vagrant needs to discover the guest IP):
export LIBVIRT_DEFAULT_URI=qemu:///system
```

> The scenario forces `qemu_use_session: false` (system libvirt) and disables
> `vagrant-cachier` (`cachier: disabled`) in `molecule.yml`. Session mode has no
> usermode/slirp support — vagrant-libvirt finds the guest IP only via a libvirt
> DHCP lease — and both the `debian/trixie64` box and vagrant-cachier default to
> **NFS** synced folders, whose `/etc/exports` edit needs root; disabling them
> keeps the run rootless.

### Running the tests

```bash
cd ansible/roles/clevis-encryption

# Tier-0 — repository validation (no runtime) + device-free crypto (Docker)
yamllint .
ansible-lint
molecule test -s network

# Tiers 1-2 — libvirt/KVM VMs (rootless via the libvirt group); both need:
export ANSIBLE_LIBRARY="$(python3 -c 'import molecule_plugins.vagrant, os; print(os.path.join(os.path.dirname(molecule_plugins.vagrant.__file__), "modules"))')"
export LIBVIRT_DEFAULT_URI=qemu:///system

# Tier-1 — real virtio-disk LUKS keyslot layer (fast, no reboot)
molecule test              # the 'default' scenario — no sudo

# Tier-2 — real boot ordering: 2 VMs, clevis NBDE + btrfs consumer, provision +
#          REBOOT + verify (no ZFS, no DKMS)
molecule test -s vm
```

`molecule test` runs the full lifecycle (`create → prepare → converge →
idempotence → verify → destroy`); the `vm` scenario swaps `idempotence` for a
`side_effect` step that reboots the guest before `verify`.  To iterate, use
`molecule converge -s <scenario>` then `molecule verify -s <scenario>`.

### Continuous integration

Two GitHub Actions workflows:

- **`ci.yml`** (every push / PR): the Tier-0 gate — `yamllint`, `ansible-lint`,
  an `ansible-core` version matrix syntax-check, and the device-free `network`
  scenario (Docker). Cheap, no VMs.
- **`vm-tests.yml`** (PRs touching role/test code, or manual dispatch): Tiers 1–2
  (`default`, `vm`) on libvirt/KVM. It bootstraps libvirt + Vagrant +
  `vagrant-libvirt` on the runner and needs nested KVM (`/dev/kvm`).

### What is tested

**`network`** (device-free):

- the role's auto-probe resolves the family and writes
  `/etc/clevis/curl/.curlrc` pinning `--ipv4` (the test Tang is IPv4-only)
- `clevis encrypt | clevis decrypt` round-trips through that curlrc, and forcing
  `--ipv6` **fails** — proving the pin is actually read and is decisive
- the device-independent boot-ordering artifacts are deployed
  (the `clevis-luks-askpass` network-online gate and `clevis-unlock-data.service`)

**`default`** (real virtio-disk LUKS):

- `/etc/crypttab` has the expected `crypt-vdb` entry with `_netdev`,
  `x-systemd.after=network-online.target`, `discard`, and `nofail`
- `/dev/mapper/crypt-vdb` is open and `discards` is active in the dm-crypt table
  (the live-apply path)
- the auto-probe pinned `--ipv4` against the IPv4-only test Tang
- the retired `gai.conf` block, `clevis-network-ready.service`, and
  `clevis-luks-askpass.service.d/ipv4-only.conf` are **absent**, while a foreign
  same-named drop-in is **preserved** (content-guard test)
- a vendored harness proves `clevis luks unlock -o "--allow-discards"` and the
  live-refresh path land `allow_discards`

**`vm`** (real boot ordering, post-reboot — clevis NBDE + btrfs consumer):

- both `crypt-vdb` / `crypt-vdc` mappers are open after boot with `allow_discards`
  still set (durable across the reboot, not just the live-apply)
- `clevis-luks-unlocked.target` is active and systemd logged "Reached target"
  this boot — the public NBDE seam
- the seam ordering held across roles at boot:
  `clevis-unlock-data.service` ≤ `clevis-luks-unlocked.target` ≤
  `encrypted-storage-assemble.service` (the consumer ran after the seam)
- `clevis-unlock-data` logged a successful unlock — the disks were opened at boot
  from the **external** Tang (the `clevis-tang` VM) over the network
- the downstream `encrypted_storage_pool` (btrfs) assembled + mounted the pool at
  `/srv/data`, real I/O round-trips, and `encrypted-storage-ready.target` is
  active (the consumer's barrier)

In the `network` and `default` scenarios the provisioning block (LUKS format on
real disks, Clevis bind) is **skipped** because `prepare.yml` pre-creates the
recovery-key file — the same mechanism that prevents re-provisioning on live
nodes.  The `vm` scenario is the opposite: `prepare.yml` *removes* the
recovery-key gate so the role provisions for real — it formats the disks and
binds Clevis, then the btrfs consumer assembles the pool, and after a reboot the
test verifies both the boot-time unlock and the pool come up across the seam.

### How disk selection works

`tasks/main.yml`'s disk-discovery task carries `when: clevis_raw_disks is not
defined`.  The `default` scenario pre-sets `clevis_raw_disks: [vdb]` and the `vm`
scenario `[vdb, vdc]` — the extra virtio disks the libvirt provider attaches to
the VM; the `network` scenario sets `clevis_raw_disks: []` so the per-disk loops
are empty and nothing touches a block device.  Either way the role never inspects
`ansible_devices`, which is unreliable in test substrates.

## Troubleshooting

### `cryptsetup refresh --token-only` fails silently (cryptsetup 2.7+)

**Symptom:** The live discard passthrough task exits with rc=1 in under 10 ms, no
stderr output, and the mapper's `discards` flag is not set.

**Cause:** cryptsetup 2.7+ delegates LUKS2 token handling to shared libraries
(`/usr/lib/x86_64-linux-gnu/cryptsetup/libcryptsetup-token-<name>.so`).  The
Clevis token handler (`libcryptsetup-token-clevis.so`) is not packaged for
Debian as of Bookworm/Trixie.  Without it cryptsetup logs:

```
Trying to load …/libcryptsetup-token-clevis.so: cannot open shared object file
No usable token is available.
```

**Fix:** This role uses `dmsetup suspend/reload/resume` to rewrite the dm-crypt
kernel device table directly, which does not require any token handler or Tang
connectivity.  The existing kernel keyring reference is reused as-is.

If you see this error outside of Ansible, confirm the installed cryptsetup
version with `cryptsetup --version` and check whether
`libcryptsetup-token-clevis.so` exists under
`/usr/lib/x86_64-linux-gnu/cryptsetup/`.

---

### Tang unlock fails on a dual-stack host (wrong IP family)

**Symptom:** Clevis fails to fetch the advertisement or unlock at boot on a
dual-stack host, even though `curl --ipv4 <tang-url>/adv` (or `--ipv6`) succeeds
by hand.

**Cause:** curl's Happy Eyeballs races IPv4 and IPv6 at the **TCP layer** and
commits to whichever completes the handshake first; it never reconsiders based
on the HTTP status.  If a Tang load balancer answers the IPv6 handshake but
returns `403` to a non-whitelisted IPv6 client (or the IPv6 path is a blackhole),
curl commits to IPv6 and the request fails — even though IPv4 would have served
the advertisement.

**Fix:** Pin the family clevis uses. Leave `clevis_curl_ip_version: auto` to let
the role probe each Tang `/adv` over both families at provision time and bake the
one that returns a valid adv, or set it explicitly to `ipv4` / `ipv6`. The role
writes the choice to `/etc/clevis/curl/.curlrc` and points clevis's curl at it
via `CURL_HOME` — at bind, at rotate/regen, and in the boot-time
`clevis-unlock-data` script.

Inspect the resulting pin on the host:

```bash
cat /etc/clevis/curl/.curlrc
# verify clevis actually reads it:
CURL_HOME=/etc/clevis/curl curl -v https://<tang-url>/adv >/dev/null
```

**Why not `gai.conf` / `disable_ipv6`:** earlier versions raised IPv4 precedence
in `/etc/gai.conf` and disabled IPv6 host-wide. That disabled IPv6 for everything
on the box and — crucially — was silently ignored under `systemd-resolved`
(`/etc/resolv.conf` → `127.0.0.53`), which does its own RFC 6724 sort and never
consults `gai.conf`. The curlrc pin is scoped to clevis and is immune to both
problems. See [Upgrade notes](#automatic-legacy-cleanup)
for cleanup of the old artifacts (handled automatically on the next run).

---

### `--tags systemd` fails with "clevis_raw_disks is undefined"

**Symptom:** Running `ansible-playbook … --tags systemd` against an already-encrypted
node fails immediately with an undefined variable error.

**Cause (historical):** The disk discovery `set_fact` task was not tagged with
`tags: always`, so it was skipped when `--tags systemd` was passed, leaving
`clevis_raw_disks` undefined for the boot-ordering block.

**Fix:** The task now carries `tags: always` so it runs regardless of which
tag filter is active.  If you see this error, ensure you are running a recent
version of this role.

---

### Boot unlock fails (Tang unreachable)

If Tang is unreachable at boot time:

- `clevis-unlock-data.service` retries each disk a bounded number of times
  (`clevis_unlock_retries` × `clevis_unlock_attempt_timeout`), logs the failure,
  and exits 0 — the boot is never blocked on it.
- `clevis-luks-unlocked.target` is still reached (the seam means "the unlock step
  ran", not "every disk opened"), but the mappers of the failed disks are not
  open.  The downstream consumer's assemble/check chain then fails its viability
  gate, so its `encrypted-storage-ready.target` is **not** reached and services
  that gate on it (e.g. Proxmox `pvestatd`) stay stopped rather than running
  against a missing pool.
- The host still boots to `multi-user.target` and remains accessible for operator
  intervention.
- To unlock manually after fixing Tang connectivity:

```bash
# Re-run the role's fail-degraded unlock, then let the consumer re-assemble:
systemctl start clevis-unlock-data.service
systemctl start clevis-luks-unlocked.target   # (or the consumer's assemble unit)

# …or open a single disk by hand (pool import/assembly is the consumer's concern):
clevis luks unlock -d /dev/<device> -n crypt-<device> -o "--allow-discards"
```

Inspect what happened with `journalctl -u clevis-unlock-data
-u clevis-luks-unlocked.target`.

## License

MIT
