# nix-config

> **Original author:** [notthebee](https://git.notthebe.ee/notthebee/nix-config). All credit for the original configuration goes to him. This is a personal fork with modifications for my own setup.

Configuration files for my NixOS machine.

Very much a work in progress.

## Hardware

- **CPU**: Intel
- **RAM**: 32GB
- **Boot**: Kingston SNV3S 500GB NVMe
- **Storage**: 2x WD 12TB HDD (1 data + 1 parity)

## Services

> This section is generated automatically from the Nix configuration using GitHub Actions and [this cursed Nix script](bin/generateServicesTable.nix)

<!-- BEGIN SERVICE LIST -->
### sweet
|Icon|Name|Description|Category|
|---|---|---|---|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/bazarr.svg' width=32 height=32>|Bazarr|Subtitle manager|Arr|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/deluge.svg' width=32 height=32>|Deluge|Torrent client|Downloads|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/immich.svg' width=32 height=32>|Immich|Self-hosted photo and video management solution|Media|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/jellyfin.svg' width=32 height=32>|Jellyfin|The Free Software Media System|Media|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/jellyseerr.svg' width=32 height=32>|Jellyseerr|Media request and discovery manager|Arr|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/keycloak.svg' width=32 height=32>|Keycloak|Open Source Identity and Access Management|Services|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/microbin.png' width=32 height=32>|Microbin|A minimal pastebin|Services|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/miniflux-light.svg' width=32 height=32>|Miniflux|Minimalist and opinionated feed reader|Services|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/nextcloud.svg' width=32 height=32>|Nextcloud|Enterprise File Storage and Collaboration|Services|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/paperless.svg' width=32 height=32>|Paperless-ngx|Document management system|Services|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/prowlarr.svg' width=32 height=32>|Prowlarr|PVR indexer|Arr|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/radarr.svg' width=32 height=32>|Radarr|Movie collection manager|Arr|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/sabnzbd.svg' width=32 height=32>|SABnzbd|The free and easy binary newsreader|Downloads|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/slskd.svg' width=32 height=32>|slskd|Web-based Soulseek client|Downloads|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/sonarr.svg' width=32 height=32>|Sonarr|TV show collection manager|Arr|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/uptime-kuma.svg' width=32 height=32>|Uptime Kuma|Service monitoring tool|Services|
|<img src='https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/bitwarden.svg' width=32 height=32>|Vaultwarden|Password manager|Services|

<!-- END SERVICE LIST -->

## Installation runbook (NixOS)

### 1. Prepare the live environment

Boot from NixOS USB installer, then create a root password:

```bash
sudo su
passwd
```

From your host, copy the public SSH key to the server:

```bash
export NIXOS_HOST=192.168.2.xxx
ssh-copy-id -i ~/.ssh/id_ed25519 root@$NIXOS_HOST
```

SSH into the host:

```bash
ssh root@$NIXOS_HOST
```

Enable flakes:

```bash
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

### 2. Partition and mount drives

Expand the live ISO tmpfs (required for large installs):

```bash
mount -o remount,size=28G /
```

Partition the boot NVMe using [disko](https://github.com/nix-community/disko).
The disko config is hardcoded for the Kingston NVMe — if your disk is different,
edit the file before running:

```bash
curl -o /tmp/disko.nix https://raw.githubusercontent.com/brunodmsi/nix-config/main/disko/zfs-root/default.nix
nix --experimental-features "nix-command flakes" run github:nix-community/disko \
    -- -m destroy,format,mount /tmp/disko.nix
```

Verify pools are online:

```bash
zpool status
```

### 3. Clone and install (minimal)

The initial install uses a minimal config (no services, no secrets, no data drive mounts)
because:

- The live USB tmpfs can't hold all service packages
- Agenix secrets are placeholders and can't decrypt
- Data HDDs are not yet configured

See [RESTORE.md](RESTORE.md) for full details on what's disabled and how to restore.

Install git and clone:

```bash
nix-env -f '<nixpkgs>' -iA git
git clone https://github.com/brunodmsi/nix-config.git /mnt/etc/nixos
```

Install the system:

```bash
nixos-install \
--root "/mnt" \
--no-root-passwd \
--flake "git+file:///mnt/etc/nixos#sweet"
```

Unmount and reboot (remove USB drive):

```bash
umount -Rl /mnt
zpool export -a
reboot
```

### 4. First boot

Log in with:
- **User**: `bmasi`
- **Password**: `changeme` (change immediately with `passwd`)
- **SSH**: port 22, password auth enabled

### 5. Post-install setup

After booting on real disk, follow [RESTORE.md](RESTORE.md) to:

1. **Set up Cloudflare** — Create API tokens for DNS and firewall management
2. **Set up agenix secrets** — Generate host SSH key, encrypt real secrets
3. **Set up data drives** — Format and mount the 2x 12TB HDDs
4. **Restore full config** — Copy `.full.nix` files back and rebuild
5. **Update personal settings** — SSH keys, git config, email addresses
