# Autonomous coding agents — Claude Code on git worktrees managed by wt
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
  fluzyNotify = "/persist/openfang/scripts/fluzy-notify.sh";
  claudeBin = "${cfg.workspaceDir}/node_modules/.bin/claude";
  wtBin = "${cfg.workspaceDir}/wt/wt.sh";
  promptFile = "/etc/coding-agents/agent-prompt.txt";

  # --- Scripts ---

  runScript = pkgs.writeShellScript "coding-agent-run" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.git}/bin:${pkgs.jq}/bin:${pkgs.postgresql}/bin:${pkgs.systemd}/bin:${pkgs.util-linux}/bin:${pkgs.yq-go}/bin:${pkgs.tmux}/bin:$PATH
    DB="${dbUrl}"
    WORKSPACE="${cfg.workspaceDir}"
    WT="${wtBin}"
    export HOME="$WORKSPACE"
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'

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

    # Mark stale tasks (stuck >35min) as failed before checking limit
    psql -c "UPDATE coding_tasks SET status='failed', error='stale (>35min)', updated_at=NOW() WHERE status IN ('queued','running','reviewing','iterating','pushing') AND created_at < NOW() - INTERVAL '35 minutes';" "$DB" 2>/dev/null || true

    # Check concurrent limit
    RUNNING=$(psql -t -A -c "SELECT COUNT(*) FROM coding_tasks WHERE status IN ('queued','running','reviewing','iterating','pushing');" "$DB" 2>/dev/null || echo "0")
    if [ "$RUNNING" -ge ${toString cfg.maxConcurrent} ]; then
      echo '{"error": "concurrent limit reached ('"$RUNNING"'/${toString cfg.maxConcurrent})"}'
      exit 1
    fi

    # Generate task ID
    TASK_ID="$(date +%Y%m%d-%H%M%S)-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"

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
      git remote set-url origin "https://github.com/$REPO.git"
      chown -R ${cfg.user}:users "$REPO_DIR" 2>/dev/null || true

      # Initialize wt config for this project
      cd "$REPO_DIR"
      $WT init 2>/dev/null || true
    fi

    # Fetch latest
    cd "$REPO_DIR"
    git fetch origin 2>/dev/null

    # Create worktree (standard git — always reliable)
    BRANCH="agent-$TASK_ID"
    TASK_DIR="$WORKSPACE/tasks/$TASK_ID"
    WORKTREE_DIR="$TASK_DIR/worktree"
    mkdir -p "$TASK_DIR"
    git worktree add "$WORKTREE_DIR" -b "$BRANCH" "origin/$BASE_BRANCH" 2>&1

    # Ensure bmasi owns everything (run script may be called by root via Fluzy)
    chown -R ${cfg.user}:users "$TASK_DIR" 2>/dev/null || true

    # Write task.json
    ${pkgs.jq}/bin/jq -n \
      --arg id "$TASK_ID" \
      --arg repo "$REPO" \
      --arg base "$BASE_BRANCH" \
      --arg branch "$BRANCH" \
      --arg task "$TASK" \
      --arg worktree "$WORKTREE_DIR" \
      '{id: $id, repo: $repo, base_branch: $base, branch: $branch, task: $task, worktree: $worktree}' \
      > "$TASK_DIR/task.json"

    # Insert DB record
    SAFE_TASK=$(echo "$TASK" | sed "s/'''/''''/g")
    psql -c "INSERT INTO coding_tasks (id, repo, branch, base_branch, task_description, status, log_file) VALUES ('$TASK_ID', '$REPO', '$BRANCH', '$BASE_BRANCH', '$SAFE_TASK', 'queued', '$TASK_DIR/agent.log');" "$DB"

    # Start background service (sudo if not root, direct if root)
    if [ "$(id -u)" = "0" ]; then
      /run/current-system/sw/bin/systemctl start --no-block "coding-agent@$TASK_ID.service"
    else
      sudo /run/current-system/sw/bin/systemctl start --no-block "coding-agent@$TASK_ID.service"
    fi

    # Return task info
    ${pkgs.jq}/bin/jq -n \
      --arg id "$TASK_ID" \
      --arg branch "$BRANCH" \
      '{task_id: $id, status: "queued", branch: $branch}'
  '';

  workerScript = pkgs.writeShellScript "coding-agent-worker" ''
    set -euo pipefail
    export PATH=${pkgs.coreutils}/bin:${pkgs.git}/bin:${pkgs.jq}/bin:${pkgs.postgresql}/bin:${pkgs.nodejs_22}/bin:${pkgs.gh}/bin:${pkgs.gnugrep}/bin:${pkgs.gnused}/bin:${pkgs.findutils}/bin:${pkgs.procps}/bin:${pkgs.yq-go}/bin:${pkgs.tmux}/bin:$PATH
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'

    TASK_ID="$1"
    WORKSPACE="${cfg.workspaceDir}"
    DB="${dbUrl}"
    TASK_DIR="$WORKSPACE/tasks/$TASK_ID"
    CLAUDE="${claudeBin}"
    PROMPT_FILE="${promptFile}"
    WT="${wtBin}"

    # Error handler
    on_error() {
      local err_msg
      err_msg=$(tail -5 "$TASK_DIR/agent.log" 2>/dev/null | head -c 500 || echo "unknown error")
      err_msg=$(echo "$err_msg" | sed "s/'''/''''/g")
      psql -c "UPDATE coding_tasks SET status='failed', error='$err_msg', updated_at=NOW() WHERE id='$TASK_ID';" "$DB" 2>/dev/null || true
      ${fluzyNotify} "[SYSTEM] Coding agent task FAILED. Task ID: $TASK_ID. Repo: $(cat "$TASK_DIR/task.json" 2>/dev/null | jq -r '.repo // "unknown"'). Error: $(tail -3 "$TASK_DIR/agent.log" 2>/dev/null | head -c 200). Let the user know what happened and suggest what to do." 2>/dev/null || true
    }
    trap on_error ERR

    # Read task config
    TASK_JSON=$(cat "$TASK_DIR/task.json")
    REPO=$(echo "$TASK_JSON" | jq -r '.repo')
    BRANCH=$(echo "$TASK_JSON" | jq -r '.branch')
    BASE_BRANCH=$(echo "$TASK_JSON" | jq -r '.base_branch')
    TASK_DESC=$(echo "$TASK_JSON" | jq -r '.task')
    WORKTREE_DIR=$(echo "$TASK_JSON" | jq -r '.worktree')

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
    echo "[agent] Worktree: $WORKTREE_DIR"
    echo "[agent] Model: ${cfg.model} | Max turns: ${toString cfg.maxTurns}"
    echo "[agent] $(date '+%H:%M:%S') Starting implementation..."

    # Phase 1: Implement
    IMPLEMENT_PROMPT="Your task: $TASK_DESC

