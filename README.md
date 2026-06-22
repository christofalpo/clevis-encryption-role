# clevis-encryption

An Ansible role that provisions LUKS2 full-disk encryption on Debian hosts,
binds the unlock key to one or more Tang servers using Clevis Shamir Secret
Sharing, and configures the correct systemd boot ordering so encrypted devices
are unlocked before any dependent service (ZFS, NFS, databases) starts.

Optionally creates a ZFS pool on top of the encrypted devices.

The role is **storage-vendor-agnostic** — it ends at "imported ZFS pool".
If you want the pool registered as a Proxmox VE storage backend, do that on
the consuming side (e.g., `community.proxmox.proxmox_storage` with
`state: present`).  Earlier versions of this role embedded that call;
it was removed in 2026-05 so the role stays reusable for any LUKS+ZFS
deployment, not just Proxmox.

## Why this role exists

The two most widely-used public roles for Clevis/Tang automation
(`linux-system-roles/nbde_client`, `stackhpc/ansible-role-luks`) both target
RHEL/Fedora and use **dracut** for initramfs management.  Proxmox VE runs on
**Debian** and uses **initramfs-tools**.  The boot integration is different
enough that neither role works without significant modification.

This role was written specifically for the Debian/initramfs-tools path and
addresses several real-world problems that are not covered by existing public
automation:

- The correct `crypttab` flag combination for network-unlocked devices
  (`_netdev,x-systemd.after=network-online.target`) and why `noauto` breaks
  things
- Ordering `zfs-import-cache.service` after `remote-cryptsetup.target` so ZFS
  never races the unlock
