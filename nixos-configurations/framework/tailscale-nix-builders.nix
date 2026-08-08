{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  primaryUser = config.dev.johnrinehart.users.primary;
  stateDirectory = "tailscale-nix-builders";
  statePath = "/var/lib/${stateDirectory}";
  machinesFile = "/etc/nix/machines";
  sshKey = "/home/${primaryUser}/.ssh/id_ed25519_neocache_cloud_ci_builder";
  maxJobs = 4;
  builderUserIds = [
    "17597721195653961"
    "29860812111823113"
  ];
  preferredBuilderUserId = "29860812111823113";
  supportedFeatures = [
    "benchmark"
    "big-parallel"
    "kvm"
    "nixos-test"
  ];
  allowedUsersFile = pkgs.writeText "tailscale-nix-builder-users.json" (
    builtins.toJSON (
      lib.genAttrs builderUserIds (userId: if userId == preferredBuilderUserId then 2 else 1)
    )
  );
  generator = pkgs.callPackage ./tailscale-nix-builders-package.nix { };
  generatorArgs = [
    (lib.getExe generator)
    machinesFile
    statePath
    allowedUsersFile
    sshKey
    primaryUser
    maxJobs
    (lib.concatStringsSep "," supportedFeatures)
  ];
in
{
  assertions = [
    {
      assertion = config.services.tailscale.enable;
      message = "Framework's dynamic Nix builders require services.tailscale.enable.";
    }
  ];

  nix = {
    distributedBuilds = true;
    # nix __build-remote reads this indirection for each dispatch, so an atomic
    # replacement takes effect without restarting nix-daemon.
    settings.builders = "@${machinesFile}";
  };

  systemd.tmpfiles.rules = [
    "d /etc/nix 0755 root root -"
  ];

  systemd.services.tailscale-nix-builders = {
    description = "Discover reachable Nix builders shared through Tailscale";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "network-online.target"
      "tailscaled.service"
    ];
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = utils.escapeSystemdExecArgs generatorArgs;
      TimeoutStartSec = "50s";

      StateDirectory = stateDirectory;
      StateDirectoryMode = "0700";
      UMask = "0077";

      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = "read-only";
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/etc/nix" ];
      RestrictSUIDSGID = true;
    };
  };

  systemd.timers.tailscale-nix-builders = {
    description = "Refresh Tailscale Nix builders every 60 seconds";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10s";
      OnUnitActiveSec = "60s";
      AccuracySec = "1s";
      Persistent = true;
      Unit = "tailscale-nix-builders.service";
    };
  };
}
