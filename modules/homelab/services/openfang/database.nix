# PostgreSQL database for OpenFang (agent routing + Jellyseerr tracking)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  homelab = config.homelab;
  cfg = homelab.services.openfang;
  dbUrl = "postgresql://openfang@127.0.0.1:5432/openfang";
in
{
  config = lib.mkIf cfg.enable {
    # PostgreSQL database
    services.postgresql = {
      enable = true;
      enableTCPIP = true;
      ensureDatabases = [ "openfang" ];
      ensureUsers = [
        {
          name = "openfang";
          ensureDBOwnership = true;
        }
      ];
      authentication = lib.mkAfter ''
        host openfang openfang 127.0.0.1/32 trust
      '';
    };

    # Create tables for integrations
    systemd.services.openfang-db-init = {
      description = "Initialize OpenFang integration tables";
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "openfang-db-init" ''
          DB="${dbUrl}"
          ${pkgs.postgresql}/bin/psql -c "CREATE TABLE IF NOT EXISTS channel_users (id SERIAL PRIMARY KEY, channel TEXT NOT NULL, channel_user_id TEXT NOT NULL, display_name TEXT, created_at TIMESTAMP DEFAULT NOW(), UNIQUE(channel, channel_user_id));" "$DB"
          ${pkgs.postgresql}/bin/psql -c "CREATE TABLE IF NOT EXISTS media_requests (id SERIAL PRIMARY KEY, jellyseerr_request_id TEXT, tmdb_id TEXT, title TEXT, media_type TEXT, channel_user_id INTEGER REFERENCES channel_users(id), status TEXT DEFAULT 'pending', requested_at TIMESTAMP DEFAULT NOW());" "$DB"
          ${pkgs.postgresql}/bin/psql -c "ALTER TABLE channel_users ADD COLUMN IF NOT EXISTS agent_id TEXT;" "$DB"
          ${pkgs.postgresql}/bin/psql -c "ALTER TABLE channel_users ADD COLUMN IF NOT EXISTS remote_jid TEXT;" "$DB"
          ${pkgs.postgresql}/bin/psql -c "ALTER TABLE channel_users ADD COLUMN IF NOT EXISTS role TEXT DEFAULT 'admin';" "$DB"

          # Per-user service credentials
          ${pkgs.postgresql}/bin/psql -c "CREATE TABLE IF NOT EXISTS user_services (
            id SERIAL PRIMARY KEY,
            channel_user_id INTEGER REFERENCES channel_users(id),
            service TEXT NOT NULL,
            config JSONB NOT NULL DEFAULT '{}',
            UNIQUE(channel_user_id, service)
          );" "$DB"

          # Conversation log — persists message history across agent restarts
          ${pkgs.postgresql}/bin/psql -c "CREATE TABLE IF NOT EXISTS conversation_log (
            id SERIAL PRIMARY KEY,
            channel_user_id TEXT NOT NULL,
            direction TEXT NOT NULL,
            content TEXT NOT NULL,
            metadata JSONB DEFAULT '{}',
            created_at TIMESTAMP DEFAULT NOW()
          );" "$DB"
          ${pkgs.postgresql}/bin/psql -c "CREATE INDEX IF NOT EXISTS idx_convo_user ON conversation_log(channel_user_id, created_at DESC);" "$DB"
        '';
      };
    };
  };
}
