# Fluminense matchday pre-game notifications via WhatsApp
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.services.openfang;
  flu = cfg.fluminense;
  waNotify = "/persist/openfang/scripts/wa-notify.sh";

  matchdayScript = pkgs.writeShellScript "fluminense-matchday" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.gnugrep}/bin:$PATH

    TAVILY_KEY=$(cat ${cfg.tavilyApiKeyFile})
    GEMINI_KEY=$(cat ${flu.geminiApiKeyFile})
    TODAY=$(TZ=America/Belem date +"%d/%m/%Y")
    TODAY_ISO=$(TZ=America/Belem date +"%Y-%m-%d")
    TODAY_SHORT=$(TZ=America/Belem date +"%-d/%-m")
    TODAY_DAY=$(TZ=America/Belem date +"%-d")
    TODAY_WEEKDAY=$(TZ=America/Belem date +"%A" | sed 's/Monday/segunda/;s/Tuesday/terça/;s/Wednesday/quarta/;s/Thursday/quinta/;s/Friday/sexta/;s/Saturday/sábado/;s/Sunday/domingo/')

    echo "[flu] Checking Fluminense matchday for $TODAY ($TODAY_WEEKDAY)..."

    # Step 1: Search specifically for today's match date
    SEARCH=$(${pkgs.curl}/bin/curl -s --max-time 15 -X POST "https://api.tavily.com/search" \
      -H "Content-Type: application/json" \
      -d '{
        "query": "Fluminense jogo '"$TODAY"' '"$TODAY_WEEKDAY"' horario adversario",
        "search_depth": "basic",
        "max_results": 5,
        "include_answer": true
      }' 2>/dev/null)

    if [ -z "$SEARCH" ]; then
      echo "[flu] Tavily search failed"
      exit 0
    fi

    CONTENTS=$(echo "$SEARCH" | ${pkgs.jq}/bin/jq -r '(.answer // "") + " " + ([.results[].content] | join(" "))' 2>/dev/null)

    # Step 1b: Also check Fluminense schedule to cross-reference
    SCHEDULE=$(${pkgs.curl}/bin/curl -s --max-time 15 -X POST "https://api.tavily.com/search" \
      -H "Content-Type: application/json" \
      -d '{
        "query": "Fluminense calendario proximo jogo data março 2026",
        "search_depth": "basic",
        "max_results": 3,
        "include_answer": true
      }' 2>/dev/null)

    SCHEDULE_TEXT=$(echo "$SCHEDULE" | ${pkgs.jq}/bin/jq -r '(.answer // "")' 2>/dev/null)

    # Must find today's date (DD/MM or DD/M or just day number near "Fluminense x") in results
    # This prevents matching results about other dates
    HAS_DATE=$(echo "$CONTENTS $SCHEDULE_TEXT" | ${pkgs.gnugrep}/bin/grep -icP "(${TODAY_SHORT}|${TODAY}|${TODAY_ISO}).{0,80}(fluminense|flu\b)|(fluminense|flu\b).{0,80}(${TODAY_SHORT}|${TODAY}|${TODAY_ISO})" || echo "0")

    if [ "$HAS_DATE" -eq 0 ]; then
      echo "[flu] No date match for $TODAY in search results — skipping"
      exit 0
    fi

    # Also verify there's an actual matchup pattern (not just a news article mentioning the date)
    HAS_MATCH=$(echo "$CONTENTS" | ${pkgs.gnugrep}/bin/grep -icP "(fluminense\s*(x|vs|contra)\s)|(\s(x|vs|contra)\s*fluminense)|(\d{1,2}h\d{0,2}.*fluminense)|(fluminense.*\d{1,2}h\d{0,2})" || echo "0")

    if [ "$HAS_MATCH" -eq 0 ]; then
      echo "[flu] No matchup pattern found"
      exit 0
    fi

    echo "[flu] Match detected for $TODAY! Gathering context..."

    # Step 2: Get more context — opponent form + head-to-head
    CONTEXT_FORM=$(${pkgs.curl}/bin/curl -s --max-time 15 -X POST "https://api.tavily.com/search" \
      -H "Content-Type: application/json" \
      -d '{
        "query": "Fluminense ultimos jogos resultados 2026",
        "search_depth": "basic",
        "max_results": 3,
        "include_answer": true
      }' 2>/dev/null)

    FORM_TEXT=$(echo "$CONTEXT_FORM" | ${pkgs.jq}/bin/jq -r '(.answer // "") + " " + ([.results[].content] | join(" "))' 2>/dev/null)

    # Step 3: Compose via Gemini
    PROMPT="You are Fluzy, a WhatsApp assistant with Fluminense (Tricolor das Laranjeiras) energy — laid back, carioca, debochado, but PASSIONATE about Flu. You speak with carioca slang (po, mermao, suave, ta ligado, firmeza, caraca).

