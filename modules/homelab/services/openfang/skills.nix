# OpenFang skill definitions and deployment
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.services.openfang;
  openfangBin = "${cfg.configDir}/.openfang/bin/openfang";
  openfangConfig = "/etc/openfang/config.toml";
  skillsDir = "${cfg.configDir}/.openfang/skills";

  # --- ping-test skill (Phase 0 validation) ---
  pingTestToml = pkgs.writeText "ping-test-skill.toml" ''
    [skill]
    name = "ping-test"
    version = "0.1.0"
    description = "Test skill — returns pong"
    author = "bmasi"
    tags = ["test"]

    [runtime]
    type = "python"
    entry = "src/main.py"

    [[tools.provided]]
    name = "ping"
    description = "Returns pong — used to test the skill system is working"
    input_schema = { type = "object", properties = {} }
  '';

  pingTestPy = pkgs.writeText "ping-test-main.py" ''
    #!/usr/bin/env python3
    import json, sys
    req = json.loads(sys.stdin.readline())
    print(json.dumps({"result": "pong"}))
  '';

  pingTestSkill = pkgs.runCommand "ping-test-skill" {} ''
    mkdir -p $out/src
    cp ${pingTestToml} $out/skill.toml
    cp ${pingTestPy} $out/src/main.py
  '';

  # --- homelab-server skill (Phase 1) ---
  serverSkillToml = pkgs.writeText "homelab-server-skill.toml" ''
    [skill]
    name = "homelab-server"
    version = "0.1.0"
    description = "NixOS homelab server monitoring — logs, storage, zpool, snapraid, services, auth, backup, tunnel"
    author = "bmasi"
    tags = ["homelab", "monitoring", "nixos"]

    [runtime]
    type = "python"
    entry = "src/main.py"

    [[tools.provided]]
    name = "server_errors"
    description = "Recent error/warning journal entries. Use when user asks about errors, issues, or problems."
    input_schema = { type = "object", properties = { timeframe = { type = "string", description = "1h, 6h, or 24h (default: 1h)" } } }

    [[tools.provided]]
    name = "server_service_logs"
    description = "Last N lines of a specific systemd service log. Use when user asks about a specific service."
    input_schema = { type = "object", properties = { service = { type = "string", description = "Service name, e.g. jellyfin, sonarr, deluge" }, lines = { type = "integer", description = "Number of lines (default: 30)" } }, required = ["service"] }

    [[tools.provided]]
    name = "server_failed_units"
    description = "List failed systemd units. Use when user asks what's broken or failing."
    input_schema = { type = "object", properties = {} }

    [[tools.provided]]
    name = "server_storage"
    description = "Disk usage per mount point with growth forecast. Use when user asks about disk space."
    input_schema = { type = "object", properties = {} }

    [[tools.provided]]
    name = "server_zpool_status"
    description = "ZFS pool health for bpool and rpool. Use when user asks about ZFS or pool health."
    input_schema = { type = "object", properties = {} }

    [[tools.provided]]
    name = "server_snapraid_status"
    description = "Snapraid parity health and last sync time. Use when user asks about snapraid or data protection."
    input_schema = { type = "object", properties = {} }

    [[tools.provided]]
    name = "server_snapraid_diff"
    description = "Files changed since last snapraid sync. Shows what would be synced next."
    input_schema = { type = "object", properties = {} }

    [[tools.provided]]
    name = "server_auth_events"
    description = "Authelia authentication events — logins, failures, suspicious activity."
    input_schema = { type = "object", properties = { timeframe = { type = "string", description = "1h, 6h, or 24h (default: 1h)" } } }

    [[tools.provided]]
    name = "server_backup_status"
    description = "Last backup run time and result. Daily rsync to HDD."
    input_schema = { type = "object", properties = {} }

    [[tools.provided]]
    name = "server_tunnel_status"
    description = "Cloudflare tunnel health and status."
    input_schema = { type = "object", properties = {} }

    [requirements]
    capabilities = ["ShellExec(*)"]
  '';

  serverSkillPy = pkgs.writeText "homelab-server-main.py" ''
    #!/usr/bin/env python3
    """homelab-server skill — server monitoring tools for OpenFang."""
    import json
    import os
    import re
    import sys
    import subprocess

    os.environ["PATH"] = "/run/current-system/sw/bin:" + os.environ.get("PATH", "")

    STORAGE_HISTORY = "/persist/openfang/storage-history.csv"


    def run_cmd(cmd, timeout=30):
        try:
            r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
            out = r.stdout.strip()
            err = r.stderr.strip()
            return out if out else err if err else "No output"
        except subprocess.TimeoutExpired:
            return "Command timed out"
        except Exception as e:
            return f"Error: {e}"


    def server_errors(inp):
        tf = inp.get("timeframe", "1h")
        since = {"1h": "1 hour ago", "6h": "6 hours ago", "24h": "24 hours ago"}.get(tf, "1 hour ago")
        return run_cmd(f'journalctl -p err --since "{since}" --no-pager -n 50')


    def server_service_logs(inp):
        svc = inp.get("service", "")
        if not svc:
            return "Error: service name required"
        if not re.match(r'^[a-zA-Z0-9._@-]+$', svc):
            return "Error: invalid service name"
        lines = min(int(inp.get("lines", 30)), 100)
        return run_cmd(f'journalctl -u {svc} -n {lines} --no-pager')


    def server_failed_units(inp):
        return run_cmd('systemctl --failed --no-pager')


    def server_storage(inp):
        df_out = run_cmd('df -h /mnt/data1 /mnt/parity1 / /boot 2>/dev/null')
        try:
            with open(STORAGE_HISTORY) as f:
                lines = f.readlines()[-7:]
            forecast = "\nLast 7 days:\n" + "".join(lines)
        except FileNotFoundError:
            forecast = "\nNo storage history yet."
        return df_out + forecast


    def server_zpool_status(inp):
        return run_cmd('zpool status')


    def server_snapraid_status(inp):
        status = run_cmd('snapraid status', timeout=60)
        last_sync = run_cmd('systemctl show snapraid-sync --property=ExecMainStartTimestamp --value')
        last_result = run_cmd('systemctl show snapraid-sync --property=Result --value')
        return f"Last sync: {last_sync} (result: {last_result})\n\n{status}"


    def server_snapraid_diff(inp):
        return run_cmd('snapraid diff', timeout=120)


    def server_auth_events(inp):
        tf = inp.get("timeframe", "1h")
        since = {"1h": "1 hour ago", "6h": "6 hours ago", "24h": "24 hours ago"}.get(tf, "1 hour ago")
        return run_cmd(f'journalctl -u authelia-main --since "{since}" --no-pager -n 50')


    def server_backup_status(inp):
        last_run = run_cmd('systemctl show backup-to-hdd --property=ExecMainStartTimestamp --value')
        last_result = run_cmd('systemctl show backup-to-hdd --property=Result --value')
        next_run = run_cmd('systemctl show backup-to-hdd.timer --property=NextElapseUSecRealtime --value')
        return f"Last run: {last_run} (result: {last_result})\nNext run: {next_run}"


    def server_tunnel_status(inp):
        return run_cmd('systemctl is-active cloudflared-tunnel') + "\n" + \
               run_cmd('systemctl show cloudflared-tunnel --property=ActiveEnterTimestamp --value')


    TOOLS = {
        "server_errors": server_errors,
        "server_service_logs": server_service_logs,
        "server_failed_units": server_failed_units,
        "server_storage": server_storage,
        "server_zpool_status": server_zpool_status,
        "server_snapraid_status": server_snapraid_status,
        "server_snapraid_diff": server_snapraid_diff,
        "server_auth_events": server_auth_events,
        "server_backup_status": server_backup_status,
        "server_tunnel_status": server_tunnel_status,
    }


    def main():
        req = json.loads(sys.stdin.readline())
        tool = req.get("tool", "")
        inp = req.get("input", {})

        handler = TOOLS.get(tool)
        if not handler:
            print(json.dumps({"error": f"Unknown tool: {tool}"}))
            return

        try:
            result = handler(inp)
            print(json.dumps({"result": result}))
        except Exception as e:
            print(json.dumps({"error": str(e)}))


    if __name__ == "__main__":
        main()
  '';

  serverSkill = pkgs.runCommand "homelab-server-skill" {} ''
    mkdir -p $out/src
    cp ${serverSkillToml} $out/skill.toml
    cp ${serverSkillPy} $out/src/main.py
  '';

  # All skills to install
  skills = [
    { name = "ping-test"; path = pingTestSkill; }
    { name = "homelab-server"; path = serverSkill; }
  ];

  installSkillsScript = pkgs.writeShellScript "openfang-install-skills" ''
    export PATH=${pkgs.python3}/bin:${pkgs.coreutils}/bin:$PATH
    export HOME=${cfg.configDir}

    echo "[skills] Installing OpenFang skills..."

    ${lib.concatMapStringsSep "\n" (skill: ''
      echo "[skills] Installing ${skill.name}..."
      ${openfangBin} skill remove ${skill.name} --config ${openfangConfig} 2>/dev/null || true
      ${openfangBin} skill install ${skill.path} --config ${openfangConfig} 2>&1 || echo "[skills] WARNING: Failed to install ${skill.name}"
    '') skills}

    echo "[skills] Done. Installed skills:"
    ${openfangBin} skill list --config ${openfangConfig} 2>&1 || true
  '';
in
{
  config = lib.mkIf cfg.enable {
    # python3 must be in system PATH for OpenFang to run Python skills
    environment.systemPackages = [ pkgs.python3 ];

    # Install/update skills on every rebuild
    systemd.services.openfang-install-skills = {
      description = "Install OpenFang skills";
      after = [ "openfang-install.service" "openfang.service" ];
      requires = [ "openfang-install.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = installSkillsScript;
      };
    };

    # Sync-agents should run after skills are installed
    systemd.services.openfang-sync-agents = {
      after = [ "openfang-install-skills.service" ];
      wants = [ "openfang-install-skills.service" ];
    };
  };
}
