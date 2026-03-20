# Security hardening TODO

## Add to Authelia (web-only, no mobile apps)
- Sonarr, Radarr, Bazarr, Prowlarr, Jellyseerr
- Paperless
- Grafana, Prometheus

## Keep direct access (mobile apps need it)
- Jellyfin (Jellyfin app)
- Immich (Immich photo backup app)
- Nextcloud (Nextcloud sync app)

## Set up Fail2ban for direct-access services
Watches login attempts, auto-bans IPs after too many failures.
Needed for: Jellyfin, Immich, Nextcloud

## Enable 2FA on services that support it
- Authelia: TOTP (protects all services behind it)
- Nextcloud: enable TOTP app in settings
- Vaultwarden: enable TOTP in user settings
- Uptime Kuma: enable TOTP in settings
- Grafana: enable TOTP in settings

## Services with NO 2FA and NO Authelia (highest risk)
- Jellyfin, Immich — rely on Fail2ban only
