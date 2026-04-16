# clevis-encryption

An Ansible role that provisions LUKS2 full-disk encryption on Debian hosts,
binds the unlock key to one or more Tang servers using Clevis Shamir Secret
Sharing, and configures the correct systemd boot ordering so encrypted devices
are unlocked before any dependent service (ZFS, NFS, databases) starts.

Optionally creates a ZFS pool on top of the encrypted devices and registers it
with Proxmox VE.

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
| `clevis_register_proxmox_storage` | `false` | Run `pvesm add zfspool` after pool creation to register the pool as a Proxmox VE storage backend. |
| `clevis_vault_password_file` | `"~/.ansible_vault_pass"` | Path to the Ansible Vault password file on the controller, used to encrypt the per-host recovery key. |
| `clevis_keep_temp_key` | `false` | Retain `/tmp/ansible_luks_key` on the remote host after provisioning. Leave `false` in production. |
| `clevis_destroy_existing` | `false` | Destroy an existing ZFS pool before (re-)provisioning. **Destructive.** |
| `clevis_dns_servers` | `[]` | Nameservers to prepend to `/etc/resolv.conf` during provisioning. Useful when Tang is reachable only via an internal DNS zone not in the host's default resolver. Empty = no change. |
| `clevis_ipv4_only` | `false` | Deploy a systemd gate that verifies IPv6 is disabled before allowing Tang unlock attempts. See [IPv4-only mode](#ipv4-only-mode). |

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
| `provision` | The provisioning block only (LUKS format, Clevis bind, ZFS pool creation). Skipped automatically if the recovery key already exists on the controller. |
| `systemd` | The boot ordering block only (crypttab, systemd drop-ins, network gate). Safe to run against already-encrypted live nodes. |

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

### With ZFS pool and Proxmox registration

```yaml
- name: "Encrypt data disks and register with Proxmox"
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
        clevis_register_proxmox_storage: true
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

## License

MIT
