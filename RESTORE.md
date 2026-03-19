# Restoring full configuration after initial install

The initial install uses a minimal config because agenix can't decrypt placeholder
secrets from the USB installer. Once booted on real disk, restore the full config.

## What was disabled and why

All disabled items are because they reference `inputs.secrets` / `config.age.secrets`
which require real age-encrypted secrets to evaluate.

### Builder (`modules/machines/nixos/default.nix`)

Removed from module list (full version in `default.full.nix`):

- `../../misc/email` — SMTP email alerts (needs `smtpPassword` secret)
- `../../misc/tg-notify` — Telegram notifications (needs `tgNotifyCredentials` secret)
- `../../misc/mover` — File mover between cache/backing arrays (no secret dep, but depends on homelab mounts)
- `../../misc/withings2intervals` — Health data sync (needs `withings2intervals` secret)
- `self.inputs.agenix.nixosModules.default` — Agenix secret decryption (all secrets are placeholders)
- `self.inputs.adios-bot.nixosModules.default` — Telegram bot (needs `adiosBotToken` secret)
- `self.inputs.autoaspm.nixosModules.default` — PCIe power management (no secret dep)
- `self.inputs.fmatrix.nixosModules.default` — Matrix client (no secret dep)
- `self.inputs.invoiceplane.nixosModules.default` — Invoicing (needs DB password secret)
- `self.inputs.home-manager.nixosModules.home-manager` — Home Manager + dotfiles (needs `gitIncludes`, `bwSession` secrets)
- `../../users/notthebee` — User config with agenix age.nix (needs secrets)
- `homeManagerCfg` — Home Manager wrapper config

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
- `services.mover` — Cache/backing array file mover
- `services.autoaspm` — PCIe ASPM power management
- `services.hddfancontrol` — HDD fan control
- `systemd.services.hd-idle` — HDD spin-down daemon
- `services.prometheus.exporters` — Prometheus metrics exporters
- `services.udev.extraRules` — NIC rename rules (MAC-specific to original hardware)
- `tg-notify` — Telegram notifications (needs secret)
- `services.adiosBot` — Telegram bot (needs secret)
- `systemd.network` with static IP — Replaced with `useDHCP = true`
- `powerManagement.powertop` — Power management

### Homelab config (`modules/machines/nixos/sweet/homelab/default.nix`)

All services set to `enable = false` (full version in `homelab/full.nix`):

- fail2ban-cloudflare, samba, slskd, backup, keycloak, radicale, immich
- invoiceplane, homepage, jellyfin, paperless, sabnzbd, sonarr, radarr
- bazarr, prowlarr, jellyseerr, nextcloud, vaultwarden, microbin
- miniflux, navidrome, audiobookshelf, uptime-kuma, deluge, wireguard-netns

## How to restore

### 1. Set up real secrets first

Before restoring, you need real age-encrypted secrets in your `nix-secrets` repo:

```bash
# Generate an age key from your SSH host key
ssh-keygen -t ed25519 -f /persist/ssh/ssh_host_ed25519_key -N ""

# Use agenix to encrypt each secret
cd /path/to/nix-secrets
# Edit secrets.nix with your public keys, then:
agenix -e secretName.age
```

### 2. Restore config files

```bash
cd /etc/nixos/modules/machines/nixos
cp default.full.nix default.nix
cp _common/default.full.nix _common/default.nix
cp sweet/configuration.full.nix sweet/configuration.nix
cp sweet/homelab/full.nix sweet/homelab/default.nix
```

### 3. Rebuild

```bash
cd /etc/nixos
nixos-rebuild switch --flake /etc/nixos#sweet
```

## Username change

The user was renamed from `notthebee` to `bmasi`. This needs to be updated in:
- `_common/default.nix` (done in minimal, needs doing in full)
- `users/notthebee/` directory (rename to `users/bmasi/`)
- `default.nix` builder (`home-manager.users.notthebee` -> `home-manager.users.bmasi`)
- All home-manager references
