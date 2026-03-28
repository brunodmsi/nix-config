# Per-sender agent router — routes WhatsApp messages to per-user OpenFang agents
# Includes media handling: Paperless upload for documents, local whisper for audio, Gemini vision for images
{
  config,
  lib,
  pkgs,
  ...
}:
let
  homelab = config.homelab;
  cfg = homelab.services.openfang;
  plCfg = cfg.paperless;
  dbUrl = "postgresql://openfang@127.0.0.1:5432/openfang";
  routerPort = 50052;
  openfangApi = "http://127.0.0.1:50051";
  paperlessApiUrl = "http://127.0.0.1:${toString plCfg.port}";

  # Find the Gemini fallback provider's API key file (for audio transcription)
  geminiProvider = lib.findFirst (fb: fb.provider == "google") null cfg.fallbackProviders;
  geminiApiKeyFile = if geminiProvider != null then geminiProvider.apiKeyFile else null;

  # Bundle router + media handler into a single directory so ES module imports work
  routerBundle = pkgs.runCommand "openfang-message-router" {} ''
    mkdir -p $out
    cp ${pkgs.writeTextFile { name = "message-router.mjs"; text = builtins.readFile ./message-router.js; }} $out/message-router.js
    cp ${pkgs.writeTextFile { name = "media-handler.mjs"; text = builtins.readFile ./media-handler.js; }} $out/media-handler.js
  '';

  # Script to upload an image to Paperless (called by Fluzy via shell_exec after user confirms)
  paperlessUploadScript = pkgs.writeShellScript "paperless-upload" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:$PATH
    FILE_PATH="$1"
    SENDER="$2"

    if [ ! -f "$FILE_PATH" ]; then
      echo "Error: File not found: $FILE_PATH"
      exit 1
    fi

    PAPERLESS_TOKEN=$(cat ${plCfg.apiKeyFile} 2>/dev/null || echo "")
    if [ -z "$PAPERLESS_TOKEN" ]; then
      echo "Error: Paperless API token not available"
      exit 1
    fi

    FILENAME=$(basename "$FILE_PATH")
    RESULT=$(${pkgs.curl}/bin/curl -s -w "\n%{http_code}" \
      -X POST "${paperlessApiUrl}/api/documents/post_document/" \
      -H "Authorization: Token $PAPERLESS_TOKEN" \
      -F "document=@$FILE_PATH" \
      -F "title=$FILENAME")

    HTTP_CODE=$(echo "$RESULT" | tail -1)
    BODY=$(echo "$RESULT" | head -n -1)

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
      echo "Uploaded $FILENAME to Paperless successfully."
      rm -f "$FILE_PATH"
    else
      echo "Upload failed (HTTP $HTTP_CODE): $BODY"
    fi
  '';
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.openfang-message-router = {
      description = "OpenFang per-sender message router";
      after = [ "openfang.service" "postgresql.service" "openfang-db-init.service" ];
      requires = [ "openfang.service" "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ bash coreutils curl jq postgresql ffmpeg-headless whisper-cpp ];
      environment = {
        HOME = cfg.configDir;
        ROUTER_PORT = toString routerPort;
        OPENFANG_API = openfangApi;
        DB_URL = dbUrl;
        OPENFANG_BIN = "${cfg.configDir}/.openfang/bin/openfang";
        OPENFANG_CONFIG = "${cfg.configDir}/.openfang/config.toml";
        MANIFEST_PATH = "/etc/openfang/agent-manifest.toml";
        ALLOWED_SENDERS_FILE = cfg.allowedSendersFile;
        GATEWAY_URL = "http://127.0.0.1:3010";
        PAPERLESS_API_URL = paperlessApiUrl;
        FFMPEG_PATH = "${pkgs.ffmpeg-headless}/bin/ffmpeg";
        WHISPER_PATH = "${pkgs.whisper-cpp}/bin/whisper-cli";
        WHISPER_MODEL = "${cfg.configDir}/models/ggml-base.bin";
        MEDIA_TMP_DIR = "${cfg.configDir}/media-tmp";
      };
      serviceConfig = {
        ExecStartPre = pkgs.writeShellScript "router-load-secrets" ''
          export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:$PATH
          mkdir -p ${cfg.configDir}/media-tmp
          mkdir -p ${cfg.configDir}/models

          # Download whisper model if not present
          if [ ! -f "${cfg.configDir}/models/ggml-base.bin" ]; then
            echo "[router] Downloading whisper base model..."
            ${pkgs.curl}/bin/curl -fsSL -o "${cfg.configDir}/models/ggml-base.bin" \
              "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
            echo "[router] Whisper model downloaded"
          fi
        '';
        ExecStart = pkgs.writeShellScript "openfang-router-run" ''
          ${lib.optionalString plCfg.enable ''
          export PAPERLESS_API_TOKEN=$(cat ${plCfg.apiKeyFile} 2>/dev/null || echo "")
          ''}
          ${lib.optionalString (geminiApiKeyFile != null) ''
          export GEMINI_API_KEY=$(cat ${geminiApiKeyFile} 2>/dev/null || echo "")
          ''}
          exec ${pkgs.nodejs_22}/bin/node ${routerBundle}/message-router.js
        '';
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # Paperless upload script for Fluzy to call via shell_exec (for images after user confirms)
    systemd.tmpfiles.rules = [
      "d ${cfg.configDir}/media-tmp 0755 root root 7d -"
    ] ++ lib.optionals plCfg.enable [
      "L+ /persist/openfang/scripts/paperless-upload.sh - - - - ${paperlessUploadScript}"
    ];
  };
}
