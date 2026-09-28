# nix-darwin configuration for the Apple Silicon MacBook Pro itself (the host
# that runs the mbp-apple-silicon QEMU guest).
#
# Everything here is personal and public. Work-specific additions (identities,
# private MCP servers, work apps) belong to a downstream flake, which layers
# its own modules on top through `lib.mkMbpHost` in flake.nix; the per-user
# parts go under `home-manager.users.john`, which merges across modules.
#
# Apply with `nix run .#provision-mac` (first time) or the same command later;
# it builds this system, sets it as /nix/var/nix/profiles/system and activates.
{ inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = "john";
  # One build for both the launch agent (home.nix) and its manual step below.
  shotedit = pkgs.callPackage ../../packages/shotedit/package.nix { };
  shoteditBin = lib.getExe shotedit;

  # Every key the generated ~/.ssh/config names, including ones downstream
  # modules add, so a fresh machine is told which keys to put in place.
  sshSettings = config.home-manager.users.${user}.programs.ssh.settings;
  sshKeys = lib.unique (
    lib.filter (key: key != null) (
      lib.mapAttrsToList (_: entry: (entry.data or entry).IdentityFile or null) sshSettings
    )
  );
in
{
  imports = [
    inputs.home-manager.darwinModules.home-manager
    ./apps.nix
    ./manual-steps.nix
    ./tmp-cleaner.nix
    ./vm-shares.nix
  ];

  # The guest's ~/code, mounted here: the data lives on the guest's disk.
  dev.johnrinehart.mbp-host.vmShares = [
    {
      host = "/Users/${user}/code";
      guest = "/home/${user}/code";
    }
  ];

  dev.johnrinehart.provisionMac.summary.shotedit = "${shotedit.meta.mainProgram} (${shoteditBin})";

  dev.johnrinehart.provisionMac.manualSteps = {
    "shotedit: Accessibility" = {
      # shotedit writes its own path there once macOS trusts it.
      check = ''
        [[ $(cat "$HOME/.local/state/shotedit/trusted-binary") == ${shoteditBin} ]]
      '';
      instructions = ''
        Allow ${shotedit.meta.mainProgram} under Privacy & Security > Accessibility;
        add it with + (Cmd+Shift+G) if it is not listed, and remove the entries
        for older shotedit builds. TCC keys the grant to the binary, so each build
        (a new tag) needs this again:
          ${shoteditBin}
      '';
      settingsPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
    };
    "SSH keys" = {
      check =
        lib.concatMapStrings (key: ''
          [[ -f ${lib.replaceStrings [ "~/" ] [ "$HOME/" ] key} ]] &&
        '') sshKeys
        + "true";
      instructions = ''
        Put the private keys ~/.ssh/config names in place (secrets are not
        managed):
      ''
      + lib.concatMapStrings (key: ''
        ${key}
      '') sshKeys;
    };
  };

  nixpkgs.hostPlatform = "aarch64-darwin";
  nixpkgs.overlays = [
    (import ../../packages/spice-quartz-overlay.nix)
    # repo-manager's flake only exposes Linux packages; its overlay is
    # system-independent, so build it here from the same source.
    inputs.nixosModules.inputs.repo-manager.inputs.rust-overlay.overlays.default
    inputs.nixosModules.inputs.repo-manager.overlays.default
  ];

  system.stateVersion = 6;
  system.primaryUser = user;

  users.users.${user}.home = "/Users/${user}";

  # The official installer's daemon is taken over in place (same launchd
  # label); nix-darwin recognises its /etc/nix/nix.conf.
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  # The omp wrapper (home.nix) runs llm-agents.nix's omp, which numtide
  # prebuilds here; without it every new version builds locally.
  nix.settings.extra-substituters = [ "https://cache.numtide.com" ];
  nix.settings.extra-trusted-public-keys = [
    "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
  ];

  # nix-darwin only writes /etc/nix/machines when build machines are set, and
  # its activation reloads the daemon whenever that file differs from the
  # running system's - which a missing file always does, so every switch sat
  # through a daemon restart. An empty file is what Nix assumes anyway.
  environment.etc."nix/machines".text = "";

  # Work kept in /tmp for a few days (long renders, scratch checkouts) must
  # not vanish over a weekend; macOS alone deletes it after 3 untouched days.
  dev.johnrinehart.mbp-host.tmpCleaner.enable = true;

  # /etc/zshrc puts the Nix and per-user profiles on PATH ahead of /usr/bin.
  programs.zsh.enable = true;

  # No Touch ID for sudo: the sensor is hardware that can fail (or be
  # unavailable, e.g. lid closed on a dock), and the password path must stay
  # the one that always works.
  security.pam.services.sudo_local.touchIdAuth = false;

  # /Library/Fonts/Nix Fonts. The oh-my-posh prompt's powerline and status
  # glyphs need a Nerd Font; the Terminal profile below selects FiraMono NFM.
  fonts.packages = [ pkgs.nerd-fonts.fira-mono ];

  system.defaults = {
    NSGlobalDomain = {
      AppleInterfaceStyle = "Dark";
      # "Natural" scrolling off.
      "com.apple.swipescrolldirection" = false;
      # F1, F2, ... act as standard function keys; Fn gives the media keys.
      "com.apple.keyboard.fnState" = true;
    };

    CustomUserPreferences = {
      NSGlobalDomain = {
        "com.apple.trackpad.scrolling" = 0.5882;
        "com.apple.scrollwheel.scaling" = 0.3125;
        "com.apple.sound.beep.volume" = 0.0;
      };

      # U.S. plus Dvorak, typing in Dvorak.
      "com.apple.HIToolbox" = {
        AppleEnabledInputSources = [
          {
            InputSourceKind = "Keyboard Layout";
            "KeyboardLayout ID" = 0;
            "KeyboardLayout Name" = "U.S.";
          }
          {
            InputSourceKind = "Non Keyboard Input Method";
            "Bundle ID" = "com.apple.CharacterPaletteIM";
          }
          {
            InputSourceKind = "Keyboard Layout";
            "KeyboardLayout ID" = 16300;
            "KeyboardLayout Name" = "Dvorak";
          }
        ];
        AppleSelectedInputSources = [
          {
            InputSourceKind = "Keyboard Layout";
            "KeyboardLayout ID" = 16300;
            "KeyboardLayout Name" = "Dvorak";
          }
          {
            InputSourceKind = "Non Keyboard Input Method";
            "Bundle ID" = "com.apple.CharacterPaletteIM";
          }
        ];
      };

      # On this macOS `target-screenshot` overrides `target` for stills.
      "com.apple.screencapture"."target-screenshot" = "file";
    };

    # shotedit clicks the floating thumbnail to open the editor; without the
    # thumbnail Cmd+Shift+4 would only save a file.
    screencapture.show-thumbnail = true;

    dock = {
      orientation = "left";
      tilesize = 78;
      autohide = false;
      # The tiles are left to the Dock itself: nix-darwin would replace the
      # whole list, including apps this configuration does not install.
    };
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    # Pre-existing hand-made dotfiles (~/.zshrc, ~/.gitconfig, ~/.ssh/config,
    # ...) are moved aside rather than refused on the first switch.
    backupFileExtension = "before-home-manager";
    # Apps that rewrite a managed file (spicy, Karabiner) leave a real file
    # to back up on every switch; replace the previous backup instead of
    # stopping at mv's prompt (the old backup is read-only, a store copy).
    overwriteBackup = true;
    extraSpecialArgs = { inherit inputs shotedit; };
    users.${user} = ./home.nix;
  };
}
