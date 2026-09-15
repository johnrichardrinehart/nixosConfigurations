{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  breakpoint = inputs.nixosModules.lib.daylightDisplay.breakpoint;
in
{
  imports = [
    ./framework.nix
    ./tailscale-nix-builders.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  dev.johnrinehart.boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 5;
  };

  boot.loader = {
    efi.canTouchEfiVariables = true;
    timeout = 1;
  };

  dev.johnrinehart.profiles.laptop.enable = true;

  fonts.fontconfig.enable = lib.mkForce true;

  dev.johnrinehart.firmware.framework-ec.features = [ "F9-display-toggle" ];
  dev.johnrinehart.firmware.framework-ec.flashService.enable = true;

  dev.johnrinehart.desktop = {
    greetd_niri.fingerprint.enable = true;
    greetd_niri.niri.extraConfig = ''
      debug {
          // Work around Framework/Thunderbolt display resume cases where a docked
          // external monitor remains DRM-connected but disabled and missing from
          // `niri msg outputs`.
          force-disable-connectors-on-resume
      }
      output "Dell Inc. DELL U3225QE 6WS9B84" {
          mode "3840x2160@59.997"
          position x=0 y=0
          scale 1.0
      }
      output "Dell Inc. DELL U2520D 7Z4V823" {
          position x=3840 y=360
      }
      output "eDP-1" {
          mode "1920x1200@60.001"
          scale 1.0
          transform "normal"
          position x=3840 y=1800
      }
    '';
    greetd_niri.niri.extraKeybindings = ''
      Mod+O repeat=false {
          toggle-overview all-outputs=false
      }
      Mod+Shift+O repeat=false {
          toggle-overview
      }
    '';
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
  dev.johnrinehart.kitkat-rs.variant = "faster";
  environment.systemPackages = [
    pkgs.intel-gpu-tools
  ];
}
