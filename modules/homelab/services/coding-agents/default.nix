# Autonomous coding agents — Claude Code on git worktrees with self-review, PRs, and live previews
{
  config,
  lib,
  pkgs,
  ...
}:
let
  homelab = config.homelab;
  cfg = homelab.services.coding-agents;
  dbUrl = "postgresql://openfang@127.0.0.1:5432/openfang";
  waNotify = "/persist/openfang/scripts/wa-notify.sh";
  claudeBin = "${cfg.workspaceDir}/node_modules/.bin/claude";
  promptFile = "/etc/coding-agents/agent-prompt.txt";

  # --- Scripts ---

  runScript = pkgs.writeShellScript "coding-agent-run" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.git}/bin:${pkgs.jq}/bin:${pkgs.postgresql}/bin:${pkgs.systemd}/bin:${pkgs.util-linux}/bin:$PATH
    DB="${dbUrl}"
    WORKSPACE="${cfg.workspaceDir}"

    usage() {
      echo "Usage: coding-agent-run --repo OWNER/REPO --task \"description\" [--branch BASE_BRANCH]"
      exit 1
    }

    REPO="" TASK="" BASE_BRANCH="main"
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --task) TASK="$2"; shift 2 ;;
        --branch) BASE_BRANCH="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -z "$REPO" ] || [ -z "$TASK" ] && usage

    # Check concurrent limit
    RUNNING=$(psql -t -A -c "SELECT COUNT(*) FROM coding_tasks WHERE status IN ('queued','running','reviewing','iterating','pushing');" "$DB" 2>/dev/null || echo "0")
    if [ "$RUNNING" -ge ${toString cfg.maxConcurrent} ]; then
      echo '{"error": "concurrent limit reached ('"$RUNNING"'/${toString cfg.maxConcurrent})"}'
      exit 1
    fi

    # Generate task ID
    TASK_ID="$(date +%Y%m%d-%H%M%S)-$(head -c 4 /dev/urandom | xxd -p)"

    # Clone repo if not exists
    REPO_DIR="$WORKSPACE/repos/$REPO"
    if [ ! -d "$REPO_DIR/.git" ]; then
      echo "[agent] Cloning $REPO..."
      mkdir -p "$(dirname "$REPO_DIR")"
      GITHUB_TOKEN=$(cat ${cfg.githubTokenFile})
      git clone "https://x-access-token:''${GITHUB_TOKEN}@github.com/$REPO.git" "$REPO_DIR"
      cd "$REPO_DIR"
      git config user.name "Coding Agent"
      git config user.email "agent@demasi.dev"
      # Reset URL to not store token on disk
      git remote set-url origin "https://github.com/$REPO.git"
    fi

    # Fetch latest
    cd "$REPO_DIR"
    git fetch origin 2>/dev/null

    # Create worktree
    TASK_DIR="$WORKSPACE/tasks/$TASK_ID"
    WORKTREE_DIR="$TASK_DIR/worktree"
    BRANCH="agent/$TASK_ID"
    mkdir -p "$TASK_DIR"

    git worktree add "$WORKTREE_DIR" -b "$BRANCH" "origin/$BASE_BRANCH" 2>&1

    # Allocate preview port
    NEXT_PORT=$(psql -t -A -c "SELECT COALESCE(MAX(preview_port), ${toString (cfg.previewBasePort - 1)}) + 1 FROM coding_tasks WHERE preview_port IS NOT NULL;" "$DB" 2>/dev/null)
    [ -z "$NEXT_PORT" ] && NEXT_PORT=${toString cfg.previewBasePort}

    # Write task.json
    ${pkgs.jq}/bin/jq -n \
      --arg id "$TASK_ID" \
      --arg repo "$REPO" \
      --arg base "$BASE_BRANCH" \
      --arg branch "$BRANCH" \
      --arg task "$TASK" \
      --arg port "$NEXT_PORT" \
      '{id: $id, repo: $repo, base_branch: $base, branch: $branch, task: $task, preview_port: ($port | tonumber)}' \
      > "$TASK_DIR/task.json"

    # Insert DB record
    SAFE_TASK=$(echo "$TASK" | sed "s/'/''/g")
    psql -c "INSERT INTO coding_tasks (id, repo, branch, base_branch, task_description, status, preview_port, log_file) VALUES ('$TASK_ID', '$REPO', '$BRANCH', '$BASE_BRANCH', '$SAFE_TASK', 'queued', $NEXT_PORT, '$TASK_DIR/agent.log');" "$DB"

    # Start background service
    systemctl start "coding-agent@$TASK_ID.service" 2>/dev/null &

    # Return task info
    ${pkgs.jq}/bin/jq -n \
      --arg id "$TASK_ID" \
      --arg branch "$BRANCH" \
      --arg port "$NEXT_PORT" \
      '{task_id: $id, status: "queued", branch: $branch, preview_port: ($port | tonumber)}'
  '';

  workerScript = pkgs.writeShellScript "coding-agent-worker" ''
    set -euo pipefail
    export PATH=${pkgs.coreutils}/bin:${pkgs.git}/bin:${pkgs.jq}/bin:${pkgs.postgresql}/bin:${pkgs.nodejs_22}/bin:${pkgs.gh}/bin:${pkgs.gnugrep}/bin:${pkgs.gnused}/bin:${pkgs.findutils}/bin:${pkgs.procps}/bin:$PATH

    TASK_ID="$1"
    WORKSPACE="${cfg.workspaceDir}"
    DB="${dbUrl}"
    TASK_DIR="$WORKSPACE/tasks/$TASK_ID"
    CLAUDE="${claudeBin}"
    PROMPT_FILE="${promptFile}"

    # Error handler
    on_error() {
      local err_msg
      err_msg=$(tail -5 "$TASK_DIR/agent.log" 2>/dev/null | head -c 500 || echo "unknown error")
      err_msg=$(echo "$err_msg" | sed "s/'/''/g")
      psql -c "UPDATE coding_tasks SET status='failed', error='$err_msg', updated_at=NOW() WHERE id='$TASK_ID';" "$DB" 2>/dev/null || true
      ${waNotify} "" "$(printf '❌ *Coding Agent Failed*\nTask: %s\nError: %s' "$TASK_ID" "$(tail -3 "$TASK_DIR/agent.log" 2>/dev/null | head -c 200)")" 2>/dev/null || true
    }
    trap on_error ERR

    # Read task config
    TASK_JSON=$(cat "$TASK_DIR/task.json")
    REPO=$(echo "$TASK_JSON" | jq -r '.repo')
    BRANCH=$(echo "$TASK_JSON" | jq -r '.branch')
    BASE_BRANCH=$(echo "$TASK_JSON" | jq -r '.base_branch')
    TASK_DESC=$(echo "$TASK_JSON" | jq -r '.task')
    PREVIEW_PORT=$(echo "$TASK_JSON" | jq -r '.preview_port')

    WORKTREE_DIR="$TASK_DIR/worktree"
    REPO_DIR="$WORKSPACE/repos/$REPO"

    # Set up auth
    export GITHUB_TOKEN=$(cat ${cfg.githubTokenFile})
    export GH_TOKEN="$GITHUB_TOKEN"
    export CLAUDE_CONFIG_DIR="${cfg.workspaceDir}/.claude"
    export HOME="${cfg.workspaceDir}"

    cd "$WORKTREE_DIR"

    # Update DB status
    psql -c "UPDATE coding_tasks SET status='running', updated_at=NOW() WHERE id='$TASK_ID';" "$DB"

    echo "[agent] Task $TASK_ID: $TASK_DESC"
    echo "[agent] Repo: $REPO | Branch: $BRANCH | Base: $BASE_BRANCH"
    echo "[agent] Starting implementation..."

    # Phase 1: Implement
    IMPLEMENT_PROMPT="Your task: $TASK_DESC