- A network-ready gate for dual-stack hosts where Tang servers are
  IPv4-whitelisted only (`clevis_ipv4_only`)
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
| `clevis_pool_name` | `"data"` | Name of the ZFS pool created on top of the encrypted devices. |
| `clevis_zfs_pool_topology` | `"mirror"` | Vdev layout. See [ZFS pool topology](#zfs-pool-topology). |
| `clevis_vault_password_file` | `"~/.ansible_vault_pass"` | Path to the Ansible Vault password file on the controller, used to encrypt the per-host recovery key. |
| `clevis_keep_temp_key` | `false` | Retain `/tmp/ansible_luks_key` on the remote host after provisioning. Leave `false` in production. |
| `clevis_destroy_existing` | `false` | Destroy an existing ZFS pool before (re-)provisioning. **Destructive.** |
| `clevis_dns_servers` | `[]` | Nameservers to prepend to `/etc/resolv.conf` during provisioning. Useful when Tang is reachable only via an internal DNS zone not in the host's default resolver. Empty = no change. |
| `clevis_ipv4_only` | `false` | Deploy a systemd gate that verifies IPv6 is disabled before allowing Tang unlock attempts. See [IPv4-only mode](#ipv4-only-mode). |
| `clevis_recovery_key_path` | `{{ inventory_dir }}/host_vars/{{ inventory_hostname }}/secrets/luks_recovery_key.txt` | Path on the Ansible controller where the vault-encrypted recovery key is stored. Override when using a non-standard inventory layout or a separate secrets directory. |

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

### ZFS pool topology

`clevis_zfs_pool_topology` controls how the auto-discovered data disks are
arranged into ZFS vdevs:

| Value | Behaviour | Minimum disks |
|---|---|---|
| `mirror` | Pairs of disks become mirror vdevs. 6 disks → 3 mirrors. Requires an even number of disks. | 2 |
| `raidz` | All disks in a single raidz vdev (1 parity). | 3 |
| `raidz2` | All disks in a single raidz2 vdev (2 parity). | 4 |
| `raidz3` | All disks in a single raidz3 vdev (3 parity). | 5 |
| `stripe` | All disks striped with no redundancy. Data loss on any single disk failure. | 1 |

The role auto-discovers data disks by grouping all non-removable, non-virtual
block devices by size and selecting the largest size group.  This reliably
selects data disks over the OS/boot disk on typical server hardware.

### IPv4-only mode

On dual-stack hosts (e.g. Hetzner dedicated servers), `getaddrinfo()` returns
AAAA records before A records.  If `net.ipv6.conf.all.disable_ipv6=1` is set
in `/etc/sysctl.d/` but `systemd-sysctl.service` has not completed when
`clevis-luks-askpass.service` starts, Clevis may attempt Tang connections over
IPv6 — which fails silently if the Tang server only whitelists IPv4.

Setting `clevis_ipv4_only: true` deploys `clevis-network-ready.service`, a
oneshot systemd unit that:

1. Runs `After=systemd-sysctl.service network-online.target`
2. Verifies `sysctl net.ipv6.conf.all.disable_ipv6` is `1` (live kernel value,
   not config file)
3. Is ordered `Before=clevis-luks-askpass.service`

If the check fails at boot, Clevis is blocked and the operator sees a clear
failure rather than a silent unlock loop.

**Prerequisites for `clevis_ipv4_only: true`:**
- `net.ipv6.conf.all.disable_ipv6=1` must be in `/etc/sysctl.d/` (managed
  separately, e.g. by your network configuration role)
- Tang servers must be reachable over IPv4

## Tags

| Tag | What it runs |
|---|---|
| `prestage` | Package install + Tang network preconditions (DNS, IPv6 sysctl, gai.conf gate). Idempotent and safe on un-encrypted nodes. Use this to do most of the setup ahead of the destructive LUKS-format step, shortening the actual maintenance window. |
| `provision` | The provisioning block only (LUKS format, Clevis bind, ZFS pool creation). Skipped automatically if the recovery key already exists on the controller. |
| `systemd` | The boot ordering block only (crypttab, systemd drop-ins). Safe to run against already-encrypted live nodes. Does NOT re-run prestage — combine with `--tags prestage,systemd` if you also want the network gate re-validated. |

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

## Example playbook

### Basic — Tang-only, no ZFS, no Proxmox

```yaml
- name: "Encrypt data disks"
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
        clevis_zfs_pool_topology: "raidz2"
        clevis_dns_servers:
          - "192.168.1.1"
```

### With ZFS pool, register storage on the caller side

```yaml
- name: "Encrypt data disks; register pool with Proxmox afterwards"
  hosts: new_proxmox_hosts
  become: true
  gather_facts: true

  tasks:
    - name: "Apply disk encryption"
      ansible.builtin.include_role:
        name: clevis-encryption
      vars:
        clevis_encryption_enabled: "{{ encrypt_data_disks | default(false) }}"
        clevis_pool_name: "data"
        clevis_zfs_pool_topology: "mirror"

    - name: "Register the ZFS pool as Proxmox storage"
      community.proxmox.proxmox_storage:
        api_host: "{{ ansible_host | default(inventory_hostname) }}"
        api_user: "{{ proxmox_user }}"
        api_password: "{{ proxmox_password }}"
        validate_certs: false
        name: "{{ clevis_pool_name }}"
        type: zfspool
        content: [images, rootdir]
        zfspool_options:
          pool: "{{ clevis_pool_name }}"
          sparse: true
        state: present
      delegate_to: localhost
      become: false
      when: encrypt_data_disks | default(false) | bool
```

With the following in `group_vars`:

```yaml
tang_servers:
  - url: "https://tang-prod.example.com"
  - url: "https://tang-backup.example.com"

encrypt_data_disks: true
clevis_ipv4_only: false   # set true on Hetzner or other dual-stack hosts
                          # where Tang is IPv4-only
```

### Re-apply boot ordering to existing nodes

```bash
ansible-playbook your-playbook.yml --tags systemd
```

This is safe to run on live systems.  It rewrites crypttab entries and systemd
drop-ins without touching the LUKS key slots.

## How boot unlock works

```
systemd-sysctl.service ──┐
network-online.target ───┤
                         ▼
             clevis-network-ready.service   ← only when clevis_ipv4_only=true
                         │
                         ▼
         clevis-luks-askpass.service
         (fetches Tang adv, unlocks LUKS)
                         │
                         ▼
         remote-cryptsetup.target
         (reached when all crypt units unlock or time out)
                         │
                         ▼
         zfs-import-cache.service
         (imports pool from /etc/zfs/zpool.cache)
                         │
                         ▼
         zfs-mount.service → dependent services
```

The `nofail` crypttab flag ensures boot continues even if Tang is unreachable
(e.g. Tang server maintenance).  The disk will not be unlocked in that case and
services depending on the pool will fail, but the host itself boots to a
recoverable state.

## Compatibility

| Distribution | Initramfs | Tested |
|---|---|---|
| Debian 12 (Bookworm) | initramfs-tools | Yes |
| Debian 13 (Trixie) | initramfs-tools | Yes |
| Ubuntu 22.04+ | initramfs-tools | Likely works, not tested |
| RHEL / Fedora | dracut | **Not supported** — use `linux-system-roles/nbde_client` |

## Upgrade notes

### Removed: networking.service early bring-up drop-in

An earlier version of this role wrote `/etc/systemd/system/networking.service.d/10-override.conf`
to start networking before `sysinit` so Clevis could reach Tang. It was validated
to **break boot** (a systemd ordering cycle) and has been replaced by the late,
decoupled unlock chain (`clevis-unlock-data` → `encrypted-storage-import` → …).

This role **no longer writes** that drop-in. It also deliberately does **not
delete** it: the role cannot prove it owns a generically-named file in another
service's drop-in directory, and a reusable role must never clobber a file it
doesn't own.

**If you ran a pre-rework version of this role**, that stale drop-in may still be
on your nodes and will keep breaking boot. Remove it as a deliberate, one-time
step from your own playbook/runbook — you have the context to know the file is
yours. A content-guarded example (removes the file only when it matches what this
role used to write — the distinctive `After=… ifupdown2-pre.service sysinit.target`
line — so it never touches an unrelated `10-override.conf`):

```yaml
- name: "Stat the legacy clevis networking.service drop-in"
  ansible.builtin.stat:
    path: /etc/systemd/system/networking.service.d/10-override.conf
  register: _dropin
- name: "Read it (only when present)"
  ansible.builtin.slurp:
    src: /etc/systemd/system/networking.service.d/10-override.conf
  register: _dropin_raw
  when: _dropin.stat.exists
- name: "Remove only the old clevis-written drop-in"
  ansible.builtin.file:
    path: /etc/systemd/system/networking.service.d/10-override.conf
    state: absent
  when:
    - _dropin.stat.exists
    - "'ifupdown2-pre.service sysinit.target' in (_dropin_raw.content | b64decode)"
```

## Testing

The role ships with a [Molecule](https://ansible.readthedocs.io/projects/molecule/)
test suite under `molecule/default/`.  It uses the Docker driver with a
privileged Debian 13 (Trixie) container that has `systemd` as PID 1.

### Prerequisites

```bash
pip install molecule molecule-plugins[docker] ansible
```

Docker must be running on the controller.

### Running the tests

```bash
cd ansible/roles/clevis-encryption
molecule test
```

`molecule test` runs the full lifecycle: `create → prepare → converge → verify → destroy`.

To iterate faster during development:

```bash
molecule converge   # apply role changes to a running instance
molecule verify     # re-run assertions without re-converging
molecule destroy    # tear down the container
```

### What is tested

The test suite focuses on the **boot-ordering block** (always runs, idempotent):

- `/etc/crypttab` contains a correct entry for the loopback device with all
  required flags (`_netdev`, `x-systemd.after=network-online.target`, `discard`,
  `nofail`)
- `/dev/mapper/crypt-loop0` is open and `discards` is active in the dm-crypt table
- `/etc/gai.conf` contains both IPv4 precedence lines (because `clevis_ipv4_only: true`
  is set in the test scenario)
- `clevis-network-ready.service` is deployed
- `clevis-luks-askpass.service.d/ipv4-only.conf` and `network-online.conf` drop-ins
  are deployed

The provisioning block (LUKS format, Clevis bind, ZFS pool creation) is skipped
in the test because `prepare.yml` pre-creates the recovery key file — the same
mechanism that prevents re-provisioning on live nodes.

### How disk mocking works

The disk discovery task in `tasks/main.yml` carries a
`when: clevis_raw_disks is not defined` guard.  The Molecule `host_vars` in
`molecule.yml` pre-set `clevis_raw_disks: [loop0]`, so the task is skipped and
the role operates on the loopback device rather than trying to inspect
`ansible_devices` (which is unreliable in containers).

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

### Tang connections use IPv6 on dual-stack hosts (`clevis_ipv4_only`)

**Symptom:** Clevis fails to unlock at boot on a dual-stack host.  Manually
running `clevis luks unlock` or `curl <tang-url>/adv` works only when IPv6 is
explicitly blocked.

**Cause:** On dual-stack hosts (e.g. Hetzner dedicated servers), `getaddrinfo()`
returns AAAA records before A records by default.  Even when
`net.ipv6.conf.all.disable_ipv6=1` is configured in `/etc/sysctl.d/`, the sysctl
only prevents *new* IPv6 addresses being assigned — addresses already configured
before `systemd-sysctl.service` ran remain active.  Clevis then attempts Tang
connections over IPv6, which fails if the Tang server only accepts IPv4 clients.

**Fix:** Set `clevis_ipv4_only: true`.  This writes a two-line `/etc/gai.conf`
block that explicitly raises IPv4-mapped precedence (100) and lowers native IPv6
precedence (1), making `getaddrinfo()` return A records first for all
applications.

```
precedence ::ffff:0:0/96  100
precedence ::/0           1
```

A single `precedence ::ffff:0:0/96  100` line is not sufficient: glibc may
fall back to a built-in default of 40 for `::/0`, and RFC 6724 Rule 5
(prefer matching scope/label) can still favour IPv6 before Rule 6 (precedence)
is reached.  Both lines are required.

**Caveat — `systemd-resolved`:** If the host uses `systemd-resolved` as its
stub resolver (`/etc/resolv.conf` → `127.0.0.53`), `gai.conf` changes have
no effect on DNS resolution order.  `systemd-resolved` performs its own RFC 6724
address sorting and does not consult `/etc/gai.conf`.  In this case the only
reliable fix is to ensure IPv6 is fully disabled at the kernel level before
`clevis-luks-askpass.service` starts, or to restrict the Tang DNS record to
A records only.

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

### Boot unlock hangs or loops (Tang unreachable)

If Tang is unreachable at boot time:

- The `nofail` crypttab flag allows `remote-cryptsetup.target` to be reached
  without the disk being unlocked.
- `ConditionPathExists=/dev/mapper/crypt-<disk>` on the ZFS import drop-ins
  causes ZFS import to be **skipped** rather than attempting to import a
  degraded or missing pool.
- The host boots to `multi-user.target` without ZFS, remaining accessible
  for operator intervention.
- To unlock manually after fixing Tang connectivity:

```bash
clevis luks unlock -d /dev/<device>
# then import the pool:
zpool import <pool-name>
```

## License

MIT