After completing the implementation, write a file called .agent-result.json at the repository root with this exact JSON structure:
{\"score\": <1-10>, \"summary\": \"brief description of what you did\", \"files_changed\": [\"list of files\"], \"issues\": [\"any remaining issues\"]}

Score guide: 9-10 production-ready, 7-8 good with minor issues, 5-6 functional but needs work, 1-4 incomplete."

    echo "[agent] $(date '+%H:%M:%S') Calling Claude Code (${cfg.model})..."
    $CLAUDE -p "$IMPLEMENT_PROMPT" \
      --dangerously-skip-permissions \
      --model ${cfg.model} \
      --max-turns ${toString cfg.maxTurns} \
      --system-prompt-file "$PROMPT_FILE" \
      --output-format stream-json \
      --verbose \
      2>&1 | while IFS= read -r line; do
        # Log tool use events for visibility
        TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
        if [ "$TYPE" = "assistant" ]; then
          TOOL=$(echo "$line" | jq -r '.message.content[]? | select(.type=="tool_use") | .name // empty' 2>/dev/null)
          [ -n "$TOOL" ] && echo "[agent] $(date '+%H:%M:%S') Using tool: $TOOL"
        elif [ "$TYPE" = "result" ]; then
          echo "$line" > "$TASK_DIR/claude-result.json"
          echo "[agent] $(date '+%H:%M:%S') Claude finished ($(echo "$line" | jq -r '.duration_ms // 0' 2>/dev/null)ms, $(echo "$line" | jq -r '.num_turns // 0' 2>/dev/null) turns)"
        fi
      done || true

    # Parse result
    SCORE=0
    SUMMARY="No result produced"
    ISSUES=""
    if [ -f ".agent-result.json" ]; then
      SCORE=$(jq -r '.score // 0' .agent-result.json 2>/dev/null || echo "0")
      SUMMARY=$(jq -r '.summary // "No summary"' .agent-result.json 2>/dev/null || echo "No summary")
      ISSUES=$(jq -r '.issues // [] | join("; ")' .agent-result.json 2>/dev/null || echo "")
    fi

    echo "[agent] $(date '+%H:%M:%S') Phase 1 complete. Score: $SCORE/10"

    # Iteration loop
    ITERATIONS=0
    while [ "$SCORE" -lt ${toString cfg.scoreThreshold} ] && [ "$ITERATIONS" -lt ${toString cfg.maxIterations} ]; do
      ITERATIONS=$((ITERATIONS + 1))
      psql -c "UPDATE coding_tasks SET status='iterating', iterations=$ITERATIONS, score=$SCORE, updated_at=NOW() WHERE id='$TASK_ID';" "$DB"

      echo "[agent] $(date '+%H:%M:%S') Score $SCORE < ${toString cfg.scoreThreshold}, iterating ($ITERATIONS/${toString cfg.maxIterations})..."

      IMPROVE_PROMPT="Your previous implementation scored $SCORE/10. Issues found: $ISSUES

Review all your changes, fix the issues, improve the code quality, and re-score. Update .agent-result.json with the new score."

      echo "[agent] $(date '+%H:%M:%S') Calling Claude Code (${cfg.model}, iteration)..."
      $CLAUDE -p "$IMPROVE_PROMPT" \
        --dangerously-skip-permissions \
        --model ${cfg.model} \
        --max-turns $((${toString cfg.maxTurns} / 2)) \
        --system-prompt-file "$PROMPT_FILE" \
        --output-format stream-json \
        --verbose \
        2>&1 | while IFS= read -r line; do
          TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
          if [ "$TYPE" = "assistant" ]; then
            TOOL=$(echo "$line" | jq -r '.message.content[]? | select(.type=="tool_use") | .name // empty' 2>/dev/null)
            [ -n "$TOOL" ] && echo "[agent] $(date '+%H:%M:%S') Using tool: $TOOL"
          elif [ "$TYPE" = "result" ]; then
            echo "$line" > "$TASK_DIR/claude-result.json"
            echo "[agent] $(date '+%H:%M:%S') Claude finished ($(echo "$line" | jq -r '.duration_ms // 0' 2>/dev/null)ms)"
          fi
        done || true

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
      ${fluzyNotify} "[SYSTEM] Coding agent task produced no changes. Task ID: $TASK_ID. Repo: $REPO. Task: $TASK_DESC. Score: $SCORE/10. The agent ran but didn't change any files. Suggest the user rephrase the task or check if it was already done." || true
      exit 0
    fi

    # Commit and push
    psql -c "UPDATE coding_tasks SET status='pushing', score=$SCORE, iterations=$ITERATIONS, updated_at=NOW() WHERE id='$TASK_ID';" "$DB"

    git add -A
    git reset HEAD .agent-result.json 2>/dev/null || true
    rm -f .agent-result.json

    SAFE_SUMMARY=$(echo "$SUMMARY" | head -c 200)
    git commit -m "$(cat <<COMMITEOF
$SAFE_SUMMARY

Task: $TASK_DESC
Agent: $TASK_ID | Score: $SCORE/10 | Iterations: $ITERATIONS
COMMITEOF
    )"

    # Push (set token URL temporarily)
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

    # Start services via wt (ports handled automatically by wt config)
    PREVIEW_URL=""
    cd "$REPO_DIR"
    $WT start "$BRANCH" --all 2>&1 || true

    # Extract port info from wt
    PORT_INFO=$($WT ports "$BRANCH" 2>&1 | grep -E "^export PORT_" | head -1 || true)
    if [ -n "$PORT_INFO" ]; then
      MAIN_PORT=$(echo "$PORT_INFO" | grep -oP '=\K[0-9]+')
      PREVIEW_URL="http://sweet:$MAIN_PORT"
    fi

    # Update DB — do this BEFORE notification so task is marked done regardless
    SAFE_PR_URL=$(echo "$PR_URL" | sed "s/'''/''''/g" | head -1)
    psql -c "UPDATE coding_tasks SET status='done', score=$SCORE, iterations=$ITERATIONS, pr_url='$SAFE_PR_URL', pr_number=$(echo "''${PR_NUMBER:-0}"), completed_at=NOW(), updated_at=NOW() WHERE id='$TASK_ID';" "$DB"

    # Disable ERR trap — everything after this is best-effort
    trap - ERR

    # Notify via Fluzy (best-effort — Fluzy interprets and relays in his own voice)
    PREVIEW_NOTE=""
    if [ -n "$PREVIEW_URL" ]; then
      PREVIEW_NOTE="Live preview: $PREVIEW_URL."
    fi
    ${fluzyNotify} "[SYSTEM] Coding agent task completed. Task ID: $TASK_ID. Repo: $REPO. Task: $TASK_DESC. Score: $SCORE/10 ($ITERATIONS iterations). PR: ''${PR_URL:-no PR}. Summary: $SUMMARY. $PREVIEW_NOTE Inform the user about this. Include the PR link." || echo "[agent] fluzy-notify failed (non-fatal)"

    echo "[agent] Done! PR: $PR_URL"
  '';

  workspaceScript = pkgs.writeShellScript "coding-workspace" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.git}/bin:${pkgs.jq}/bin:${pkgs.findutils}/bin:${pkgs.yq-go}/bin:${pkgs.tmux}/bin:$PATH
    WORKSPACE="${cfg.workspaceDir}"
    WT="${wtBin}"
    export HOME="$WORKSPACE"
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'

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

        # Initialize wt config
        $WT init 2>/dev/null || true
        echo "Cloned: $REPO (wt config initialized — edit at ~/.config/wt/projects/)"
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
      config)
        REPO="$2"
        [ -z "$REPO" ] && echo "Usage: coding-workspace config OWNER/REPO" && exit 1
        REPO_NAME=$(basename "$REPO")
        CONFIG="$WORKSPACE/.config/wt/projects/$REPO_NAME.yaml"
        if [ -f "$CONFIG" ]; then
          cat "$CONFIG"
        else
          echo "No wt config found for $REPO. Run: coding-workspace clone $REPO"
        fi
        ;;
      remove)
        REPO="$2"
        [ -z "$REPO" ] && echo "Usage: coding-workspace remove OWNER/REPO" && exit 1
        REPO_DIR="$WORKSPACE/repos/$REPO"
        [ ! -d "$REPO_DIR" ] && echo "Not found: $REPO" && exit 1
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
        echo "Usage: coding-workspace {clone|list|update|config|remove} [OWNER/REPO]"
        ;;
    esac
  '';

  tasksScript = pkgs.writeShellScript "coding-tasks" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.jq}/bin:${pkgs.postgresql}/bin:${pkgs.gh}/bin:${pkgs.gnugrep}/bin:${pkgs.procps}/bin:${pkgs.systemd}/bin:${pkgs.yq-go}/bin:${pkgs.tmux}/bin:$PATH
    DB="${dbUrl}"
    WORKSPACE="${cfg.workspaceDir}"
    WT="${wtBin}"
    export HOME="$WORKSPACE"

    case "''${1:-}" in
      list)
        STATUS_FILTER="''${2:-}"
        if [ -n "$STATUS_FILTER" ] && [ "$STATUS_FILTER" != "--status" ]; then
          WHERE="WHERE status='$STATUS_FILTER'"
        elif [ -n "''${3:-}" ]; then
          WHERE="WHERE status='$3'"
        else
          WHERE=""
        fi
        RESULT=$(psql -t -A -c "SELECT json_build_object('id',id,'repo',repo,'status',status,'score',score,'task',substring(task_description for 80),'pr_url',pr_url,'created_at',created_at) FROM coding_tasks $WHERE ORDER BY created_at DESC LIMIT 20;" "$DB" 2>/dev/null)
        if [ -z "$RESULT" ]; then
          echo "No tasks found"
        else
          echo "[$RESULT]" | sed 's/}{/},{/g' | jq '.' 2>/dev/null || echo "$RESULT"
        fi
        ;;
      status)
        TASK_ID="$2"
        [ -z "$TASK_ID" ] && echo "Usage: coding-tasks status TASK_ID" && exit 1
        psql -t -A -c "SELECT json_build_object('id',id,'repo',repo,'branch',branch,'status',status,'score',score,'iterations',iterations,'task',task_description,'pr_url',pr_url,'pr_number',pr_number,'error',error,'created_at',created_at,'completed_at',completed_at) FROM coding_tasks WHERE id='$TASK_ID';" "$DB" 2>/dev/null | jq '.' 2>/dev/null
        ;;
      logs)
        TASK_ID="$2"
        [ -z "$TASK_ID" ] && echo "Usage: coding-tasks logs TASK_ID [-f|--tail N]" && exit 1
        LOG_FILE="$WORKSPACE/tasks/$TASK_ID/agent.log"
        if [ "''${3:-}" = "-f" ]; then
          exec tail -f "$LOG_FILE"
        elif [ "''${3:-}" = "--tail" ]; then
          TAIL_N="''${4:-50}"
          tail -n "$TAIL_N" "$LOG_FILE" 2>/dev/null || echo "No log file found"
        else
          tail -n 50 "$LOG_FILE" 2>/dev/null || echo "No log file found"
        fi
        ;;
      cancel)
        TASK_ID="$2"
        [ -z "$TASK_ID" ] && echo "Usage: coding-tasks cancel TASK_ID" && exit 1
        systemctl stop "coding-agent@$TASK_ID.service" 2>/dev/null || true
        # Stop wt services
        BRANCH=$(psql -t -A -c "SELECT branch FROM coding_tasks WHERE id='$TASK_ID';" "$DB" 2>/dev/null)
        REPO=$(psql -t -A -c "SELECT repo FROM coding_tasks WHERE id='$TASK_ID';" "$DB" 2>/dev/null)
        if [ -n "$BRANCH" ] && [ -n "$REPO" ]; then
          cd "$WORKSPACE/repos/$REPO" 2>/dev/null && $WT stop "$BRANCH" --all 2>/dev/null || true
        fi
        psql -c "UPDATE coding_tasks SET status='cancelled', updated_at=NOW() WHERE id='$TASK_ID' AND status NOT IN ('done','failed','cancelled');" "$DB" 2>/dev/null
        echo "Cancelled: $TASK_ID"
        ;;
      pr-info)
        TASK_ID="$2"
        [ -z "$TASK_ID" ] && echo "Usage: coding-tasks pr-info TASK_ID" && exit 1
        TASK_DATA=$(psql -t -A -c "SELECT repo || ' ' || COALESCE(pr_number::text, '''') FROM coding_tasks WHERE id='$TASK_ID';" "$DB" 2>/dev/null)
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
        BRANCH=$(psql -t -A -c "SELECT branch FROM coding_tasks WHERE id='$TASK_ID';" "$DB" 2>/dev/null)
        REPO=$(psql -t -A -c "SELECT repo FROM coding_tasks WHERE id='$TASK_ID';" "$DB" 2>/dev/null)
        if [ -n "$BRANCH" ] && [ -n "$REPO" ]; then
          cd "$WORKSPACE/repos/$REPO" 2>/dev/null
          echo "=== Services for $BRANCH ==="
          $WT ports "$BRANCH" 2>/dev/null || echo "No services running"
        else
          echo "Task not found"
        fi
        ;;
      ports)
        echo "=== All Running Previews ==="
        # Check each done task for running wt services
        psql -t -A -c "SELECT id || '|' || repo || '|' || branch FROM coding_tasks WHERE status = 'done' ORDER BY created_at DESC LIMIT 10;" "$DB" 2>/dev/null | while IFS='|' read -r tid trepo tbranch; do
          if [ -n "$tbranch" ] && [ -n "$trepo" ]; then
            PORT_LINE=$(cd "$WORKSPACE/repos/$trepo" 2>/dev/null && $WT ports "$tbranch" 2>/dev/null | grep -E "^export PORT_" | head -1 || true)
            if [ -n "$PORT_LINE" ]; then
              PORT=$(echo "$PORT_LINE" | grep -oP '=\K[0-9]+')
              echo "$tid | $trepo | $tbranch | http://sweet:$PORT"
            fi
          fi
        done
        ;;
      stop-preview)
        TASK_ID="$2"
        [ -z "$TASK_ID" ] && echo "Usage: coding-tasks stop-preview TASK_ID" && exit 1
        BRANCH=$(psql -t -A -c "SELECT branch FROM coding_tasks WHERE id='$TASK_ID';" "$DB" 2>/dev/null)
        REPO=$(psql -t -A -c "SELECT repo FROM coding_tasks WHERE id='$TASK_ID';" "$DB" 2>/dev/null)
        if [ -n "$BRANCH" ] && [ -n "$REPO" ]; then
          cd "$WORKSPACE/repos/$REPO" 2>/dev/null && $WT stop "$BRANCH" --all 2>/dev/null
          echo "Stopped services for $BRANCH"
        else
          echo "Task not found"
        fi
        ;;
      *)
        echo "Usage: coding-tasks {list|status|logs|cancel|pr-info|preview|ports|stop-preview} [ARGS]"
        ;;
    esac
  '';

  cleanupScript = pkgs.writeShellScript "coding-agents-cleanup" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.git}/bin:${pkgs.postgresql}/bin:${pkgs.findutils}/bin:${pkgs.procps}/bin:${pkgs.yq-go}/bin:${pkgs.tmux}/bin:$PATH
    DB="${dbUrl}"
    WORKSPACE="${cfg.workspaceDir}"
    WT="${wtBin}"
    export HOME="$WORKSPACE"
    RETENTION=${toString cfg.retentionDays}

    echo "[cleanup] Cleaning tasks older than $RETENTION days..."

    OLD_TASKS=$(psql -t -A -c "SELECT id || '|' || repo || '|' || branch FROM coding_tasks WHERE status IN ('done','failed','cancelled') AND completed_at < NOW() - INTERVAL '$RETENTION days';" "$DB" 2>/dev/null)

    for entry in $OLD_TASKS; do
      TASK_ID=$(echo "$entry" | cut -d'|' -f1)
      REPO=$(echo "$entry" | cut -d'|' -f2)
      BRANCH=$(echo "$entry" | cut -d'|' -f3)
      REPO_DIR="$WORKSPACE/repos/$REPO"
      TASK_DIR="$WORKSPACE/tasks/$TASK_ID"

      # Stop and delete via wt
      if [ -d "$REPO_DIR" ] && [ -n "$BRANCH" ]; then
        cd "$REPO_DIR"
        $WT stop "$BRANCH" --all 2>/dev/null || true
        $WT delete "$BRANCH" 2>/dev/null || true
      fi

      # Remove task metadata directory
      rm -rf "$TASK_DIR"

      # Delete DB record
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
      default = "opus";
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
      default = 3;
    };
    retentionDays = lib.mkOption {
      type = lib.types.int;
      default = 30;
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "bmasi";
      description = "User to run coding agents as (cannot be root)";
    };
  };

  config = lib.mkIf cfg.enable {
    # CLI wrapper: `ca run`, `ca status`, `ca logs`, etc.
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "ca" ''
        export PATH=${pkgs.coreutils}/bin:$PATH
        SCRIPTS="${cfg.workspaceDir}/scripts"
        CMD="''${1:-help}"
        shift 2>/dev/null || true

        case "$CMD" in
          run)       exec "$SCRIPTS/coding-agent-run.sh" "$@" ;;
          status)    exec "$SCRIPTS/coding-tasks.sh" status "$@" ;;
          logs)      exec "$SCRIPTS/coding-tasks.sh" logs "$@" ;;
          list)      exec "$SCRIPTS/coding-tasks.sh" list "$@" ;;
          cancel)    exec "$SCRIPTS/coding-tasks.sh" cancel "$@" ;;
          pr)        exec "$SCRIPTS/coding-tasks.sh" pr-info "$@" ;;
          preview)   exec "$SCRIPTS/coding-tasks.sh" preview "$@" ;;
          ports)     exec "$SCRIPTS/coding-tasks.sh" ports ;;
          stop)      exec "$SCRIPTS/coding-tasks.sh" stop-preview "$@" ;;
          clone)     exec "$SCRIPTS/coding-workspace.sh" clone "$@" ;;
          repos)     exec "$SCRIPTS/coding-workspace.sh" list ;;
          config)    exec "$SCRIPTS/coding-workspace.sh" config "$@" ;;
          update)    exec "$SCRIPTS/coding-workspace.sh" update "$@" ;;
          tail)
            TASK_ID="$1"
            [ -z "$TASK_ID" ] && echo "Usage: ca tail TASK_ID" && exit 1
            exec tail -f "${cfg.workspaceDir}/tasks/$TASK_ID/agent.log"
            ;;
          *)
            echo "ca — coding agents CLI"
            echo ""
            echo "Tasks:"
            echo "  ca run --repo OWNER/REPO --task \"description\" [--branch main]"
            echo "  ca list [running|done|failed]"
            echo "  ca status TASK_ID"
            echo "  ca logs TASK_ID [--tail N]"
            echo "  ca tail TASK_ID              (live follow)"
            echo "  ca cancel TASK_ID"
            echo "  ca pr TASK_ID"
            echo ""
            echo "Previews:"
            echo "  ca preview TASK_ID"
            echo "  ca ports"
            echo "  ca stop TASK_ID"
            echo ""
            echo "Repos:"
            echo "  ca clone OWNER/REPO"
            echo "  ca repos"
            echo "  ca config OWNER/REPO"
            echo "  ca update [OWNER/REPO]"
            ;;
        esac
      '')
    ];
    # Ensure workspace directories exist
    systemd.tmpfiles.rules = [
      "d ${cfg.workspaceDir} 0750 ${cfg.user} users - -"
      "d ${cfg.workspaceDir}/repos 0750 ${cfg.user} users - -"
      "d ${cfg.workspaceDir}/tasks 0750 ${cfg.user} users - -"
      "d ${cfg.workspaceDir}/scripts 0750 ${cfg.user} users - -"
      "d ${cfg.workspaceDir}/.claude 0700 ${cfg.user} users - -"
      "d ${cfg.workspaceDir}/.config/wt/projects 0750 ${cfg.user} users - -"
      "d ${cfg.workspaceDir}/.local/share/wt 0750 ${cfg.user} users - -"
      "L+ ${cfg.workspaceDir}/scripts/coding-agent-run.sh - - - - ${runScript}"
      "L+ ${cfg.workspaceDir}/scripts/coding-workspace.sh - - - - ${workspaceScript}"
      "L+ ${cfg.workspaceDir}/scripts/coding-tasks.sh - - - - ${tasksScript}"
    ];

    # Agent system prompt — no port/service management, wt handles that
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
      - Do NOT worry about ports, services, or dev server configuration — that is handled externally.
    '';

    # Install Claude Code CLI + wt
    systemd.services.coding-agents-install = {
      description = "Install Claude Code CLI and wt";
      wantedBy = [ "multi-user.target" ];
      environment.HOME = cfg.workspaceDir;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        ExecStart = pkgs.writeShellScript "coding-agents-install" ''
          export PATH=${pkgs.nodejs_22}/bin:${pkgs.coreutils}/bin:${pkgs.git}/bin:${pkgs.bash}/bin:${pkgs.findutils}/bin:${pkgs.gnused}/bin:$PATH
          export HOME=${cfg.workspaceDir}

          # Install Claude Code if not present
          if [ ! -f ${claudeBin} ]; then
            echo "[install] Installing Claude Code CLI..."
            cd ${cfg.workspaceDir}
            ${pkgs.nodejs_22}/bin/npm install @anthropic-ai/claude-code 2>&1
          fi

          # Install wt if not present
          if [ ! -f ${wtBin} ]; then
            echo "[install] Installing wt (git worktree manager)..."
            ${pkgs.git}/bin/git clone --depth 1 https://github.com/brunodmsi/wt.git ${cfg.workspaceDir}/wt 2>&1
            # NixOS has no /bin/bash — patch shebangs to use env
            ${pkgs.findutils}/bin/find ${cfg.workspaceDir}/wt -name "*.sh" -exec ${pkgs.gnused}/bin/sed -i 's|#!/bin/bash|#!/usr/bin/env bash|' {} \;
            chmod +x ${wtBin}
          fi

          echo "[install] Claude Code CLI + wt ready"
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
      path = with pkgs; [ bash coreutils git jq postgresql nodejs_22 gh gnugrep gnused findutils procps yq-go tmux ];
      environment = {
        HOME = cfg.workspaceDir;
        CLAUDE_CONFIG_DIR = "${cfg.workspaceDir}/.claude";
        TERM = "dumb";
      };
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "30min";
        User = cfg.user;
        ExecStart = "${workerScript} %i";
        StandardOutput = "append:${cfg.workspaceDir}/tasks/%i/agent.log";
        StandardError = "append:${cfg.workspaceDir}/tasks/%i/agent.log";
        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "full";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };

    # Auth health check — verify Claude Code credentials, notify if expired
    systemd.services.coding-agents-auth-check = {
      description = "Check Claude Code authentication status";
      after = [ "coding-agents-install.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      path = with pkgs; [ bash coreutils nodejs_22 gnugrep ];
      environment = {
        HOME = cfg.workspaceDir;
        CLAUDE_CONFIG_DIR = "${cfg.workspaceDir}/.claude";
      };
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        ExecStart = pkgs.writeShellScript "coding-agents-auth-check" ''
          export PATH=${pkgs.nodejs_22}/bin:${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:$PATH
          export HOME=${cfg.workspaceDir}
          export CLAUDE_CONFIG_DIR="${cfg.workspaceDir}/.claude"

          CREDS="${cfg.workspaceDir}/.claude/.credentials.json"
          if [ ! -f "$CREDS" ]; then
            /persist/openfang/scripts/wa-notify.sh "" "$(printf '⚠️ *Coding Agents*: Claude Code not authenticated\nRun on server: CLAUDE_CONFIG_DIR=/persist/coding-agents/.claude claude login')"
            exit 0
          fi

          RESULT=$(timeout 30 ${claudeBin} -p "respond with exactly: OK" --max-turns 1 --output-format text 2>&1 || echo "AUTH_FAILED")
          if echo "$RESULT" | grep -qi "auth\|unauthorized\|login\|credential\|AUTH_FAILED"; then
            /persist/openfang/scripts/wa-notify.sh "" "$(printf '⚠️ *Coding Agents*: Claude Code auth expired\nRun on server: CLAUDE_CONFIG_DIR=/persist/coding-agents/.claude claude login')"
          fi
        '';
      };
    };
    systemd.timers.coding-agents-auth-check = {
      description = "Daily Claude Code auth check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 08:00:00";
        Persistent = true;
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

    # Open port range for wt-managed dev servers (LAN access)
    networking.firewall.allowedTCPPortRanges = [
      { from = 3000; to = 5300; }
    ];

    # Let the coding-agents user start/stop agent services without password
    security.sudo.extraRules = [{
      users = [ cfg.user ];
      commands = [
        { command = "/run/current-system/sw/bin/systemctl start coding-agent@*"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/systemctl stop coding-agent@*"; options = [ "NOPASSWD" ]; }
      ];
    }];
  };
}
