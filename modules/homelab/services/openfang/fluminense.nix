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

    echo "[flu] Checking Fluminense matchday for $TODAY..."

    # Step 1: Search for today's match
    SEARCH=$(${pkgs.curl}/bin/curl -s --max-time 15 -X POST "https://api.tavily.com/search" \
      -H "Content-Type: application/json" \
      -d '{
        "query": "Fluminense jogo hoje '"$TODAY"' horario adversario campeonato",
        "search_depth": "basic",
        "max_results": 5,
        "include_answer": true
      }' 2>/dev/null)

    if [ -z "$SEARCH" ]; then
      echo "[flu] Tavily search failed"
      exit 0
    fi

    # Check if results indicate a match today
    CONTENTS=$(echo "$SEARCH" | ${pkgs.jq}/bin/jq -r '(.answer // "") + " " + ([.results[].content] | join(" "))' 2>/dev/null)

    # Look for patterns indicating a match today: "Fluminense x", "x Fluminense", time patterns like "21h", "19h30"
    HAS_MATCH=$(echo "$CONTENTS" | ${pkgs.gnugrep}/bin/grep -icP "(fluminense\s*(x|vs|contra)\s)|(\s(x|vs|contra)\s*fluminense)|(\d{1,2}h\d{0,2}.*fluminense)|(fluminense.*\d{1,2}h\d{0,2})" || echo "0")

    if [ "$HAS_MATCH" -eq 0 ]; then
      echo "[flu] No Fluminense match today"
      exit 0
    fi

    echo "[flu] Match detected! Gathering context..."

    # Step 2: Get more context — opponent form + head-to-head
    CONTEXT_FORM=$(${pkgs.curl}/bin/curl -s --max-time 15 -X POST "https://api.tavily.com/search" \
      -H "Content-Type: application/json" \
      -d '{
        "query": "Fluminense ultimos jogos resultados '"$TODAY_ISO"'",
        "search_depth": "basic",
        "max_results": 3,
        "include_answer": true
      }' 2>/dev/null)

    FORM_TEXT=$(echo "$CONTEXT_FORM" | ${pkgs.jq}/bin/jq -r '(.answer // "") + " " + ([.results[].content] | join(" "))' 2>/dev/null)

    # Step 3: Compose via Gemini
    PROMPT="You are Fluzy, a WhatsApp assistant with Fluminense (Tricolor das Laranjeiras) energy — laid back, carioca, debochado, but PASSIONATE about Flu. You speak with carioca slang (po, mermao, suave, ta ligado, firmeza, caraca).

Based on the following search results about today's Fluminense match, compose a pre-game WhatsApp message for Bruno (a fellow Tricolor). Include:
- The matchup, competition, time, and venue
- How the opponent has been doing lately
- Recent head-to-head results if available
- How Fluminense is arriving to the match
- A little hype/commentary in your sassy style

Use WhatsApp formatting (*bold*, _italic_). Keep it punchy — no walls of text. End with the Hungary flag emoji.

SEARCH RESULTS (today's match):
$CONTENTS

RECENT FORM:
$FORM_TEXT

If the search results do NOT actually confirm a Fluminense match TODAY ($TODAY), respond with exactly: NO_MATCH"

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
