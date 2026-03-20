# Restoring full configuration after initial install

The initial install uses a minimal config because agenix can't decrypt placeholder
secrets from the USB installer. Once booted on real disk, restore the full config.

## What was disabled and why

All disabled items are because they reference `inputs.secrets` / `config.age.secrets`
which require real age-encrypted secrets to evaluate, or because they depend on
hardware (data drives) not yet configured.

### Builder (`modules/machines/nixos/default.nix`)

Removed from module list (full version in `default.full.nix`):

- `self.inputs.agenix.nixosModules.default` — Agenix secret decryption (all secrets are placeholders)
- `self.inputs.home-manager.nixosModules.home-manager` — Home Manager + dotfiles (needs `gitIncludes`, `bwSession` secrets)
- `../../users/bmasi` — User config with agenix age.nix (needs secrets)
- `homeManagerCfg` — Home Manager wrapper config

Kept (these just define options, no secret deps):

- `../../misc/email`, `../../misc/tg-notify`, `../../misc/mover`, `../../misc/withings2intervals`
- `self.inputs.autoaspm`, `self.inputs.fmatrix`, `self.inputs.invoiceplane`, `self.inputs.adios-bot`

### Common config (`modules/machines/nixos/_common/default.nix`)

Removed (full version in `_common/default.full.nix`):

- SSH config for `git.notthebe.ee` — Forgejo SSH known hosts/identity
- `system.autoUpgrade` — Auto upgrade with git pull (needs working git remote)
- `"${inputs.secrets}/networks.nix"` import — Network reservations/topology
- `age.secrets.hashedUserPassword` — Hashed user password via agenix
- `age.secrets.smtpPassword` — SMTP password via agenix
- `email` config block — Email alert settings
- `homelab.motd` — Message of the day
- User password set to `initialPassword = "changeme"` instead of agenix-managed hash
- SSH changed to port 22 with password auth (was port 69, key-only)

### Machine config (`modules/machines/nixos/sweet/configuration.nix`)

Removed (full version in `configuration.full.nix`):

- `../../../misc/tailscale` import — Tailscale VPN (needs `tailscaleAuthKey` secret)
- `../../../misc/agenix` import — Shared agenix secrets (samba, cloudflare, restic, etc.)
- `./backup` import — Restic backup config (needs `resticPassword`, `resticBackblazeEnv` secrets)
- `./secrets` import — Machine-specific agenix secret declarations
- `services.duckdns` — Dynamic DNS (needs `duckDNSDomain`, `duckDNSToken` secrets)
- `services.withings2intervals` — Health data sync (needs secrets)
- `services.mover` — Cache/backing array file mover (needs data drives)
- `services.autoaspm` — PCIe ASPM power management
- `services.hddfancontrol` — HDD fan control (needs data drives)
- `systemd.services.hd-idle` — HDD spin-down daemon (needs data drives)
- `services.prometheus.exporters` — Prometheus metrics exporters
- `services.udev.extraRules` — NIC rename rules (MAC-specific to original hardware)
- `tg-notify` — Telegram notifications (needs secret)
- `services.adiosBot` — Telegram bot (needs secret)
- `systemd.network` with static IP — Replaced with `useDHCP = true`
- `powerManagement.powertop` — Power management
- `immutable = true` — ZFS immutable root (rolls back `/` on boot, causes emergency mode on fresh install)

### Filesystems (`modules/machines/nixos/sweet/filesystems/`)

Removed (original config expected 3 data + 1 parity drives):

- `fileSystems."/mnt/data1"` through `/mnt/data3` — XFS data drives (`Data1`, `Data2`, `Data3` labels)
- `fileSystems."/mnt/parity1"` — XFS parity drive (`Parity1` label)
- `fileSystems.${hl.mounts.fast}` — ZFS `cache` dataset
- `fileSystems.${hl.mounts.slow}` — mergerfs pool over data drives
- `fileSystems.${hl.mounts.merged}` — mergerfs cache + slow merged view
- `services.snapraid` — Snapraid with 3 data disks + 1 parity
- `services.smartd` — SMART monitoring with email alerts

Current hardware: 1x Kingston NVMe 500G (boot), 2x WD 12TB HDD (not yet configured).
These will need a new filesystem config when the HDDs are set up (1 data + 1 parity).

### Homelab config (`modules/machines/nixos/sweet/homelab/default.nix`)

All services set to `enable = false` (full version in `homelab/full.nix`):

- fail2ban-cloudflare, samba, slskd, backup, keycloak, radicale, immich
- invoiceplane, homepage, jellyfin, paperless, sabnzbd, sonarr, radarr
- bazarr, prowlarr, jellyseerr, nextcloud, vaultwarden, microbin
- miniflux, navidrome, audiobookshelf, uptime-kuma, deluge, wireguard-netns

`cloudflare.dnsCredentialsFile` set to `/dev/null` placeholder (needs agenix secret).

