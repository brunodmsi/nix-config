# Car Scout Hand: autonomous used car listing monitor with WhatsApp control via Fluzy
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.services.openfang;
  csCfg = cfg.carScout;
  openfangBin = "${cfg.configDir}/.openfang/bin/openfang";
  openfangConfig = "/etc/openfang/config.toml";
  dataDir = "/persist/openfang/car-scout";
  configFile = "${dataDir}/searches.json";
  seenFile = "${dataDir}/seen-listings.txt";
  gatewayUrl = "http://127.0.0.1:${toString cfg.whatsappGatewayPort}";

  handDir = ./hands/car-scout;

  # --- car-scout-tool.sh: config management for Fluzy ---
  carScoutToolScript = pkgs.writeShellScript "car-scout-tool" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.jq}/bin:$PATH

    CONFIG="${configFile}"
    SEEN="${seenFile}"
    OPENFANG_BIN="${openfangBin}"
    OPENFANG_CONFIG="${openfangConfig}"

    # Ensure files exist
    [ -f "$CONFIG" ] || echo '[]' > "$CONFIG"
    [ -f "$SEEN" ] || touch "$SEEN"

    usage() {
      echo "Car Scout config manager"
      echo ""
      echo "Commands:"
      echo "  add       Add a search watch"
      echo "  remove    Remove a search by index (0-based)"
      echo "  list      Show all active searches"
      echo "  clear     Remove all searches"
      echo "  set-phone Set WhatsApp notification number"
      echo "  trigger   Run Car Scout immediately"
      echo "  pause     Pause scheduled runs"
      echo "  resume    Resume scheduled runs"
      echo "  status    Show Hand status and config"
      echo ""
      echo "add usage:"
      echo "  car-scout-tool.sh add --models civic,corolla --location Budapest --country HU --currency HUF --platforms hasznaltauto.hu --budget-max 5000000"
      echo ""
      echo "Optional add flags: --budget-min N --min-year N --max-km N"
    }

    case "$1" in
      add)
        shift
        MODELS=""
        LOCATION=""
        COUNTRY=""
        CURRENCY=""
        PLATFORMS=""
        BUDGET_MIN=""
        BUDGET_MAX=""
        MIN_YEAR=""
        MAX_KM=""

        while [ $# -gt 0 ]; do
          case "$1" in
            --models) MODELS="$2"; shift 2 ;;
            --location) LOCATION="$2"; shift 2 ;;
            --country) COUNTRY="$2"; shift 2 ;;
            --currency) CURRENCY="$2"; shift 2 ;;
            --platforms) PLATFORMS="$2"; shift 2 ;;
            --budget-min) BUDGET_MIN="$2"; shift 2 ;;
            --budget-max) BUDGET_MAX="$2"; shift 2 ;;
            --min-year) MIN_YEAR="$2"; shift 2 ;;
            --max-km) MAX_KM="$2"; shift 2 ;;
            *) echo "Unknown flag: $1"; exit 1 ;;
          esac
        done

        if [ -z "$MODELS" ] || [ -z "$LOCATION" ] || [ -z "$CURRENCY" ]; then
          echo "Error: --models, --location, and --currency are required"
          exit 1
        fi

        # Build JSON entry
        MODELS_JSON=$(echo "$MODELS" | tr ',' '\n' | jq -R . | jq -s .)
        PLATFORMS_JSON="[]"
        if [ -n "$PLATFORMS" ]; then
          PLATFORMS_JSON=$(echo "$PLATFORMS" | tr ',' '\n' | jq -R . | jq -s .)
        fi

        ENTRY=$(jq -n \
          --argjson models "$MODELS_JSON" \
          --arg location "$LOCATION" \
          --arg country "''${COUNTRY:-}" \
          --arg currency "$CURRENCY" \
          --argjson platforms "$PLATFORMS_JSON" \
          --arg budget_min "''${BUDGET_MIN:-}" \
          --arg budget_max "''${BUDGET_MAX:-}" \
          --arg min_year "''${MIN_YEAR:-}" \
          --arg max_km "''${MAX_KM:-}" \
          '{
            models: $models,
            location: $location,
            currency: $currency,
            platforms: $platforms
          }
          + (if $country != "" then {country: $country} else {} end)
          + (if $budget_min != "" then {budget_min: ($budget_min | tonumber)} else {} end)
          + (if $budget_max != "" then {budget_max: ($budget_max | tonumber)} else {} end)
          + (if $min_year != "" then {min_year: ($min_year | tonumber)} else {} end)
          + (if $max_km != "" then {max_km: ($max_km | tonumber)} else {} end)')

        # Append to config
        jq ". + [$ENTRY]" "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"

        COUNT=$(jq length "$CONFIG")
        echo "Search added. You now have $COUNT active search(es)."
        echo ""
        echo "$ENTRY" | jq .
        ;;

      remove)
        INDEX="$2"
        if [ -z "$INDEX" ]; then
          echo "Error: provide search index (0-based). Use 'list' to see indexes."
          exit 1
        fi

        TOTAL=$(jq length "$CONFIG")
        if [ "$INDEX" -ge "$TOTAL" ] 2>/dev/null; then
          echo "Error: index $INDEX out of range (have $TOTAL searches)"
          exit 1
        fi

        REMOVED=$(jq ".[$INDEX]" "$CONFIG")
        jq "del(.[$INDEX])" "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"

        echo "Removed search #$INDEX:"
        echo "$REMOVED" | jq .
        echo ""
        echo "$(jq length "$CONFIG") search(es) remaining."
        ;;

      list)
        COUNT=$(jq length "$CONFIG")
        if [ "$COUNT" -eq 0 ]; then
          echo "No active searches."
          exit 0
        fi

        echo "$COUNT active search(es):"
        echo ""
        jq -r 'to_entries[] | "#\(.key): \(.value.models | join(", ")) in \(.value.location) (\(.value.currency)) max \(.value.budget_max // "no limit") | platforms: \(.value.platforms | join(", "))"' "$CONFIG"
        ;;

      clear)
        echo '[]' > "$CONFIG"
        echo "All searches cleared."
        ;;

      set-phone)
        PHONE="$2"
        if [ -z "$PHONE" ]; then
          echo "Error: provide phone number (e.g. +5511999999999)"
          exit 1
        fi
        echo "$PHONE" > "${dataDir}/notify-phone.txt"
        echo "Notification phone set to $PHONE"
        ;;

      trigger)
        export HOME=${cfg.configDir}
        $OPENFANG_BIN hand activate car-scout --config "$OPENFANG_CONFIG" 2>&1 || echo "Note: Hand may already be active"
        echo "Car Scout triggered. Results will be sent via WhatsApp."
        ;;

      pause)
        export HOME=${cfg.configDir}
        $OPENFANG_BIN hand pause car-scout --config "$OPENFANG_CONFIG" 2>&1
        echo "Car Scout paused."
        ;;

      resume)
        export HOME=${cfg.configDir}
        $OPENFANG_BIN hand resume car-scout --config "$OPENFANG_CONFIG" 2>&1
        echo "Car Scout resumed."
        ;;

      status)
        export HOME=${cfg.configDir}
        echo "Hand status:"
        $OPENFANG_BIN hand status car-scout --config "$OPENFANG_CONFIG" 2>&1 || echo "Hand not installed or inactive"
        echo ""
        echo "Active searches: $(jq length "$CONFIG")"
        echo "Seen listings: $(wc -l < "$SEEN" | tr -d ' ')"
        ;;

      *)
        usage
        ;;
    esac
  '';

