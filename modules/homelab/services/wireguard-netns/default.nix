{
  pkgs,
  config,
  lib,
  ...
}:
let
  homelab = config.homelab;
  cfg = homelab.services.wireguard-netns;
in
{
  options.homelab.services.wireguard-netns = {
    enable = lib.mkEnableOption {
      description = "Enable Wireguard client network namespace";
    };
    namespace = lib.mkOption {
      type = lib.types.str;
      description = "Network namespace to be created";
      default = "wg_client";
    };
    monitoredServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        cfg.namespace
      ];
    };
    configFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to a wg-quick style Wireguard config file";
    };
  };
  config = lib.mkIf cfg.enable {
    systemd.services."netns@" = {
      description = "%I network namespace";
      before = [ "network.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.iproute2}/bin/ip netns add %I";
        ExecStop = "${pkgs.iproute2}/bin/ip netns del %I";
      };
    };
    environment.etc."netns/${cfg.namespace}/resolv.conf".text = "nameserver 10.64.0.1";

    systemd.services.${cfg.namespace} = {
      description = "${cfg.namespace} network interface";
      bindsTo = [ "netns@${cfg.namespace}.service" ];
      requires = [ "network-online.target" ];
      after = [ "netns@${cfg.namespace}.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart =
          with pkgs;
          writers.writeBash "wg-up" ''
            set -e

            # Parse wg-quick config
            CONFIG="${cfg.configFile}"
            PRIVATE_KEY=$(grep -oP 'PrivateKey\s*=\s*\K.*' "$CONFIG" | tr -d ' ')
            ADDRESS=$(grep -oP 'Address\s*=\s*\K.*' "$CONFIG" | tr -d ' ')
            PEER_KEY=$(grep -oP 'PublicKey\s*=\s*\K.*' "$CONFIG" | tr -d ' ')
            ENDPOINT=$(grep -oP 'Endpoint\s*=\s*\K.*' "$CONFIG" | tr -d ' ')
            ALLOWED_IPS=$(grep -oP 'AllowedIPs\s*=\s*\K.*' "$CONFIG" | tr -d ' ')

            # Create WireGuard interface in namespace
            ${iproute2}/bin/ip link add wg0 type wireguard
            ${iproute2}/bin/ip link set wg0 netns ${cfg.namespace}

            # Configure WireGuard
            ${iproute2}/bin/ip netns exec ${cfg.namespace} \
              ${wireguard-tools}/bin/wg set wg0 \
                private-key <(echo "$PRIVATE_KEY") \
                peer "$PEER_KEY" \
                endpoint "$ENDPOINT" \
                allowed-ips "$ALLOWED_IPS"

            # Set address and bring up
            ${iproute2}/bin/ip -n ${cfg.namespace} address add "$ADDRESS" dev wg0
            ${iproute2}/bin/ip -n ${cfg.namespace} link set wg0 up
            ${iproute2}/bin/ip -n ${cfg.namespace} link set lo up
            ${iproute2}/bin/ip -n ${cfg.namespace} route add default dev wg0
          '';
        ExecStop =
          with pkgs;
          writers.writeBash "wg-down" ''
            set -e
            ${iproute2}/bin/ip -n ${cfg.namespace} route del default dev wg0
            ${iproute2}/bin/ip -n ${cfg.namespace} link del wg0
          '';
      };
    };
  };
}
