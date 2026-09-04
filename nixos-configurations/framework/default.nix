{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  primaryUser = config.dev.johnrinehart.users.primary;
  breakpoint = inputs.nixosModules.lib.daylightDisplay.breakpoint;
in
{
  imports = [
    ./framework.nix
    ./tailscale-nix-builders.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";
  documentation.nixos.enable = false;

  dev.johnrinehart.boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 5;
  };

  boot.loader = {
    efi.canTouchEfiVariables = true;
    timeout = 1;
  };

  fonts.fontconfig.enable = lib.mkForce true;
  services.sshd.enable = true;
  programs.ssh.extraConfig = ''
    Host *
      ConnectTimeout 2
  '';
  virtualisation.containers.enable = true;

  users.users.${primaryUser}.extraGroups = [ "input" ];

  # Enable cgroup delegation for the john user's systemd user manager.
  # This is required for running Kubernetes (k3s) inside rootless Podman containers.
  # Without this, k3s fails with "failed to find cpuset cgroup (v2)" because
  # rootless containers don't have access to cgroup controllers by default.
  #
  # The Delegate= directive allows the user's systemd instance to manage its own
  # cgroup subtree, enabling proper resource isolation for containerized workloads.
  # Controllers delegated: cpu, cpuset, io, memory, pids
  #
  # Reference: https://github.com/k3d-io/k3d/issues/1439
  systemd.services."user@".serviceConfig.Delegate = "cpu cpuset io memory pids";

  dev.johnrinehart.system.enable = true;
  dev.johnrinehart.repo-manager.daemon.enable = true;

  dev.johnrinehart.agentTools = {
    enable = true;
    "oh-my-codex".enable = false;
    codexCli.statusLinePlugins = [ "codex-weekly-pace" ];
  };

  dev.johnrinehart.firmware.framework-ec.features = [ "F9-display-toggle" ];
  dev.johnrinehart.firmware.framework-ec.flashService.enable = true;

  dev.johnrinehart.desktop = {
    enable = true;
    variant = "greetd+niri";
    greetd_niri.fingerprint.enable = true;
    greetd_niri.waybar.systemd.enable = true;
    obsidian.enable = true;
    daylightDisplay = {
      enable = true;
      breakpoints = [
        (breakpoint "sunrise" (-30) 60 3500)
        (breakpoint "sunrise" (-25) 63 3750)
        (breakpoint "sunrise" (-20) 67 4000)
        (breakpoint "sunrise" (-15) 70 4250)
        (breakpoint "sunrise" (-10) 73 4500)
        (breakpoint "sunrise" (-5) 77 4750)
        (breakpoint "sunrise" 0 80 5000)
        (breakpoint "sunrise" 5 83 5250)
        (breakpoint "sunrise" 10 87 5500)
        (breakpoint "sunrise" 15 90 5750)
        (breakpoint "sunrise" 20 93 6000)
        (breakpoint "sunrise" 25 97 6250)
        (breakpoint "sunrise" 30 100 6500)
        (breakpoint "sunset" (-30) 100 6500)
        (breakpoint "sunset" (-25) 97 6250)
        (breakpoint "sunset" (-20) 93 6000)
        (breakpoint "sunset" (-15) 90 5750)
        (breakpoint "sunset" (-10) 87 5500)
        (breakpoint "sunset" (-5) 83 5250)
        (breakpoint "sunset" 0 80 5000)
        (breakpoint "sunset" 5 77 4750)
        (breakpoint "sunset" 10 73 4500)
        (breakpoint "sunset" 15 70 4250)
        (breakpoint "sunset" 20 67 4000)
        (breakpoint "sunset" 25 63 3750)
        (breakpoint "sunset" 30 60 3500)
      ];
    };
  };

  # Authenticate before starting Niri so PAM receives the login password and
  # can unlock GNOME Keyring before applications such as Brave are launched.
  # The shared desktop module otherwise starts Niri directly as greetd's
  # unauthenticated default session.
  services.greetd = {
    useTextGreeter = true;
    settings.default_session = {
      command = lib.mkForce "${lib.getExe pkgs.tuigreet} --time --remember --user-menu --asterisks --cmd ${lib.getExe' config.programs.niri.package "niri-session"}";
      user = lib.mkForce "greeter";
    };
  };

  # greetd starts its default greeter through this PAM service without running
  # authentication. Define the account/session phases explicitly; otherwise
  # Linux-PAM falls back to the deny-all `other` service and tuigreet cannot
  # start after reboot.
  security.pam.services.greetd-greeter.text = ''
    auth required pam_permit.so
    account required pam_permit.so
    password required pam_deny.so
    session required pam_env.so conffile=/etc/pam/environment readenv=0
    session required pam_unix.so
    session optional ${pkgs.systemd}/lib/security/pam_systemd.so
  '';
  dev.johnrinehart.voice-dictation.enable = true;
  dev.johnrinehart.sshSessionLock = {
    enable = true;
    timeoutSeconds = 60 * 15;
    suspendPromptTimeoutSeconds = 60 * 15;
    terminalMultiplexer = "tmux";
    forceInteractiveShellsIntoMultiplexer = true;
    multiplexerSessionName = "main";
  };

  dev.johnrinehart.packages.shell.enable = true;
  dev.johnrinehart.kitkat-rs.variant = "fastest";
  dev.johnrinehart.packages.editors.enable = true;
  dev.johnrinehart.packages.gui.enable = true;
  dev.johnrinehart.packages.devops.enable = true;
  dev.johnrinehart.packages.media.enable = true;
  dev.johnrinehart.packages.system.enable = true;
  dev.johnrinehart.packages.archive.enable = true;
  dev.johnrinehart.bluetooth = {
    enable = true;
    autoSuspend.enable = true;
  };

  dev.johnrinehart.terminal.filepicker.enable = true;
  dev.johnrinehart.users.terminalEmulator = {
    package = pkgs.dev.johnrinehart.monstar;
  };
  environment.systemPackages = [
    pkgs.intel-gpu-tools
  ];
}
