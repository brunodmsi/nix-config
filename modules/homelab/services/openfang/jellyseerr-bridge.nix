# Jellyseerr integration: tool script for OpenFang + webhook handler for notifications
{
  config,
  lib,
  pkgs,
  ...
}:
let
  homelab = config.homelab;
  cfg = homelab.services.openfang;
  jsCfg = cfg.jellyseerr;
  dbUrl = "postgresql://openfang@127.0.0.1:5432/openfang";
  gatewayUrl = "http://127.0.0.1:${toString cfg.whatsappGatewayPort}";

  # Jellyseerr CLI tool for OpenFang agent
  jellyseerrTool = pkgs.writeShellScript "jellyseerr-tool" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.postgresql}/bin:$PATH
    API_KEY=$(cat ${jsCfg.apiKeyFile})
    API_URL="http://127.0.0.1:5055/api/v1"
    DB="${dbUrl}"

    # Normalize phone: ensure + prefix, strip spaces
    normalize_phone() {
      local p="$1"
      p=$(echo "$p" | tr -d ' ')
      case "$p" in
        +*) echo "$p" ;;
        *) echo "+$p" ;;
      esac
    }

    case "$1" in
      search)
        QUERY="$2"
        RESULTS=$(curl -s "$API_URL/search?query=$(echo "$QUERY" | sed 's/ /%20/g')&language=en" \
          -H "X-Api-Key: $API_KEY")
        echo "$RESULTS" | jq -r '.results[:5][] | "\(.mediaType // "unknown") | \(.title // .name // "Unknown") (\(.releaseDate // .firstAirDate // "?" | split("-")[0])) | TMDB ID: \(.id)"'
        ;;

      details)
        TMDB_ID="$2"
        DETAILS=$(curl -s "$API_URL/tv/$TMDB_ID" -H "X-Api-Key: $API_KEY")
        NAME=$(echo "$DETAILS" | jq -r '.name // "Unknown"')
        YEAR=$(echo "$DETAILS" | jq -r '.firstAirDate // "?" | split("-")[0]')
        NUM_SEASONS=$(echo "$DETAILS" | jq -r '.numberOfSeasons // 0')
        SEASONS=$(echo "$DETAILS" | jq -r '[.seasons[] | select(.seasonNumber > 0) | "S\(.seasonNumber) (\(.episodeCount) eps)"] | join(", ")')
        OVERVIEW=$(echo "$DETAILS" | jq -r '.overview // "No description" | .[0:200]')
        echo "$NAME ($YEAR) — $NUM_SEASONS seasons"
        echo "Seasons: $SEASONS"
        echo "Overview: $OVERVIEW"
        ;;

      request)
        TYPE="$2"        # movie or tv
        TMDB_ID="$3"
        SEASONS="$4"     # "all" or "1,2,3" (for TV) / ignored for movie
        CHANNEL="$5"     # whatsapp, discord, telegram
        CHAN_USER="$6"    # phone number, discord ID, etc
        DISPLAY="$7"     # display name

        # Normalize phone
        CHAN_USER=$(normalize_phone "$CHAN_USER")

        # For movie, shift args back (no seasons arg)
        if [ "$TYPE" = "movie" ]; then
          CHANNEL="$4"
          CHAN_USER=$(normalize_phone "$5")
          DISPLAY="$6"
          RESPONSE=$(curl -s -X POST "$API_URL/request" \
            -H "X-Api-Key: $API_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"mediaType\":\"movie\",\"mediaId\":$TMDB_ID}")
        else
          if [ "$SEASONS" = "all" ]; then
            RESPONSE=$(curl -s -X POST "$API_URL/request" \
              -H "X-Api-Key: $API_KEY" \
              -H "Content-Type: application/json" \
              -d "{\"mediaType\":\"tv\",\"mediaId\":$TMDB_ID,\"seasons\":\"all\"}")
          else
            # Convert "1,2,3" to JSON array [1,2,3]
            SEASONS_JSON="[$(echo "$SEASONS" | sed 's/,/, /g')]"
            RESPONSE=$(curl -s -X POST "$API_URL/request" \
              -H "X-Api-Key: $API_KEY" \
              -H "Content-Type: application/json" \
              -d "{\"mediaType\":\"tv\",\"mediaId\":$TMDB_ID,\"seasons\":$SEASONS_JSON}")
          fi
        fi

        REQ_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
        ERROR=$(echo "$RESPONSE" | jq -r '.message // empty')

        if [ -z "$REQ_ID" ] || [ "$REQ_ID" = "null" ]; then
          echo "Request failed: $ERROR"
          exit 1
        fi

        # Get title from TMDB details
        if [ "$TYPE" = "movie" ]; then
          TITLE=$(curl -s "$API_URL/movie/$TMDB_ID" -H "X-Api-Key: $API_KEY" | jq -r '.title // "Unknown"')
        else
          TITLE=$(curl -s "$API_URL/tv/$TMDB_ID" -H "X-Api-Key: $API_KEY" | jq -r '.name // "Unknown"')
        fi

        # Sanitize inputs for SQL (escape single quotes)
        SAFE_DISPLAY=$(echo "$DISPLAY" | sed "s/'/''''/g")
        SAFE_TITLE=$(echo "$TITLE" | sed "s/'/''''/g")

        # Upsert channel user (separate insert + select to avoid mixed output)
        psql -c "INSERT INTO channel_users (channel, channel_user_id, display_name) VALUES ('$CHANNEL', '$CHAN_USER', '$SAFE_DISPLAY') ON CONFLICT (channel, channel_user_id) DO UPDATE SET display_name = '$SAFE_DISPLAY';" "$DB" 2>/dev/null
        USER_ID=$(psql -t -A -c "SELECT id FROM channel_users WHERE channel = '$CHANNEL' AND channel_user_id = '$CHAN_USER';" "$DB")

        # Track the request
        psql -c "INSERT INTO media_requests (jellyseerr_request_id, tmdb_id, title, media_type, channel_user_id) VALUES ('$REQ_ID', '$TMDB_ID', '$SAFE_TITLE', '$TYPE', $USER_ID);" "$DB" 2>/dev/null

        echo "Request submitted! ID: $REQ_ID. You'll be notified when \"$TITLE\" is available."
        ;;

      status)
        CHANNEL="$2"
        CHAN_USER=$(normalize_phone "$3")

        RESULTS=$(psql -t -A -F'|' -c "SELECT mr.jellyseerr_request_id, mr.title, mr.media_type, mr.tmdb_id FROM media_requests mr JOIN channel_users cu ON mr.channel_user_id = cu.id WHERE cu.channel = '$CHANNEL' AND cu.channel_user_id = '$CHAN_USER' AND mr.status != 'cancelled' ORDER BY mr.requested_at DESC LIMIT 10;" "$DB")

        if [ -z "$RESULTS" ]; then
          echo "No requests found."
          exit 0
        fi

        echo "Your requests:"
        echo "$RESULTS" | while IFS='|' read -r REQ_ID TITLE MTYPE TMDB_ID; do
          # Get live status from Jellyseerr media endpoint
          if [ "$MTYPE" = "movie" ]; then
            MEDIA=$(curl -s "$API_URL/movie/$TMDB_ID" -H "X-Api-Key: $API_KEY" 2>/dev/null)
          else
            MEDIA=$(curl -s "$API_URL/tv/$TMDB_ID" -H "X-Api-Key: $API_KEY" 2>/dev/null)
          fi

          MEDIA_STATUS=$(echo "$MEDIA" | jq -r '.mediaInfo.status // 0' 2>/dev/null)
          case "$MEDIA_STATUS" in
            1) DISPLAY_STATUS="pending approval" ;;
            2) DISPLAY_STATUS="processing" ;;
            3) DISPLAY_STATUS="available" ;;
            4) DISPLAY_STATUS="partially available" ;;
            5) DISPLAY_STATUS="available" ;;
            *) DISPLAY_STATUS="unknown" ;;
          esac

          # For TV, show per-season status from request seasons
          SEASON_INFO=""
          if [ "$MTYPE" = "tv" ]; then
            SEASON_INFO=$(echo "$MEDIA" | jq -r '
              [.mediaInfo.requests // [] | .[].seasons // [] | .[] |
                "S" + (.seasonNumber | tostring) + ": " +
                (if .status == 5 then "available"
                 elif .status == 4 then "partially available"
                 elif .status == 3 then "available"
                 elif .status == 2 then "processing"
                 elif .status == 1 then "pending"
                 else "unknown" end)
              ] | join(", ")' 2>/dev/null)
          fi

          # Show download progress (group by downloadId to avoid per-episode spam)
          DL_INFO=$(echo "$MEDIA" | jq -r '
            [.mediaInfo.downloadStatus // [] | group_by(.downloadId) | .[] | .[0] |
              (.status) + " " +
              (if .size > 0 then ((((.size - .sizeLeft) * 100 / .size) | floor | tostring) + "%") else "0%" end) +
              " (ETA: " + (.timeLeft // "unknown") + ")"
            ] | unique | join(", ")' 2>/dev/null)
          if [ -n "$DL_INFO" ] && [ "$DL_INFO" != "" ]; then
            SEASON_INFO="$SEASON_INFO | $DL_INFO"
          fi

          if [ -n "$SEASON_INFO" ]; then
            echo "- $TITLE ($MTYPE) | $DISPLAY_STATUS | Seasons: $SEASON_INFO | ID: $REQ_ID"
          else
            echo "- $TITLE ($MTYPE) | $DISPLAY_STATUS | ID: $REQ_ID"
          fi
        done
        ;;

      delete)
        REQ_ID="$2"
        CHANNEL="$3"
        CHAN_USER=$(normalize_phone "$4")

        # Verify ownership
        OWNER=$(psql -t -A -c "SELECT cu.channel_user_id FROM media_requests mr JOIN channel_users cu ON mr.channel_user_id = cu.id WHERE mr.jellyseerr_request_id = '$REQ_ID' AND cu.channel = '$CHANNEL' LIMIT 1;" "$DB")

        if [ "$OWNER" != "$CHAN_USER" ]; then
          echo "Error: Request $REQ_ID does not belong to you."
          exit 1
        fi

        # Delete from Jellyseerr
        DEL_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$API_URL/request/$REQ_ID" -H "X-Api-Key: $API_KEY")

        if [ "$DEL_RESP" = "204" ] || [ "$DEL_RESP" = "200" ]; then
          psql -c "UPDATE media_requests SET status = 'cancelled' WHERE jellyseerr_request_id = '$REQ_ID';" "$DB" 2>/dev/null
          TITLE=$(psql -t -A -c "SELECT title FROM media_requests WHERE jellyseerr_request_id = '$REQ_ID';" "$DB")
          echo "Deleted request for \"$TITLE\" (ID: $REQ_ID)."
        else
          echo "Failed to delete request $REQ_ID (HTTP $DEL_RESP)."
          exit 1
        fi
        ;;

      *)
        echo "Commands: search, details, request, status, delete"
        ;;
    esac
  '';

  # Webhook handler for Jellyseerr notifications
  jellyseerrWebhookHandler = pkgs.writeShellScript "jellyseerr-webhook-handler" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.postgresql}/bin:$PATH
    DB="${dbUrl}"

    read -r REQUEST_LINE
    CONTENT_LENGTH=0
    while IFS= read -r header; do
      header=$(echo "$header" | tr -d '\r')
      [ -z "$header" ] && break
      case "$header" in
        Content-Length:*|content-length:*) CONTENT_LENGTH=$(echo "$header" | cut -d: -f2 | tr -d ' ') ;;
      esac
    done

    BODY=""
    if [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
      BODY=$(head -c "$CONTENT_LENGTH")
    fi

    echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\n\r\n{\"ok\":true}"

    if [ -n "$BODY" ]; then
      NOTIF_TYPE=$(echo "$BODY" | jq -r '.notification_type // empty')
      SUBJECT=$(echo "$BODY" | jq -r '.subject // empty')
      REQUEST_ID=$(echo "$BODY" | jq -r '.request.request_id // .media.tmdbId // empty')

      if [ -z "$NOTIF_TYPE" ] || [ -z "$REQUEST_ID" ]; then
        exit 0
      fi

      # Look up who requested this (include remote_jid for WhatsApp LID routing)
      RESULT=$(psql -t -A -F'|' -c "SELECT cu.channel, cu.channel_user_id, mr.title, cu.remote_jid FROM media_requests mr JOIN channel_users cu ON mr.channel_user_id = cu.id WHERE mr.jellyseerr_request_id = '$REQUEST_ID' LIMIT 1;" "$DB")

      if [ -z "$RESULT" ]; then
        echo "[jellyseerr] No channel user found for request $REQUEST_ID — skipping" >&2
        exit 0
      fi

      CHANNEL=$(echo "$RESULT" | cut -d'|' -f1)
      CHAN_USER=$(echo "$RESULT" | cut -d'|' -f2)
      TITLE=$(echo "$RESULT" | cut -d'|' -f3)
      REMOTE_JID=$(echo "$RESULT" | cut -d'|' -f4)
      [ -z "$TITLE" ] && TITLE="$SUBJECT"

      # Format message based on event
      case "$NOTIF_TYPE" in
        *AVAILABLE*|*available*)
          MSG="🎬 *$TITLE* is now available on Jellyfin! Enjoy watching."
          psql -c "UPDATE media_requests SET status = 'available' WHERE jellyseerr_request_id = '$REQUEST_ID';" "$DB" 2>/dev/null
          ;;
        *APPROVED*|*approved*)
          MSG="✅ *$TITLE* has been approved and is being downloaded."
          psql -c "UPDATE media_requests SET status = 'approved' WHERE jellyseerr_request_id = '$REQUEST_ID';" "$DB" 2>/dev/null
          ;;
        *DECLINED*|*declined*)
          MSG="❌ *$TITLE* was declined."
          psql -c "UPDATE media_requests SET status = 'declined' WHERE jellyseerr_request_id = '$REQUEST_ID';" "$DB" 2>/dev/null
          ;;
        *)
          MSG="📋 Update on *$TITLE*: $NOTIF_TYPE"
          ;;
      esac

      # Send notification via WhatsApp gateway (use remote_jid for LID routing)
      if [ "$CHANNEL" = "whatsapp" ]; then
        SEND_TO="$CHAN_USER"
        if [ -n "$REMOTE_JID" ]; then
          SEND_TO="$REMOTE_JID"
        fi
        curl -s -X POST "${gatewayUrl}/message/send" \
          -H "Content-Type: application/json" \
          -d "{\"to\": \"$SEND_TO\", \"text\": $(echo "$MSG" | jq -Rs .)}" >/dev/null
        echo "[jellyseerr] Sent $NOTIF_TYPE notification to $SEND_TO on $CHANNEL" >&2
      else
        echo "[jellyseerr] Channel '$CHANNEL' not yet supported for notifications" >&2
      fi
    fi
  '';

  jellyseerrWebhookReceiver = pkgs.writeShellScript "jellyseerr-webhook-receiver" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.socat}/bin:$PATH
    echo "[jellyseerr] Webhook listener on port ${toString jsCfg.webhookPort}"
    while true; do
      ${pkgs.socat}/bin/socat TCP-LISTEN:${toString jsCfg.webhookPort},reuseaddr,fork EXEC:"${jellyseerrWebhookHandler}"
    done
  '';
in
{
  config = lib.mkIf (cfg.enable && jsCfg.enable) {
    # Install tool script for OpenFang
    systemd.tmpfiles.rules = [
      "d /persist/openfang/scripts 0755 root root - -"
      "L+ /persist/openfang/scripts/jellyseerr-tool.sh - - - - ${jellyseerrTool}"
    ];

    # Jellyseerr webhook listener
    systemd.services.jellyseerr-whatsapp-bridge = {
      description = "Jellyseerr to WhatsApp notification bridge";
      after = [ "network-online.target" "openfang-whatsapp-gateway.service" "postgresql.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = jellyseerrWebhookReceiver;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