After completing the implementation, write a file called .agent-result.json at the repository root with this exact JSON structure:
{\"score\": <1-10>, \"summary\": \"brief description of what you did\", \"files_changed\": [\"list of files\"], \"issues\": [\"any remaining issues\"]}

Score guide: 9-10 production-ready, 7-8 good with minor issues, 5-6 functional but needs work, 1-4 incomplete."

    $CLAUDE -p "$IMPLEMENT_PROMPT" \
      --dangerously-skip-permissions \
      --model ${cfg.model} \
      --max-turns ${toString cfg.maxTurns} \
      --system-prompt-file "$PROMPT_FILE" \
      --output-format json \
      2>&1 || true

    # Parse result
    SCORE=0
    SUMMARY="No result produced"
    ISSUES=""
    if [ -f ".agent-result.json" ]; then
      SCORE=$(jq -r '.score // 0' .agent-result.json 2>/dev/null || echo "0")
      SUMMARY=$(jq -r '.summary // "No summary"' .agent-result.json 2>/dev/null || echo "No summary")
      ISSUES=$(jq -r '.issues // [] | join("; ")' .agent-result.json 2>/dev/null || echo "")
    fi

    echo "[agent] Phase 1 complete. Score: $SCORE/10"

    # Iteration loop
    ITERATIONS=0
    while [ "$SCORE" -lt ${toString cfg.scoreThreshold} ] && [ "$ITERATIONS" -lt ${toString cfg.maxIterations} ]; do
      ITERATIONS=$((ITERATIONS + 1))
      psql -c "UPDATE coding_tasks SET status='iterating', iterations=$ITERATIONS, score=$SCORE, updated_at=NOW() WHERE id='$TASK_ID';" "$DB"

      echo "[agent] Score $SCORE < ${toString cfg.scoreThreshold}, iterating ($ITERATIONS/${toString cfg.maxIterations})..."

      IMPROVE_PROMPT="Your previous implementation scored $SCORE/10. Issues found: $ISSUES

Review all your changes, fix the issues, improve the code quality, and re-score. Update .agent-result.json with the new score."

      $CLAUDE -p "$IMPROVE_PROMPT" \
        --dangerously-skip-permissions \
        --model ${cfg.model} \
        --max-turns $((${toString cfg.maxTurns} / 2)) \
        --system-prompt-file "$PROMPT_FILE" \
        --output-format json \
        2>&1 || true

      if [ -f ".agent-result.json" ]; then
        SCORE=$(jq -r '.score // 0' .agent-result.json 2>/dev/null || echo "0")
        SUMMARY=$(jq -r '.summary // "No summary"' .agent-result.json 2>/dev/null || echo "No summary")
        ISSUES=$(jq -r '.issues // [] | join("; ")' .agent-result.json 2>/dev/null || echo "")
      fi

      echo "[agent] Iteration $ITERATIONS complete. Score: $SCORE/10"
    done

    # Check for actual changes
    if [ -z "$(git diff --name-only)" ] && [ -z "$(git diff --staged --name-only)" ] && [ -z "$(git ls-files --others --exclude-standard)" ]; then
      psql -c "UPDATE coding_tasks SET status='failed', error='No changes produced', score=$SCORE, iterations=$ITERATIONS, updated_at=NOW() WHERE id='$TASK_ID';" "$DB"
      ${waNotify} "" "$(printf '⚠️ *Coding Agent*: Task %s finished but produced no changes\nScore: %s/10' "$TASK_ID" "$SCORE")"
      exit 0
    fi

    # Commit and push
    psql -c "UPDATE coding_tasks SET status='pushing', score=$SCORE, iterations=$ITERATIONS, updated_at=NOW() WHERE id='$TASK_ID';" "$DB"

    git add -A
    # Remove agent artifacts from staging
    git reset HEAD .agent-result.json 2>/dev/null || true
    rm -f .agent-result.json

    SAFE_SUMMARY=$(echo "$SUMMARY" | head -c 200)
    git commit -m "$(cat <<COMMITEOF
$SAFE_SUMMARY

Task: $TASK_DESC
Agent: $TASK_ID | Score: $SCORE/10 | Iterations: $ITERATIONS
COMMITEOF
    )"

    # Set remote URL with token for push, then reset
    cd "$REPO_DIR"
    git remote set-url origin "https://x-access-token:''${GITHUB_TOKEN}@github.com/$REPO.git"
    cd "$WORKTREE_DIR"
    git push origin "$BRANCH" 2>&1
    cd "$REPO_DIR"
    git remote set-url origin "https://github.com/$REPO.git"
    cd "$WORKTREE_DIR"

    # Create PR
    PR_TITLE=$(echo "$SAFE_SUMMARY" | head -c 70)
    PR_BODY="## Summary
