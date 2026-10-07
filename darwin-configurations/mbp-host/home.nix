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
  # One build for PATH and the activation step below.
  displayMode = pkgs.callPackage ../../packages/display-mode/package.nix { };
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
      displayMode
      pkgs.tmux
      pkgs.tree
      pkgs.watch
      pkgs.wormhole-rs
      pkgs.ripgrep
      pkgs.fd
      pkgs.ncdu
      # GNU timeout alone: all of coreutils would shadow macOS's date, ls, sed...
      (pkgs.runCommand "timeout" { } ''
        mkdir -p $out/bin
        ln -s ${pkgs.coreutils}/bin/timeout $out/bin/timeout
      '')
      pkgs.repo-manager
      (pkgs.callPackage ../../packages/secretspec/package.nix { })
      inputs.self.packages.aarch64-darwin.mbp-apple-silicon-qemu-vm
      # Its viewer, Spicy.app, which Home Manager copies into
      # ~/Applications/Home Manager Apps; the launcher runs that copy.
      inputs.self.packages.aarch64-darwin.mbp-apple-silicon-qemu-vm.spicy
      # The same floating wrapper the NixOS machines install
      # (nixosModules agentTools.omp): it `nix run`s llm-agents.nix's omp,
      # rechecked hourly, with the context-mode extension.
      (inputs.nixosModules.packages.aarch64-darwin.omp.withPlugins (p: [ p.context-mode ]))
    ];

    # One full-screen editor for both: every program honors at least one.
    home.sessionVariables = {
      EDITOR = "vim";
      VISUAL = "vim";

      # Render colour escapes in less (`jq -C … | less`). nix-darwin only puts
      # -R in PAGER, which commands piping into less never see. NixOS hosts
      # get LESS=-R from programs.less, on by default.
      LESS = "-R";
    };

    # /usr/bin/git and /usr/bin/vim are Xcode shims (git refuses to run until
    # the Xcode license is accepted); the Nix ones come first on PATH.
    programs.vim = {
      enable = true;
      # nixpkgs' default vim is built for X11 (GTK2), so "+ and "* went to an
      # X clipboard nobody runs. vim-darwin uses the macOS pasteboard, which
      # is also what spicy shares with the guest.
      packageConfigurable = pkgs.vim-darwin;
      extraConfig = ''
        set encoding=utf-8
        set number

        " Tell tabs from spaces: a tab shows as », a leading space as a dim ·.
        set list
        set listchars=tab:»\ ,lead:·,trail:·,nbsp:␣

        " Trailing whitespace in red, except just behind the cursor while
        " typing. Re-applied on colorscheme changes, which clear it.
        highlight ExtraWhitespace ctermbg=red guibg=red
        augroup ExtraWhitespace
          autocmd!
          autocmd ColorScheme * highlight ExtraWhitespace ctermbg=red guibg=red
          autocmd BufWinEnter,InsertLeave * match ExtraWhitespace /\s\+$/
          autocmd InsertEnter * match ExtraWhitespace /\s\+\%#\@<!$/
        augroup END

        " :WipeTrailingSpace strips it from the whole file, or from a range
        " (:'<,'>WipeTrailingSpace), keeping the cursor and search history.
        function! s:WipeTrailingSpace(first, last) abort
          let l:view = winsaveview()
          keeppatterns execute a:first . ',' . a:last . 's/\s\+$//e'
          call winrestview(l:view)
        endfunction
        command! -range=% WipeTrailingSpace call s:WipeTrailingSpace(<line1>, <line2>)
      '';
    };

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

      # The git aliases (gst, glg, gd, gaa, ggl, ...) the NixOS hosts have.
      # oh-my-posh draws the prompt, so no oh-my-zsh theme.
      oh-my-zsh = {
        enable = true;
        plugins = [ "git" ];
        theme = "";
      };
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
      # GitHub over SSH, never HTTPS, as on the NixOS machines (nixosModules
      # common.nix). An HTTPS push would authenticate with whatever
      # ~/.netrc or a credential helper holds, not the key picked by the
      # remote's owner.
      settings.url."git@github.com:".insteadOf = "https://github.com";
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

      # The 32" Dell U3225QE (vendor 0x10ac, model 0x4376; native 3840x2160)
      # looks like 2560x1440 at scale 2: text 1.5 times its native size. The
      # mode is saved permanently, and WindowServer restores it each time the
      # monitor is attached. When it is not connected, this does nothing.
      # `display-mode list` prints them for another display.
      displayModes = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${lib.getExe displayMode} \
          set 4268 17270 2560 1440 2
      '';
    };

    # Karabiner rewrites its file on GUI edits, replacing the link with a
    # file; `force` lets the next switch put the declared version back.
    xdg.configFile = {
      # The VM-viewer rule matches the frontmost app: Spicy.app by bundle
      # identifier, and QEMU's cocoa window by its executable, by regex:
      # /nix/store/<32-char nix-base32 hash>-qemu-<version>/bin/
      # qemu-system-aarch64, also in the .qemu-system-aarch64-wrapped form
      # nixpkgs' wrapper gives the real binary. Any hash and version match,
      # so a rebuild or upgrade keeps it working.
      "karabiner/karabiner.json" = {
        source = ./karabiner.json;
        force = true;
      };
      # spicy is the SPICE viewer the VM launcher opens. The launcher runs it
      # with --no-save-settings, and it leaves an unwritable settings file
      # alone anyway, so this link stays put; `force` covers older builds.
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
  };
}