in
{
  options.homelab.services.openfang.carScout = {
    enable = lib.mkEnableOption "Car Scout Hand (used car listing monitor)";
    apiKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing the Gemini API key (GEMINI_API_KEY)";
    };
  };

  config = lib.mkIf (cfg.enable && csCfg.enable) {
    # Ensure data directory and files exist
    systemd.tmpfiles.rules = [
      "d ${dataDir} 0750 root root - -"
      "f ${configFile} 0640 root root - []"
      "f ${seenFile} 0640 root root -"
      "L+ /persist/openfang/scripts/car-scout-tool.sh - - - - ${carScoutToolScript}"
    ];

    # Install Hand after every openfang (re)start — registrations are in-memory
    systemd.services.openfang-install-car-scout = {
      description = "Install Car Scout Hand";
      after = [ "openfang-install.service" "openfang.service" ];
      requires = [ "openfang-install.service" ];
      wantedBy = [ "multi-user.target" ];
      bindsTo = [ "openfang.service" ];
      environment.HOME = cfg.configDir;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "install-car-scout" ''
          export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:$PATH
          export HOME=${cfg.configDir}
          export GEMINI_API_KEY=$(cat ${csCfg.apiKeyFile})

          HAND_INSTALL_DIR="${cfg.configDir}/.openfang/hands/car-scout"
          mkdir -p "$HAND_INSTALL_DIR"

          cp ${handDir}/HAND.toml "$HAND_INSTALL_DIR/"
          cp ${handDir}/SKILL.md "$HAND_INSTALL_DIR/"

          # Wait for OpenFang daemon to be ready
          for i in $(seq 1 30); do
            ${pkgs.curl}/bin/curl -sf "http://127.0.0.1:${toString cfg.listenPort}/api/agents" >/dev/null 2>&1 && break
            sleep 2
          done

          ${openfangBin} hand install "$HAND_INSTALL_DIR" --config ${openfangConfig} 2>&1 || echo "[car-scout] Install failed or already installed"

          echo "[car-scout] Hand installed"
        '';
      };
    };

    # Make GEMINI_API_KEY available to the OpenFang process for Hand execution
    systemd.services.openfang-gemini-env = {
      description = "Generate Gemini API key environment file for Car Scout";
      before = [ "openfang.service" ];
      after = [ "openfang-install.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "gen-gemini-env" ''
          export PATH=${pkgs.coreutils}/bin:$PATH
          echo "GEMINI_API_KEY=$(cat ${csCfg.apiKeyFile})" > /run/openfang-gemini.env
          chmod 600 /run/openfang-gemini.env
        '';
      };
    };
    systemd.services.openfang = {
      after = [ "openfang-gemini-env.service" ];
      requires = [ "openfang-gemini-env.service" ];
      serviceConfig.EnvironmentFile = [ "/run/openfang-gemini.env" ];
    };
  };
}
