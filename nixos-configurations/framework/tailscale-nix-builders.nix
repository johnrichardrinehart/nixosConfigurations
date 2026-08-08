{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  primaryUser = config.dev.johnrinehart.users.primary;
  primaryGroup = config.users.users.${primaryUser}.group;
  stateDirectory = "tailscale-nix-builders-user";
  statePath = "/home/${primaryUser}/.local/state/${stateDirectory}";
  machinesFile = "${statePath}/machines";
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

  # Bootstrap the user-owned state directory before systemd starts the user unit.
  # This also repairs ownership left by the former system service.
  systemd.tmpfiles.rules = [
    "d ${statePath} 0700 ${primaryUser} ${primaryGroup} -"
    "z ${statePath} 0700 ${primaryUser} ${primaryGroup} -"
  ];

  systemd.user.services.tailscale-nix-builders = {
    description = "Discover reachable Nix builders shared through Tailscale";
    wantedBy = [ "default.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = utils.escapeSystemdExecArgs generatorArgs;
      TimeoutStartSec = "50s";
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;

      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      # The parent must exist before systemd creates the mount namespace.
      ReadWritePaths = [ "/home/${primaryUser}/.local/state" ];
      RestrictSUIDSGID = true;
    };
  };

  systemd.user.timers.tailscale-nix-builders = {
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