$SUMMARY

## Agent Details
- Task ID: \`$TASK_ID\`
- Score: $SCORE/10
- Iterations: $ITERATIONS
- Model: ${cfg.model}

## Task
$TASK_DESC

---
_Autonomous coding agent — self-reviewed and scored_"

    PR_URL=$(gh pr create \
      --repo "$REPO" \
      --base "$BASE_BRANCH" \
      --head "$BRANCH" \
      --title "$PR_TITLE" \
      --body "$PR_BODY" 2>&1) || true

    PR_NUMBER=""
    if [ -n "$PR_URL" ]; then
      PR_NUMBER=$(echo "$PR_URL" | grep -oP '/pull/\K[0-9]+' || echo "")
    fi

    # Start dev server (detect from package.json)
    PREVIEW_URL=""
    DEV_PID=""
    if [ -f "package.json" ]; then
      # Install dependencies
      if [ -f "package-lock.json" ] || [ -f "yarn.lock" ] || [ -f "pnpm-lock.yaml" ]; then
        npm install --legacy-peer-deps 2>&1 || true
      fi

      # Detect dev command
      DEV_CMD=$(jq -r '.scripts.dev // .scripts.start // empty' package.json 2>/dev/null)
      if [ -n "$DEV_CMD" ]; then
        echo "[agent] Starting dev server on port $PREVIEW_PORT..."
        PORT=$PREVIEW_PORT nohup npm run dev -- --port "$PREVIEW_PORT" > "$TASK_DIR/dev-server.log" 2>&1 &
        DEV_PID=$!
        echo "$DEV_PID" > "$TASK_DIR/dev-server.pid"
        PREVIEW_URL="http://sweet:$PREVIEW_PORT"
        echo "[agent] Dev server PID $DEV_PID on $PREVIEW_URL"
      fi
    fi

    # Update DB
    SAFE_PR_URL=$(echo "$PR_URL" | sed "s/'/''/g" | head -1)
    psql -c "UPDATE coding_tasks SET status='done', score=$SCORE, iterations=$ITERATIONS, pr_url='$SAFE_PR_URL', pr_number=$(echo "''${PR_NUMBER:-0}"), preview_pid=$(echo "''${DEV_PID:-0}"), completed_at=NOW(), updated_at=NOW() WHERE id='$TASK_ID';" "$DB"

    # Notify via WhatsApp
    NOTIFY_MSG="$(printf '🤖 *Coding Agent Done*\n\n*Task*: %s\n*Repo*: %s\n*Score*: %s/10 (%s iterations)\n*PR*: %s' "$TASK_ID" "$REPO" "$SCORE" "$ITERATIONS" "''${PR_URL:-no PR}")"
    if [ -n "$PREVIEW_URL" ]; then
      NOTIFY_MSG="$NOTIFY_MSG$(printf '\n*Preview*: %s' "$PREVIEW_URL")"
    fi
    ${waNotify} "" "$NOTIFY_MSG"

    echo "[agent] Done! PR: $PR_URL"
  '';

  workspaceScript = pkgs.writeShellScript "coding-workspace" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.git}/bin:${pkgs.jq}/bin:${pkgs.findutils}/bin:$PATH
    WORKSPACE="${cfg.workspaceDir}"

    case "''${1:-}" in
      clone)
        REPO="$2"
        [ -z "$REPO" ] && echo "Usage: coding-workspace clone OWNER/REPO" && exit 1
        REPO_DIR="$WORKSPACE/repos/$REPO"
        if [ -d "$REPO_DIR/.git" ]; then
          echo "Already cloned: $REPO"
          exit 0
        fi
        mkdir -p "$(dirname "$REPO_DIR")"
        GITHUB_TOKEN=$(cat ${cfg.githubTokenFile})
        git clone "https://x-access-token:''${GITHUB_TOKEN}@github.com/$REPO.git" "$REPO_DIR"
        cd "$REPO_DIR"
        git config user.name "Coding Agent"
        git config user.email "agent@demasi.dev"
        git remote set-url origin "https://github.com/$REPO.git"
        echo "Cloned: $REPO"
        ;;
      list)
        echo "=== Cloned Repos ==="
        find "$WORKSPACE/repos" -name ".git" -type d 2>/dev/null | while read gitdir; do
          repo_path=$(dirname "$gitdir")
          rel_path=$(echo "$repo_path" | sed "s|$WORKSPACE/repos/||")
          last_fetch=$(stat -c %Y "$gitdir/FETCH_HEAD" 2>/dev/null || echo "0")
          if [ "$last_fetch" != "0" ]; then
            last_fetch_date=$(date -d @"$last_fetch" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown")
          else
            last_fetch_date="never"
          fi
          echo "  $rel_path (last fetch: $last_fetch_date)"
        done
        ;;
      update)
        REPO="''${2:-}"
        if [ -n "$REPO" ]; then
          cd "$WORKSPACE/repos/$REPO" && git fetch --all --prune 2>&1
          echo "Updated: $REPO"
        else
          find "$WORKSPACE/repos" -name ".git" -type d 2>/dev/null | while read gitdir; do
            repo_path=$(dirname "$gitdir")
            rel_path=$(echo "$repo_path" | sed "s|$WORKSPACE/repos/||")
            cd "$repo_path" && git fetch --all --prune 2>&1
            echo "Updated: $rel_path"
          done
        fi
        ;;
      remove)
        REPO="$2"
        [ -z "$REPO" ] && echo "Usage: coding-workspace remove OWNER/REPO" && exit 1
        REPO_DIR="$WORKSPACE/repos/$REPO"
        [ ! -d "$REPO_DIR" ] && echo "Not found: $REPO" && exit 1
        # Check for active worktrees
        ACTIVE=$(cd "$REPO_DIR" && git worktree list --porcelain | grep -c "worktree" || echo "1")
        if [ "$ACTIVE" -gt 1 ]; then
          echo "Cannot remove: $REPO has active worktrees"
          cd "$REPO_DIR" && git worktree list
          exit 1
        fi
        rm -rf "$REPO_DIR"
        echo "Removed: $REPO"
        ;;
      *)
        echo "Usage: coding-workspace {clone|list|update|remove} [OWNER/REPO]"
        ;;
    esac
  '';

  tasksScript = pkgs.writeShellScript "coding-tasks" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.jq}/bin:${pkgs.postgresql}/bin:${pkgs.gh}/bin:${pkgs.gnugrep}/bin:${pkgs.procps}/bin:${pkgs.systemd}/bin:$PATH
    DB="${dbUrl}"
    WORKSPACE="${cfg.workspaceDir}"

    case "''${1:-}" in
      list)
        STATUS_FILTER="''${2:-}"
        if [ -n "$STATUS_FILTER" ] && [ "$STATUS_FILTER" != "--status" ]; then
          QUERY="SELECT json_agg(json_build_object('id',id,'repo',repo,'status',status,'score',score,'task',substring(task_description for 80),'pr_url',pr_url,'created_at',created_at)) FROM coding_tasks WHERE status='$STATUS_FILTER' ORDER BY created_at DESC;"
        elif [ -n "''${3:-}" ]; then
          QUERY="SELECT json_agg(json_build_object('id',id,'repo',repo,'status',status,'score',score,'task',substring(task_description for 80),'pr_url',pr_url,'created_at',created_at)) FROM coding_tasks WHERE status='$3' ORDER BY created_at DESC;"
        else
          QUERY="SELECT json_agg(json_build_object('id',id,'repo',repo,'status',status,'score',score,'task',substring(task_description for 80),'pr_url',pr_url,'created_at',created_at)) FROM coding_tasks ORDER BY created_at DESC LIMIT 20;"
        fi
        RESULT=$(psql -t -A -c "$QUERY" "$DB" 2>/dev/null)
        if [ "$RESULT" = "" ] || [ "$RESULT" = "null" ]; then
          echo "No tasks found"
        else
          echo "$RESULT" | jq '.' 2>/dev/null || echo "$RESULT"
        fi
        ;;
      status)
        TASK_ID="$2"
        [ -z "$TASK_ID" ] && echo "Usage: coding-tasks status TASK_ID" && exit 1
        psql -t -A -c "SELECT json_build_object('id',id,'repo',repo,'branch',branch,'status',status,'score',score,'iterations',iterations,'task',task_description,'pr_url',pr_url,'pr_number',pr_number,'preview_port',preview_port,'error',error,'created_at',created_at,'completed_at',completed_at) FROM coding_tasks WHERE id='$TASK_ID';" "$DB" 2>/dev/null | jq '.' 2>/dev/null
        ;;
      logs)
        TASK_ID="$2"
        [ -z "$TASK_ID" ] && echo "Usage: coding-tasks logs TASK_ID [--tail N]" && exit 1
        LOG_FILE="$WORKSPACE/tasks/$TASK_ID/agent.log"
        TAIL_N="''${4:-50}"
        if [ "''${3:-}" = "--tail" ]; then
          tail -n "$TAIL_N" "$LOG_FILE" 2>/dev/null || echo "No log file found"
        else
          tail -n 50 "$LOG_FILE" 2>/dev/null || echo "No log file found"
        fi
        ;;
      cancel)
        TASK_ID="$2"
        [ -z "$TASK_ID" ] && echo "Usage: coding-tasks cancel TASK_ID" && exit 1
        systemctl stop "coding-agent@$TASK_ID.service" 2>/dev/null || true
        psql -c "UPDATE coding_tasks SET status='cancelled', updated_at=NOW() WHERE id='$TASK_ID' AND status NOT IN ('done','failed','cancelled');" "$DB" 2>/dev/null
        echo "Cancelled: $TASK_ID"
        ;;
      pr-info)
        TASK_ID="$2"
        [ -z "$TASK_ID" ] && echo "Usage: coding-tasks pr-info TASK_ID" && exit 1
        TASK_DATA=$(psql -t -A -c "SELECT repo || ' ' || COALESCE(pr_number::text, '') FROM coding_tasks WHERE id='$TASK_ID';" "$DB" 2>/dev/null)
        REPO=$(echo "$TASK_DATA" | cut -d' ' -f1)
        PR_NUM=$(echo "$TASK_DATA" | cut -d' ' -f2)
        if [ -n "$PR_NUM" ] && [ "$PR_NUM" != "0" ]; then
          export GH_TOKEN=$(cat ${cfg.githubTokenFile})
          gh pr view "$PR_NUM" --repo "$REPO" --json title,state,reviews,checks,mergeable,additions,deletions,changedFiles 2>/dev/null | jq '.' 2>/dev/null
        else
          echo "No PR found for task $TASK_ID"
        fi
        ;;
      preview)
        TASK_ID="$2"
        [ -z "$TASK_ID" ] && echo "Usage: coding-tasks preview TASK_ID" && exit 1
        PORT=$(psql -t -A -c "SELECT preview_port FROM coding_tasks WHERE id='$TASK_ID';" "$DB" 2>/dev/null)
        PID_FILE="$WORKSPACE/tasks/$TASK_ID/dev-server.pid"
        if [ -f "$PID_FILE" ]; then
          PID=$(cat "$PID_FILE")
          if kill -0 "$PID" 2>/dev/null; then
            echo "Preview running: http://sweet:$PORT (PID: $PID)"
          else
            echo "Preview stopped (PID $PID not running). Port was: $PORT"
          fi
        else
          echo "No preview server for task $TASK_ID"
        fi
        ;;
      ports)
        echo "=== Running Previews ==="
        psql -t -A -c "SELECT id || ' | ' || repo || ' | port:' || preview_port || ' | ' || status FROM coding_tasks WHERE preview_port IS NOT NULL AND status = 'done' ORDER BY created_at DESC;" "$DB" 2>/dev/null
        ;;
      stop-preview)
        TASK_ID="$2"
        [ -z "$TASK_ID" ] && echo "Usage: coding-tasks stop-preview TASK_ID" && exit 1
        PID_FILE="$WORKSPACE/tasks/$TASK_ID/dev-server.pid"
        if [ -f "$PID_FILE" ]; then
          PID=$(cat "$PID_FILE")
          kill "$PID" 2>/dev/null && echo "Stopped preview (PID $PID)" || echo "Process already stopped"
          rm -f "$PID_FILE"
        else
          echo "No preview server for task $TASK_ID"
        fi
        ;;
      *)
        echo "Usage: coding-tasks {list|status|logs|cancel|pr-info|preview|ports|stop-preview} [ARGS]"
        ;;
    esac
  '';

  cleanupScript = pkgs.writeShellScript "coding-agents-cleanup" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.git}/bin:${pkgs.postgresql}/bin:${pkgs.findutils}/bin:${pkgs.procps}/bin:$PATH
    DB="${dbUrl}"
    WORKSPACE="${cfg.workspaceDir}"
    RETENTION=${toString cfg.retentionDays}

    echo "[cleanup] Cleaning tasks older than $RETENTION days..."

    # Get old completed tasks
    OLD_TASKS=$(psql -t -A -c "SELECT id || '|' || repo || '|' || branch FROM coding_tasks WHERE status IN ('done','failed','cancelled') AND completed_at < NOW() - INTERVAL '$RETENTION days';" "$DB" 2>/dev/null)

    for entry in $OLD_TASKS; do
      TASK_ID=$(echo "$entry" | cut -d'|' -f1)
      REPO=$(echo "$entry" | cut -d'|' -f2)
      BRANCH=$(echo "$entry" | cut -d'|' -f3)
      REPO_DIR="$WORKSPACE/repos/$REPO"
      TASK_DIR="$WORKSPACE/tasks/$TASK_ID"

      # Kill dev server if running
      if [ -f "$TASK_DIR/dev-server.pid" ]; then
        kill "$(cat "$TASK_DIR/dev-server.pid")" 2>/dev/null || true
      fi

      # Remove worktree
      if [ -d "$REPO_DIR" ] && [ -n "$BRANCH" ]; then
        cd "$REPO_DIR"
        git worktree remove "$TASK_DIR/worktree" --force 2>/dev/null || true
        git branch -D "$BRANCH" 2>/dev/null || true
      fi

      # Remove task directory
      rm -rf "$TASK_DIR"

      # Update DB
      psql -c "DELETE FROM coding_tasks WHERE id='$TASK_ID';" "$DB" 2>/dev/null

      echo "[cleanup] Removed task $TASK_ID"
    done

    echo "[cleanup] Done"
  '';

in
{
  options.homelab.services.coding-agents = {
    enable = lib.mkEnableOption "Autonomous coding agents";
    workspaceDir = lib.mkOption {
      type = lib.types.str;
      default = "/persist/coding-agents";
    };
    githubTokenFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing GitHub token for pushing and PRs";
    };
    model = lib.mkOption {
      type = lib.types.str;
      default = "sonnet";
    };
    scoreThreshold = lib.mkOption {
      type = lib.types.int;
      default = 7;
    };
    maxIterations = lib.mkOption {
      type = lib.types.int;
      default = 3;
    };
    maxTurns = lib.mkOption {
      type = lib.types.int;
      default = 50;
    };
    maxConcurrent = lib.mkOption {
      type = lib.types.int;
      default = 2;
    };
    previewBasePort = lib.mkOption {
      type = lib.types.int;
      default = 4300;
    };
    retentionDays = lib.mkOption {
      type = lib.types.int;
      default = 30;
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure workspace directories exist
    systemd.tmpfiles.rules = [
      "d ${cfg.workspaceDir} 0750 root root - -"
      "d ${cfg.workspaceDir}/repos 0750 root root - -"
      "d ${cfg.workspaceDir}/tasks 0750 root root - -"
      "d ${cfg.workspaceDir}/scripts 0750 root root - -"
      "d ${cfg.workspaceDir}/.claude 0700 root root - -"
      "L+ ${cfg.workspaceDir}/scripts/coding-agent-run.sh - - - - ${runScript}"
      "L+ ${cfg.workspaceDir}/scripts/coding-workspace.sh - - - - ${workspaceScript}"
      "L+ ${cfg.workspaceDir}/scripts/coding-tasks.sh - - - - ${tasksScript}"
    ];

    # Agent system prompt
    environment.etc."coding-agents/agent-prompt.txt".text = ''
      You are an autonomous coding agent. Your task will be provided in the prompt.

      ## Protocol
      1. EXPLORE: Read project structure, README, key files. Understand the stack, conventions, and patterns before writing any code.
      2. PLAN: Outline your approach. Consider which files to modify or create, and how existing code handles similar functionality.
      3. IMPLEMENT: Write code matching existing patterns strictly. Follow the project's conventions for naming, structure, and style.
      4. TEST: Run existing tests if a test framework is configured (npm test, pytest, etc.). Fix any failures.
      5. REVIEW: Read every file you modified in full. Check:
         - Does it match existing code style and patterns exactly?
         - Are there bugs, edge cases, or security issues?
         - Is the code clean, well-structured, and complete?
         - Would a senior developer approve this in code review?
      6. SCORE: Rate your implementation 1-10. Write .agent-result.json at the repo root:
         {"score": N, "summary": "brief description of what you did", "files_changed": ["file1.ts", "file2.ts"], "issues": ["any remaining issues"]}
      7. If your score is below the threshold, identify specific improvements and fix them. Update .agent-result.json.

      ## Scoring Guide
      - 9-10: Production-ready. Follows all patterns, clean, tested, no issues.
      - 7-8: Good implementation with minor improvements possible.
      - 5-6: Functional but has notable issues or doesn't fully match patterns.
      - 1-4: Incomplete or has significant problems.

      ## Rules
      - Read before you write. Always understand existing code first.
      - Match the project's existing style exactly — don't impose your own conventions.
      - Don't add unnecessary dependencies or over-engineer solutions.
      - Don't modify CLAUDE.md, .claude/ directories, or project configuration you don't need to.
      - Don't commit secrets, .env files, or credentials.
      - Prefer editing existing files over creating new ones when possible.
      - Keep solutions simple and focused on the task.
    '';

    # Install Claude Code CLI
    systemd.services.coding-agents-install = {
      description = "Install Claude Code CLI";
      wantedBy = [ "multi-user.target" ];
      environment.HOME = cfg.workspaceDir;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "coding-agents-install" ''
          export PATH=${pkgs.nodejs_22}/bin:${pkgs.coreutils}/bin:${pkgs.git}/bin:$PATH
          export HOME=${cfg.workspaceDir}

          # Install Claude Code if not present
          if [ ! -f ${claudeBin} ]; then
            echo "[install] Installing Claude Code CLI..."
            cd ${cfg.workspaceDir}
            ${pkgs.nodejs_22}/bin/npm install @anthropic-ai/claude-code 2>&1
          fi

          echo "[install] Claude Code CLI ready"
        '';
      };
    };

    # Initialize coding_tasks table
    systemd.services.coding-agents-db-init = {
      description = "Initialize coding agents database table";
      after = [ "postgresql.service" "openfang-db-init.service" ];
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "coding-agents-db-init" ''
          DB="${dbUrl}"
          ${pkgs.postgresql}/bin/psql -c "CREATE TABLE IF NOT EXISTS coding_tasks (
            id TEXT PRIMARY KEY,
            repo TEXT NOT NULL,
            branch TEXT,
            base_branch TEXT DEFAULT 'main',
            task_description TEXT NOT NULL,
            status TEXT DEFAULT 'queued',
            score INTEGER,
            iterations INTEGER DEFAULT 0,
            pr_url TEXT,
            pr_number INTEGER,
            preview_port INTEGER,
            preview_pid INTEGER,
            log_file TEXT,
            error TEXT,
            created_at TIMESTAMP DEFAULT NOW(),
            updated_at TIMESTAMP DEFAULT NOW(),
            completed_at TIMESTAMP
          );" "$DB"
        '';
      };
    };

    # Instantiated agent service — one per task
    systemd.services."coding-agent@" = {
      description = "Coding agent worker for task %i";
      after = [ "network-online.target" "postgresql.service" "coding-agents-db-init.service" "coding-agents-install.service" ];
      wants = [ "network-online.target" ];
      requires = [ "coding-agents-install.service" "coding-agents-db-init.service" ];
      path = with pkgs; [ bash coreutils git jq postgresql nodejs_22 gh gnugrep gnused findutils procps ];
      environment = {
        HOME = cfg.workspaceDir;
        CLAUDE_CONFIG_DIR = "${cfg.workspaceDir}/.claude";
      };
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "30min";
        ExecStart = "${workerScript} %i";
        StandardOutput = "append:${cfg.workspaceDir}/tasks/%i/agent.log";
        StandardError = "append:${cfg.workspaceDir}/tasks/%i/agent.log";
      };
    };

    # Weekly cleanup of old tasks
    systemd.services.coding-agents-cleanup = {
      description = "Cleanup old coding agent tasks";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = cleanupScript;
      };
    };
    systemd.timers.coding-agents-cleanup = {
      description = "Weekly coding agents cleanup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
      };
    };

    # Open preview port range in firewall (LAN access)
    networking.firewall.allowedTCPPortRanges = [
      { from = cfg.previewBasePort; to = cfg.previewBasePort + 20; }
    ];
  };
}