CRITICAL TASK: First, determine if Fluminense has a match SPECIFICALLY on $TODAY ($TODAY_WEEKDAY). You must verify the EXACT DATE — not tomorrow, not yesterday, not next week. The match must be on $TODAY.

If there is NO Fluminense match confirmed for EXACTLY $TODAY, respond with ONLY: NO_MATCH
Do NOT compose a message about matches on other dates. Do NOT assume a match exists. If the date is ambiguous or unclear, respond with NO_MATCH.

ONLY if a match is CONFIRMED for $TODAY ($TODAY_WEEKDAY), compose a pre-game WhatsApp message for Bruno (a fellow Tricolor). Include:
- The matchup, competition, time, and venue
- How the opponent has been doing lately
- Recent head-to-head results if available
- How Fluminense is arriving to the match
- A little hype/commentary in your sassy style

Use WhatsApp formatting (*bold*, _italic_). Keep it punchy — no walls of text. End with the Hungary flag emoji.

SEARCH RESULTS:
$CONTENTS

SCHEDULE CROSS-REFERENCE:
$SCHEDULE_TEXT

RECENT FORM:
$FORM_TEXT

Remember: respond NO_MATCH unless the match is CONFIRMED for exactly $TODAY ($TODAY_WEEKDAY). When in doubt, NO_MATCH."

    ESCAPED_PROMPT=$(echo "$PROMPT" | ${pkgs.jq}/bin/jq -Rs .)

    GEMINI_RESPONSE=$(${pkgs.curl}/bin/curl -s --max-time 30 \
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$GEMINI_KEY" \
      -H "Content-Type: application/json" \
      -d '{
        "contents": [{"parts": [{"text": '"$ESCAPED_PROMPT"'}]}],
        "generationConfig": {"temperature": 0.7, "maxOutputTokens": 1500}
      }' 2>/dev/null)

    MSG=$(echo "$GEMINI_RESPONSE" | ${pkgs.jq}/bin/jq -r '.candidates[0].content.parts[0].text' 2>/dev/null)

    if [ -z "$MSG" ] || [ "$MSG" = "null" ]; then
      echo "[flu] Gemini response empty or failed"
      exit 0
    fi

    # Safety check: if Gemini determined no match, bail
    if echo "$MSG" | ${pkgs.gnugrep}/bin/grep -q "NO_MATCH"; then
      echo "[flu] Gemini confirmed no match today (false positive from search)"
      exit 0
    fi

    echo "[flu] Sending pre-game rundown..."
    ${waNotify} "" "$MSG"
    echo "[flu] Done!"
  '';
in
{
  options.homelab.services.openfang.fluminense = {
    enable = lib.mkEnableOption "Fluminense matchday pre-game notifications";
    geminiApiKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing the Gemini API key (used to compose the message)";
    };
    checkTime = lib.mkOption {
      type = lib.types.str;
      default = "09:00:00";
      description = "Daily check time (server timezone)";
    };
  };

  config = lib.mkIf (cfg.enable && flu.enable && cfg.tavilyApiKeyFile != null) {
    systemd.services.fluminense-matchday = {
      description = "Fluminense matchday pre-game notification";
      after = [ "openfang-whatsapp-gateway.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = matchdayScript;
      };
    };

    systemd.timers.fluminense-matchday = {
      description = "Daily Fluminense matchday check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* ${flu.checkTime}";
        Persistent = true;
      };
    };
  };
}
