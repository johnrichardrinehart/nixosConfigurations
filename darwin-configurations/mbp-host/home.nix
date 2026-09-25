# Home Manager configuration for john on the Mac host.
{
  config,
  inputs,
  lib,
  pkgs,
  shotedit,
  ...
}:
let
  cfg = config.dev.johnrinehart.mbp-host;
in
{
  options.dev.johnrinehart.mbp-host.github.personalSshKey = lib.mkOption {
    type = lib.types.str;
    default = "~/.ssh/id_ed25519_github.com_johnrichardrinehart";
    description = ''
      SSH key that authenticates as github.com/johnrichardrinehart. Pinned for
      all of github.com so that, with several GitHub keys in the agent, ssh
      does not authenticate as whichever account's key happens to come first.
    '';
  };

  config = {
    home.stateVersion = "26.05";

    home.packages = [
      pkgs.htop
      pkgs.tmux
      pkgs.tree
      pkgs.watch
      pkgs.wormhole-rs
      pkgs.repo-manager
      (pkgs.callPackage ../../packages/secretspec/package.nix { })
      inputs.self.packages.aarch64-darwin.mbp-apple-silicon-qemu-vm
    ];

    # One full-screen editor for both: every program honors at least one.
    home.sessionVariables = {
      EDITOR = "vim";
      VISUAL = "vim";
    };

    # /usr/bin/git and /usr/bin/vim are Xcode shims (git refuses to run until
    # the Xcode license is accepted); the Nix ones come first on PATH.
    programs.vim.enable = true;

    programs.zsh = {
      enable = true;
      initContent = ''
        # zsh picks the vi keymap whenever $EDITOR/$VISUAL contain "vi"
        # (silently unbinding ^A, ^R, ...). Line editing stays emacs.
        bindkey -e

        # Word motions (Alt+Backspace, ^W, Alt-b/f) treat only alphanumerics as
        # word characters, so they stop at / - . _ like the NixOS hosts.
        WORDCHARS=""

        # Ctrl+Left/Right: word movement
        bindkey "^[[1;5D" backward-word
        bindkey "^[[1;5C" forward-word
      '';
    };

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    # `j <query>` jumps by frecency, `ji` picks interactively.
    programs.zoxide = {
      enable = true;
      options = [
        "--cmd"
        "j"
      ];
    };

    # Same prompt as the NixOS hosts (time, user@host, path, git, status,
    # nix-shell); needs the Nerd Font the system module installs.
    programs.oh-my-posh = {
      enable = true;
      settings = builtins.fromJSON (
        builtins.readFile "${inputs.nixosModules}/home-configurations/home-manager/oh-my-posh.json"
      );
    };

    programs.git = {
      enable = true;
      # The identity follows the repository's remote, not its checkout path:
      # repo-manager keeps bare clones and worktrees in different trees.
      includes =
        map
          (prefix: {
            condition = "hasconfig:remote.*.url:${prefix}johnrichardrinehart/**";
            contents.user = {
              name = "John Rinehart";
              email = "johnrichardrinehart@gmail.com";
            };
          })
          [
            "https://github.com/"
            "git@github.com:"
            "ssh://git@github.com/"
          ];
    };

    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
      settings."github.com" = {
        HostName = "github.com";
        User = "git";
        IdentityFile = cfg.github.personalSshKey;
        IdentitiesOnly = true;
      };
    };

    # Cmd+Shift+4 opens the screenshot editor directly (see shotedit.swift).
    launchd.agents.shotedit = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe shotedit) ];
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Interactive";
        StandardErrorPath = "/tmp/shotedit.log";
      };
    };

    home.activation = {
      # System shortcuts (com.apple.symbolichotkeys) turned off, as
      # id = [ ascii keycode modifiers ]. -dict-add leaves every other hotkey
      # alone, so only these are pinned.
      #   30        "Save picture of selected area as a file" (Cmd+Shift+4):
      #             shotedit owns the chord.
      #   79, 81    Mission Control "Move left/right a space" (Ctrl+Left/Right):
      #             they swallow the chords zsh binds to backward/forward-word.
      #   118-120   "Switch to Desktop 1-3" (Ctrl+1..3).
      disabledSymbolicHotkeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        ${lib.concatStrings (
          lib.mapAttrsToList
            (id: params: ''
              run /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys \
                -dict-add ${id} '{ enabled = 0; value = { parameters = (${
                  lib.concatMapStringsSep ", " toString params
                }); type = standard; }; }'
            '')
            {
              "30" = [
                52
                21
                1179648
              ];
              "79" = [
                65535
                123
                8650752
              ];
              "81" = [
                65535
                124
                8650752
              ];
              "118" = [
                65535
                18
                262144
              ];
              "119" = [
                65535
                19
                262144
              ];
              "120" = [
                65535
                20
                262144
              ];
            }
        )}
        run /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
      '';

      # Terminal keeps each profile as one nested dictionary (colors and font
      # are archived NSColor/NSFont data), which `defaults write` cannot
      # address. Round-trip the domain through cfprefsd instead: export,
      # replace the "Clear Dark" profile with the committed one (FiraMono Nerd
      # Font Mono 12, Option as Meta, 120x30), make it the default, import.
      terminalProfile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        tmp=$(mktemp -d)
        plist="$tmp/com.apple.Terminal.plist"
        if ! /usr/bin/defaults export com.apple.Terminal "$plist" 2>/dev/null; then
          printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
            '<plist version="1.0"><dict/></plist>' >"$plist"
        fi
        /usr/bin/plutil -type "Window Settings" "$plist" >/dev/null 2>&1 \
          || /usr/bin/plutil -insert "Window Settings" -dictionary "$plist"
        /usr/bin/plutil -remove "Window Settings.Clear Dark" "$plist" 2>/dev/null || true
        /usr/bin/plutil -insert "Window Settings.Clear Dark" -xml "$(cat ${./terminal-clear-dark.plist})" "$plist"
        /usr/bin/plutil -replace "Default Window Settings" -string "Clear Dark" "$plist"
        /usr/bin/plutil -replace "Startup Window Settings" -string "Clear Dark" "$plist"
        run /usr/bin/defaults import com.apple.Terminal "$plist"
        rm -rf "$tmp"
      '';
    };

    # The apps rewrite these on GUI edits, replacing the link with a file;
    # `force` lets the next switch put the declared version back.
    xdg.configFile = {
      "karabiner/karabiner.json" = {
        source = ./karabiner.json;
        force = true;
      };
      # spicy is the SPICE viewer the VM launcher opens.
      "spicy/settings" = {
        force = true;
        text = lib.generators.toINI { } {
          general = {
            grab-keyboard = true;
            grab-mouse = true;
            scaling = true;
            auto-clipboard = true;
            sync-modifiers = true;
            resize-guest = true;
          };
          ui = {
            toolbar = true;
            statusbar = true;
          };
        };
      };
    };

    # Read by mbp-apple-silicon-qemu-vm: mount the guest's ~/code on the Mac.
    home.file."guest-vm-fs-mappings.json".text = builtins.toJSON {
      shares = [
        {
          host = "${config.home.homeDirectory}/code";
          guest = "/home/john/code";
          mode = "rw";
          cache = "none";
          msize = 512000;
          remap = false;
          transport = "nfs";
        }
      ];
    };
  };
}
