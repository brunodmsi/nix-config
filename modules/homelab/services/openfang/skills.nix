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

  # --- homelab-media skill (Phase 3) ---
  jfCfg = cfg.jellyfin;
  jellyfinApiUrl = "http://127.0.0.1:${toString jfCfg.port}";

  mediaSkillToml = pkgs.writeText "homelab-media-skill.toml" ''
    [skill]
    name = "homelab-media"
    version = "0.1.0"
    description = "Jellyfin media management — watch suggestions, cleanup, streaming stats"
    author = "bmasi"
    tags = ["homelab", "media", "jellyfin"]

    [runtime]
    type = "python"
    entry = "src/main.py"

    [[tools.provided]]
    name = "media_unwatched"
    description = "List unwatched movies or shows. Use when user asks what to watch or wants recommendations."
    input_schema = { type = "object", properties = { type = { type = "string", description = "movies or shows (default: movies)" }, limit = { type = "integer", description = "Max results (default: 10)" } } }

    [[tools.provided]]
    name = "media_suggest"
    description = "Random suggestion from unwatched content. Use when user asks 'what should I watch?' or wants a surprise pick."
    input_schema = { type = "object", properties = { type = { type = "string", description = "movies or shows (default: movies)" }, genre = { type = "string", description = "Optional genre filter, e.g. Action, Comedy, Drama" } } }

    [[tools.provided]]
    name = "media_finished"
    description = "Fully watched shows with disk size. Use when user asks about cleanup or finished content."
    input_schema = { type = "object", properties = {} }

    [[tools.provided]]
    name = "media_cleanup"
    description = "Delete a media item from Jellyfin library. ALWAYS confirm with user before calling this."
    input_schema = { type = "object", properties = { item_id = { type = "string", description = "Jellyfin item ID to delete" } }, required = ["item_id"] }

    [[tools.provided]]
    name = "media_stats"
    description = "Library overview — total, watched, unwatched counts for movies and shows."
    input_schema = { type = "object", properties = {} }
  '';

  mediaSkillPy = pkgs.writeText "homelab-media-main.py" ''
    #!/usr/bin/env python3
    """homelab-media skill — Jellyfin media management for OpenFang."""
    import json
    import os
    import random
    import sys
    import urllib.request
    import urllib.error

    API_URL = "${jellyfinApiUrl}"
    API_KEY_FILE = "${jfCfg.apiKeyFile}"


    def get_api_key():
        try:
            with open(API_KEY_FILE) as f:
                return f.read().strip()
        except Exception as e:
            return None


    def jf_request(path, method="GET"):
        api_key = get_api_key()
        if not api_key:
            return {"error": "Cannot read Jellyfin API key"}
        url = f"{API_URL}{path}"
        req = urllib.request.Request(url, method=method)
        req.add_header("Authorization", f'MediaBrowser Token="{api_key}"')
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                if method == "DELETE":
                    return {"ok": True}
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            return {"error": f"HTTP {e.code}: {e.reason}"}
        except Exception as e:
            return {"error": str(e)}


    def format_size(bytes_val):
        if not bytes_val:
            return "unknown"
        gb = bytes_val / (1024 ** 3)
        if gb >= 1:
            return f"{gb:.1f} GB"
        return f"{bytes_val / (1024 ** 2):.0f} MB"


    def media_unwatched(inp):
        media_type = inp.get("type", "movies")
        limit = min(int(inp.get("limit", 10)), 25)
        include_type = "Movie" if media_type == "movies" else "Series"

        data = jf_request(f"/Items?IncludeItemTypes={include_type}&IsPlayed=false&Recursive=true&SortBy=DateCreated&SortOrder=Descending&Limit={limit}&Fields=Genres,RunTimeTicks")
        if "error" in data:
            return data["error"]

        items = data.get("Items", [])
        if not items:
            return f"No unwatched {media_type} found."

        lines = [f"Unwatched {media_type} ({len(items)}):"]
        for item in items:
            name = item.get("Name", "Unknown")
            year = item.get("ProductionYear", "")
            genres = ", ".join(item.get("Genres", [])[:3])
            runtime = ""
            ticks = item.get("RunTimeTicks")
            if ticks:
                mins = ticks // 600000000
                runtime = f" ({mins}min)"
            lines.append(f"- {name} ({year}) [{genres}]{runtime}")
        return "\n".join(lines)


    def media_suggest(inp):
        media_type = inp.get("type", "movies")
        genre = inp.get("genre", "")
        include_type = "Movie" if media_type == "movies" else "Series"

        path = f"/Items?IncludeItemTypes={include_type}&IsPlayed=false&Recursive=true&Limit=50&Fields=Genres,Overview,RunTimeTicks"
        if genre:
            path += f"&Genres={urllib.parse.quote(genre)}"

        data = jf_request(path)
        if "error" in data:
            return data["error"]

        items = data.get("Items", [])
        if not items:
            return f"No unwatched {media_type} found" + (f" in genre '{genre}'" if genre else "") + "."

        pick = random.choice(items)
        name = pick.get("Name", "Unknown")
        year = pick.get("ProductionYear", "")
        genres = ", ".join(pick.get("Genres", [])[:3])
        overview = (pick.get("Overview") or "No description")[:200]
        runtime = ""
        ticks = pick.get("RunTimeTicks")
        if ticks:
            mins = ticks // 600000000
            runtime = f"\nRuntime: {mins} min"

        return f"How about: *{name}* ({year})\nGenre: {genres}{runtime}\n\n{overview}"


    def media_finished(inp):
        data = jf_request("/Items?IncludeItemTypes=Series&IsPlayed=true&Recursive=true&Fields=Path&Limit=50")
        if "error" in data:
            return data["error"]

        items = data.get("Items", [])
        if not items:
            return "No fully watched shows found."

        lines = ["Fully watched shows:"]
        for item in items:
            name = item.get("Name", "Unknown")
            item_id = item.get("Id", "")
            # Get size from item
            size_data = jf_request(f"/Items/{item_id}?Fields=Size,Path")
            size = ""
            if not isinstance(size_data, dict) or "error" not in size_data:
                size = format_size(size_data.get("Size", 0))
            lines.append(f"- {name} | {size} | ID: {item_id}")
        return "\n".join(lines)


    def media_cleanup(inp):
        item_id = inp.get("item_id", "")
        if not item_id:
            return "Error: item_id is required"

        # Get item name first
        item_data = jf_request(f"/Items/{item_id}")
        if isinstance(item_data, dict) and "error" in item_data:
            return item_data["error"]

        name = item_data.get("Name", "Unknown")
        result = jf_request(f"/Items/{item_id}", method="DELETE")
        if isinstance(result, dict) and "error" in result:
            return result["error"]
        return f"Deleted: {name}"


    def media_stats(inp):
        movies = jf_request("/Items/Counts")
        if "error" in movies:
            return movies["error"]

        movie_count = movies.get("MovieCount", 0)
        series_count = movies.get("SeriesCount", 0)
        episode_count = movies.get("EpisodeCount", 0)

        # Get unwatched counts
        unwatched_movies = jf_request("/Items?IncludeItemTypes=Movie&IsPlayed=false&Recursive=true&Limit=0")
        unwatched_series = jf_request("/Items?IncludeItemTypes=Series&IsPlayed=false&Recursive=true&Limit=0")

        um = unwatched_movies.get("TotalRecordCount", "?") if not isinstance(unwatched_movies, str) else "?"
        us = unwatched_series.get("TotalRecordCount", "?") if not isinstance(unwatched_series, str) else "?"

        return f"Library stats:\nMovies: {movie_count} total ({um} unwatched)\nShows: {series_count} total ({us} unwatched)\nEpisodes: {episode_count}"


    TOOLS = {
        "media_unwatched": media_unwatched,
        "media_suggest": media_suggest,
        "media_finished": media_finished,
        "media_cleanup": media_cleanup,
        "media_stats": media_stats,
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

  mediaSkill = pkgs.runCommand "homelab-media-skill" {} ''
    mkdir -p $out/src
    cp ${mediaSkillToml} $out/skill.toml
    cp ${mediaSkillPy} $out/src/main.py
  '';

  # --- homelab-paperless skill (Phase 4) ---
  plCfg = cfg.paperless;
  paperlessApiUrl = "http://127.0.0.1:${toString plCfg.port}";

  paperlessSkillToml = pkgs.writeText "homelab-paperless-skill.toml" ''
    [skill]
    name = "homelab-paperless"
    version = "0.1.0"
    description = "Paperless-ngx document search and browsing"
    author = "bmasi"
    tags = ["homelab", "documents", "paperless"]

    [runtime]
    type = "python"
    entry = "src/main.py"

    [[tools.provided]]
    name = "paperless_search"
    description = "Full-text search across all documents. Use when user asks to find a document, bill, receipt, letter, etc."
    input_schema = { type = "object", properties = { query = { type = "string", description = "Search query, e.g. 'electricity bill january'" } }, required = ["query"] }

    [[tools.provided]]
    name = "paperless_recent"
    description = "List recently added documents. Use when user asks what was scanned recently."
    input_schema = { type = "object", properties = { limit = { type = "integer", description = "Number of results (default: 5, max: 20)" } } }

    [[tools.provided]]
    name = "paperless_tags"
    description = "List all tags with document counts. Use when user asks about document categories or tags."
    input_schema = { type = "object", properties = {} }

    [[tools.provided]]
    name = "paperless_info"
    description = "Get full details of a specific document by ID — title, date, correspondent, tags, content preview."
    input_schema = { type = "object", properties = { id = { type = "integer", description = "Document ID" } }, required = ["id"] }
  '';

  paperlessSkillPy = pkgs.writeText "homelab-paperless-main.py" ''
    #!/usr/bin/env python3
    """homelab-paperless skill — Paperless-ngx document search for OpenFang."""
    import json
    import sys
    import urllib.request
    import urllib.error
    import urllib.parse

    API_URL = "${paperlessApiUrl}/api"
    API_KEY_FILE = "${plCfg.apiKeyFile}"


    def get_api_key():
        try:
            with open(API_KEY_FILE) as f:
                return f.read().strip()
        except Exception:
            return None


    def pl_request(path):
        api_key = get_api_key()
        if not api_key:
            return {"error": "Cannot read Paperless API key"}
        url = f"{API_URL}{path}"
        req = urllib.request.Request(url)
        req.add_header("Authorization", f"Token {api_key}")
        req.add_header("Accept", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            return {"error": f"HTTP {e.code}: {e.reason}"}
        except Exception as e:
            return {"error": str(e)}


    def format_doc(doc):
        title = doc.get("title", "Untitled")
        doc_id = doc.get("id", "?")
        created = (doc.get("created") or "")[:10]
        correspondent = doc.get("correspondent_name") or doc.get("correspondent") or ""
        tags = ", ".join(doc.get("tag_names", []) or [str(t) for t in doc.get("tags", [])])
        line = f"- [{doc_id}] {title}"
        if created:
            line += f" ({created})"
        if correspondent:
            line += f" — {correspondent}"
        if tags:
            line += f" [{tags}]"
        return line


    def paperless_search(inp):
        query = inp.get("query", "")
        if not query:
            return "Error: query is required"
        encoded = urllib.parse.quote(query)
        data = pl_request(f"/documents/?query={encoded}&ordering=-created&page_size=10")
        if "error" in data:
            return data["error"]

        results = data.get("results", [])
        if not results:
            return f"No documents found for '{query}'."

        total = data.get("count", len(results))
        lines = [f"Found {total} document(s) for '{query}':"]
        for doc in results:
            lines.append(format_doc(doc))
        return "\n".join(lines)


    def paperless_recent(inp):
        limit = min(int(inp.get("limit", 5)), 20)
        data = pl_request(f"/documents/?ordering=-added&page_size={limit}")
        if "error" in data:
            return data["error"]

        results = data.get("results", [])
        if not results:
            return "No documents found."

        lines = [f"Last {len(results)} documents:"]
        for doc in results:
            lines.append(format_doc(doc))
        return "\n".join(lines)


    def paperless_tags(inp):
        data = pl_request("/tags/?page_size=100")
        if "error" in data:
            return data["error"]

        tags = data.get("results", [])
        if not tags:
            return "No tags found."

        lines = ["Tags:"]
        for tag in sorted(tags, key=lambda t: t.get("document_count", 0), reverse=True):
            name = tag.get("name", "?")
            count = tag.get("document_count", 0)
            lines.append(f"- {name} ({count} docs)")
        return "\n".join(lines)


    def paperless_info(inp):
        doc_id = inp.get("id")
        if not doc_id:
            return "Error: document id is required"
        data = pl_request(f"/documents/{doc_id}/")
        if "error" in data:
            return data["error"]

        title = data.get("title", "Untitled")
        created = (data.get("created") or "")[:10]
        added = (data.get("added") or "")[:10]
        correspondent = data.get("correspondent_name") or "None"
        doc_type = data.get("document_type_name") or "None"
        tags = ", ".join(data.get("tag_names", [])) or "None"
        content = (data.get("content") or "")[:500]

        return (
            f"*{title}*\n"
            f"ID: {doc_id}\n"
            f"Created: {created} | Added: {added}\n"
            f"Correspondent: {correspondent}\n"
            f"Type: {doc_type}\n"
            f"Tags: {tags}\n"
            f"\nContent preview:\n{content}"
        )


    TOOLS = {
        "paperless_search": paperless_search,
        "paperless_recent": paperless_recent,
        "paperless_tags": paperless_tags,
        "paperless_info": paperless_info,
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

  paperlessSkill = pkgs.runCommand "homelab-paperless-skill" {} ''
    mkdir -p $out/src
    cp ${paperlessSkillToml} $out/skill.toml
    cp ${paperlessSkillPy} $out/src/main.py
  '';

  # --- Shell wrapper scripts for shell_exec (avoids pipe/metachar issues) ---

  # Paperless CLI wrapper
  paperlessToolScript = pkgs.writeShellScript "paperless-tool" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.python3}/bin:$PATH
    SKILL_PY="${skillsDir}/homelab-paperless/src/main.py"
    CMD="$1"
    ARG="$2"
    case "$CMD" in
      search)
        echo "{\"tool\":\"paperless_search\",\"input\":{\"query\":\"$ARG\"}}" | python3 "$SKILL_PY"
        ;;
      recent)
        echo "{\"tool\":\"paperless_recent\",\"input\":{\"limit\":''${ARG:-5}}}" | python3 "$SKILL_PY"
        ;;
      tags)
        echo "{\"tool\":\"paperless_tags\",\"input\":{}}" | python3 "$SKILL_PY"
        ;;
      info)
        echo "{\"tool\":\"paperless_info\",\"input\":{\"id\":$ARG}}" | python3 "$SKILL_PY"
        ;;
      *)
        echo "Commands: search QUERY, recent [N], tags, info ID"
        ;;
    esac
  '';

  # Server CLI wrapper
  serverToolScript = pkgs.writeShellScript "server-tool" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.python3}/bin:$PATH
    SKILL_PY="${skillsDir}/homelab-server/src/main.py"
    CMD="$1"
    ARG="$2"
    case "$CMD" in
      errors)
        echo "{\"tool\":\"server_errors\",\"input\":{\"timeframe\":\"''${ARG:-1h}\"}}" | python3 "$SKILL_PY"
        ;;
      service)
        echo "{\"tool\":\"server_service_logs\",\"input\":{\"service\":\"$ARG\"}}" | python3 "$SKILL_PY"
        ;;
      failed)
        echo "{\"tool\":\"server_failed_units\",\"input\":{}}" | python3 "$SKILL_PY"
        ;;
      storage)
        echo "{\"tool\":\"server_storage\",\"input\":{}}" | python3 "$SKILL_PY"
        ;;
      zpool)
        echo "{\"tool\":\"server_zpool_status\",\"input\":{}}" | python3 "$SKILL_PY"
        ;;
      snapraid)
        echo "{\"tool\":\"server_snapraid_status\",\"input\":{}}" | python3 "$SKILL_PY"
        ;;
      snapraid-diff)
        echo "{\"tool\":\"server_snapraid_diff\",\"input\":{}}" | python3 "$SKILL_PY"
        ;;
      auth)
        echo "{\"tool\":\"server_auth_events\",\"input\":{\"timeframe\":\"''${ARG:-1h}\"}}" | python3 "$SKILL_PY"
        ;;
      backup)
        echo "{\"tool\":\"server_backup_status\",\"input\":{}}" | python3 "$SKILL_PY"
        ;;
      tunnel)
        echo "{\"tool\":\"server_tunnel_status\",\"input\":{}}" | python3 "$SKILL_PY"
        ;;
      *)
        echo "Commands: errors [1h|6h|24h], service NAME, failed, storage, zpool, snapraid, snapraid-diff, auth [1h|6h|24h], backup, tunnel"
        ;;
    esac
  '';

  # Media CLI wrapper
  mediaToolScript = pkgs.writeShellScript "media-tool" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.python3}/bin:$PATH
    SKILL_PY="${skillsDir}/homelab-media/src/main.py"
    CMD="$1"
    ARG="$2"
    case "$CMD" in
      unwatched)
        echo "{\"tool\":\"media_unwatched\",\"input\":{\"type\":\"''${ARG:-movies}\"}}" | python3 "$SKILL_PY"
        ;;
      suggest)
        echo "{\"tool\":\"media_suggest\",\"input\":{\"type\":\"''${ARG:-movies}\"}}" | python3 "$SKILL_PY"
        ;;
      finished)
        echo "{\"tool\":\"media_finished\",\"input\":{}}" | python3 "$SKILL_PY"
        ;;
      cleanup)
        echo "{\"tool\":\"media_cleanup\",\"input\":{\"item_id\":\"$ARG\"}}" | python3 "$SKILL_PY"
        ;;
      stats)
        echo "{\"tool\":\"media_stats\",\"input\":{}}" | python3 "$SKILL_PY"
        ;;
      *)
        echo "Commands: unwatched [movies|shows], suggest [movies|shows], finished, cleanup ITEM_ID, stats"
        ;;
    esac
  '';

  # All skills to install
  skills = [
    { name = "ping-test"; path = pingTestSkill; }
    { name = "homelab-server"; path = serverSkill; }
  ] ++ lib.optionals (cfg.jellyfin.enable) [
    { name = "homelab-media"; path = mediaSkill; }
  ] ++ lib.optionals (cfg.paperless.enable) [
    { name = "homelab-paperless"; path = paperlessSkill; }
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

    # Shell wrapper scripts for shell_exec access
    systemd.tmpfiles.rules = [
      "L+ /persist/openfang/scripts/server-tool.sh - - - - ${serverToolScript}"
      "L+ /persist/openfang/scripts/media-tool.sh - - - - ${mediaToolScript}"
      "L+ /persist/openfang/scripts/paperless-tool.sh - - - - ${paperlessToolScript}"
    ];

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