## How to restore

### 1. Set up Cloudflare DNS API credentials

Many services use Cloudflare for ACME/Let's Encrypt certificates and DNS management.

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com) > your domain > API Tokens
2. Create a token with `Zone:DNS:Edit` and `Zone:Zone:Read` permissions
3. Save the token — you'll need it for the `cloudflareDnsApiCredentials` agenix secret:
   ```
   CLOUDFLARE_DNS_API_TOKEN=your-token-here
   ```
4. For `fail2ban-cloudflare`, create a separate token with `Firewall:Edit` permissions
   and note the Zone ID from the domain overview page

### 2. Set up agenix secrets

Before restoring the full config, you need real age-encrypted secrets:

```bash
# Generate the host SSH key (used as agenix identity)
ssh-keygen -t ed25519 -f /persist/ssh/ssh_host_ed25519_key -N ""

# Get the public key for secrets.nix
cat /persist/ssh/ssh_host_ed25519_key.pub
```

Clone your secrets repo and configure it:

```bash
git clone git@github.com:brunodmsi/nix-secrets.git
cd nix-secrets
```

Edit `secrets.nix` with your public keys:

```nix
let
  sweet = "ssh-ed25519 AAAA..."; # from above
  user = "ssh-ed25519 AAAA...";  # your personal key
in
{
  "hashedUserPassword.age".publicKeys = [ sweet user ];
  "sambaPassword.age".publicKeys = [ sweet user ];
  "cloudflareDnsApiCredentials.age".publicKeys = [ sweet user ];
  "cloudflareFirewallApiKey.age".publicKeys = [ sweet user ];
  # ... repeat for each secret you need
}
```

Encrypt each secret:

```bash
# Install agenix if not available
nix-env -iA nixpkgs.agenix

# Encrypt secrets one by one
agenix -e cloudflareDnsApiCredentials.age
agenix -e hashedUserPassword.age
# ... etc
```

Push the encrypted secrets:

```bash
git add -A && git commit -m "Add real encrypted secrets" && git push
```

### 3. Set up data drives

Current hardware: 2x WD 12TB HDD (1 data, 1 parity). Once ready:

1. Partition and format the data drive as XFS
2. Partition and format the parity drive as XFS
3. Update `sweet/filesystems/default.nix` with mount entries
4. Update `sweet/filesystems/snapraid.nix` with 1 data disk + 1 parity
5. Optionally set up mergerfs if you want cache tiering with the NVMe

### 4. Restore config files

```bash
cd /etc/nixos/modules/machines/nixos

# Restore builder (adds agenix + home-manager)
cp default.full.nix default.nix

# Restore common config (adds secrets, SSH, auto-upgrade)
cp _common/default.full.nix _common/default.nix

# Restore machine config (adds tailscale, backup, services, etc.)
cp sweet/configuration.full.nix sweet/configuration.nix

# Restore homelab services
cp sweet/homelab/full.nix sweet/homelab/default.nix
```

### 5. Rebuild

```bash
cd /etc/nixos
nixos-rebuild switch --flake /etc/nixos#sweet
```

## Disaster recovery scenarios

### Boot NVMe dies
- **NixOS config**: safe (GitHub: brunodmsi/nix-config)
- **Secrets**: safe (GitHub: brunodmsi/nix-secrets, age-encrypted)
- **Service databases**: safe (daily rsync to /mnt/data1/Backups)
- **Media files**: safe (on data HDD)
- **Recovery**: install new NVMe, reinstall NixOS via README runbook, rsync backups back to /var/lib/ and /persist/

### Data HDD dies
- **Media**: recoverable from parity drive via `snapraid fix`
- **Service DB backups**: LOST (stored on same HDD)
- **Recovery**: replace drive, run `snapraid fix` to reconstruct data from parity

### Parity HDD dies
- **Everything**: safe, data drive is unaffected
- **Recovery**: replace parity drive, run `snapraid sync` to rebuild parity

### Both HDDs die
- **Everything local**: LOST
- **NixOS config + secrets**: safe (GitHub)
- **Recovery**: start from scratch, re-download media

### All drives die (fire/theft/power surge)
- Only GitHub repos survive
- **No off-site backup currently**

## TODO: Off-site backup

Set up Backblaze B2 (~$5/month) for:
- Service databases (/var/lib/ critical dirs) — small, back up daily
- Nextcloud data — depends on size
- /persist/ (SSH keys, etc.)

Media files are replaceable (re-download) so skip those to save cost.
Use restic with B2 backend for encrypted, incremental backups.

## Snapraid notes

Current setup: 1 data drive + 1 parity drive.
- Protects against a SINGLE drive failure only
- NOT a mirror — parity can reconstruct, but needs a replacement drive
- NOT off-site — both drives in same machine
- Run `snapraid sync` periodically (set up as systemd timer)
- Run `snapraid scrub` to verify data integrity
