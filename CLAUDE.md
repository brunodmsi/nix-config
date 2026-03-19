# CLAUDE.md

## Project overview

NixOS homelab configuration for a single machine called **sweet**. Forked from [notthebee/nix-config](https://git.notthebe.ee/notthebee/nix-config).

## Architecture

- **Flake-based** NixOS config using flake-parts
- **Machine**: `sweet` (only machine, defined in `modules/machines/nixos/sweet/`)
- **Builder**: `modules/machines/nixos/default.nix` auto-discovers machines by directory
- **Services**: Defined in `modules/homelab/services/`, enabled per-machine in `sweet/homelab/default.nix`
- **Secrets**: Managed via agenix, stored in separate repo `brunodmsi/nix-secrets`
- **Immutable root**: ZFS with `rpool/nixos/empty@start` snapshot rollback on boot

## Hardware (sweet)

- Intel CPU, 32GB RAM
- Boot: Kingston SNV3S 500GB NVMe (ZFS pools: bpool + rpool)
- Storage: 2x WD 12TB HDD (XFS — Data1 + Parity1, snapraid)

## Key paths

- `flake.nix` — Entry point, all inputs
- `modules/machines/nixos/sweet/configuration.nix` — Machine config
- `modules/machines/nixos/sweet/homelab/default.nix` — Service toggles (currently minimal)
- `modules/machines/nixos/sweet/homelab/full.nix` — Full service config (to restore)
- `modules/machines/nixos/sweet/filesystems/` — Drive mounts and snapraid
- `modules/machines/nixos/_common/default.nix` — Shared config (currently minimal)
- `modules/homelab/services/` — Service module definitions
- `disko/zfs-root/default.nix` — Standalone disk partitioning config
- `RESTORE.md` — Documents everything disabled and how to restore

## Current state

Minimal install — most services and agenix are disabled. See `RESTORE.md` for details.

Full configs are saved as `.full.nix` files:
- `modules/machines/nixos/default.full.nix`
- `modules/machines/nixos/_common/default.full.nix`
- `modules/machines/nixos/sweet/configuration.full.nix`
- `modules/machines/nixos/sweet/homelab/full.nix`

## Conventions

- User is **bmasi** everywhere (not notthebee)
- All code changes are pushed to `github:brunodmsi/nix-config` — the server pulls from there
- Never run server commands (mkfs, passwd, nixos-rebuild, etc.) locally — provide them as instructions
- Always `git push` after making changes so the server can `git pull`
- Use `nofail` mount option for drives that may not be formatted/available yet
- Disko config must match the NixOS zfs-root boot config (immutable=true → `rpool/nixos/empty`, immutable=false → `rpool/nixos/root`)
- When disabling services, prefer `enable = false` over removing code — keep structure for re-enabling
- Test config changes will be evaluated on the server, not locally
- Domain is `demasi.dev` (Cloudflare DNS, nameservers moved from Route 53)
- Cloudflare Tunnel (`cloudflared`) for external access — routes managed in Cloudflare dashboard, protocol forced to `http2`

## Secrets management (agenix)

**Every secret must go through agenix. Never hardcode secrets or use plain files on disk.**

- Secrets repo: `github:brunodmsi/nix-secrets` (public — files are age-encrypted)
- Identity key: `/persist/ssh/ssh_host_ed25519_key` on the server
- Secrets are declared in `sweet/configuration.nix` under `age.secrets`
- Referenced in service configs via `config.age.secrets.<name>.path`

### Adding a new secret

1. Add the entry to `secrets.nix` in the nix-secrets repo:
   ```nix
   "myNewSecret.age".publicKeys = all;
   ```
2. Encrypt it on the server:
   ```bash
   cd /tmp/nix-secrets && git pull
   rm myNewSecret.age  # remove placeholder if exists
   sudo EDITOR=nano nix run github:ryantm/agenix -- -e myNewSecret.age -i /persist/ssh/ssh_host_ed25519_key
   git add -A && git commit -m "Encrypt myNewSecret" && git push
   ```
3. Declare it in `sweet/configuration.nix`:
   ```nix
   age.secrets.myNewSecret.file = "${inputs.secrets}/myNewSecret.age";
   ```
4. Reference it in service config:
   ```nix
   someService.passwordFile = config.age.secrets.myNewSecret.path;
   ```
5. Push nix-config, pull and rebuild on server.

## Common workflows

### Push a config change
```bash
# Local (this machine)
git add -A && git commit -m "description" && git push

# Server
cd /etc/nixos && sudo git pull
sudo nixos-rebuild switch --flake /etc/nixos#sweet
```

### Fresh install from USB
See README.md installation runbook. Key: expand tmpfs first (`mount -o remount,size=28G /`).
