# `nix run .#provision-mac`: switch this Mac to a nix-darwin configuration.
#
# Evaluating the app builds the whole system (it is referenced below), so by
# the time the script runs only activation is left. That is what
# `darwin-rebuild switch` does, minus needing darwin-rebuild to exist yet, plus
# the one-time takeover of a Mac set up by hand. Re-running it later is the
# normal way to apply changes.
{
  darwinConfiguration,
  lib,
  writeShellApplication,
}:
let
  inherit (darwinConfiguration) config;
  toplevel = config.system.build.toplevel;
  user = config.system.primaryUser;

  # Declared with dev.johnrinehart.provisionMac.manualSteps; see
  # darwin-configurations/mbp-host/manual-steps.nix.
  steps = lib.imap0 (i: step: step // { inherit i; }) (
    lib.attrsToList (config.dev.johnrinehart.provisionMac.manualSteps or { })
  );
  renderStep =
    {
      i,
      name,
      value,
    }:
    ''
      step_name[${toString i}]=${lib.escapeShellArg name}
      step_pane[${toString i}]=${lib.escapeShellArg (toString value.settingsPane)}
      step_check_${toString i}() {
      ${value.check}
      }
      step_instructions_${toString i}() {
        cat <<'EOF'
      ${lib.removeSuffix "\n" value.instructions}
      EOF
      }
      step_action_${toString i}() {
      ${if value.action == null then ":" else value.action}
      }
    '';
in
writeShellApplication {
  name = "provision-mac";
  text = ''
    toplevel=${toplevel}

    if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
      echo "provision-mac: this configuration is for Apple Silicon macOS" >&2
      exit 1
    fi
    if [[ $(id -un) != ${lib.escapeShellArg user} ]]; then
      echo "provision-mac: run this as ${user}; it asks for sudo itself" >&2
      exit 1
    fi

    echo "==> provisioning $toplevel"

    # The hand-built shotedit agent from before this configuration existed.
    # It must be gone before the managed agent starts: both register
    # Cmd+Shift+4 and only the first registration wins.
    legacy_agent=$HOME/Library/LaunchAgents/local.shotedit.plist
    if [[ -e $legacy_agent ]]; then
      echo "==> retiring $legacy_agent"
      launchctl bootout "gui/$(id -u)" "$legacy_agent" 2>/dev/null || true
      rm -f "$legacy_agent" "$HOME/.local/bin/shotedit"
      rm -rf "$HOME/.config/shotedit"
    fi

    # Hand-made files Home Manager does not write but that would stay in
    # effect beside what it does: git reads ~/.gitconfig as well as
    # ~/.config/git/config, and direnv sources ~/.config/direnv/direnvrc on
    # top of Home Manager's nix-direnv. Kept as *.before-home-manager.
    for legacy in "$HOME/.gitconfig" "$HOME/.config/direnv/direnvrc"; do
      if [[ -f $legacy && ! -L $legacy ]]; then
        echo "==> moving $legacy aside to $legacy.before-home-manager"
        mv "$legacy" "$legacy.before-home-manager"
      fi
    done

    # nix-darwin refuses to replace /etc files it does not recognise and moves
    # the ones it does to *.before-nix-darwin. Doing the move for every file it
    # is about to own yields the same end state without the refusal.
    while IFS= read -r -d "" link; do
      sub=''${link#"$toplevel/etc/"}
      target=/etc/$sub
      if [[ -e $target || -L $target ]] && [[ $(readlink "$target") != "/etc/static/$sub" ]]; then
        backup=$target.before-nix-darwin
        [[ -e $backup ]] && backup=$backup.$(date +%Y%m%d%H%M%S)
        echo "==> moving $target aside to $backup"
        sudo mv "$target" "$backup"
      fi
    done < <(find -H "$toplevel/etc" -type l -print0)

    sudo ${config.nix.package}/bin/nix-env --profile /nix/var/nix/profiles/system --set "$toplevel"
    sudo "$toplevel/activate"

    # The fonts now live in /Library/Fonts/Nix Fonts; per-user copies of the
    # same family would shadow them.
    shopt -s nullglob
    stale_fonts=("$HOME"/Library/Fonts/FiraMonoNerdFont*.otf)
    if (( ''${#stale_fonts[@]} )); then
      echo "==> removing per-user copies of FiraMono Nerd Font"
      rm -f "''${stale_fonts[@]}"
    fi

    echo "==> done"
    ${lib.concatStrings (
      lib.mapAttrsToList (name: value: ''
        echo ${lib.escapeShellArg "==> ${name}: ${value}"}
      '') (config.dev.johnrinehart.provisionMac.summary or { })
    )}

    # Imperative steps macOS only accepts from the user. Agents restarted by
    # the activation may take a moment to report, so failures are rechecked
    # once after a short wait before being listed.
    declare -a step_name=() step_pane=() pending=()
    ${lib.concatMapStrings renderStep steps}
    stepDone() { "step_check_$1" >/dev/null 2>&1; }
    for i in "''${!step_name[@]}"; do
      stepDone "$i" || pending+=("$i")
    done
    if (( ''${#pending[@]} )); then
      sleep 3
      recheck=("''${pending[@]}")
      pending=()
      for i in "''${recheck[@]}"; do
        stepDone "$i" || pending+=("$i")
      done
    fi

    if (( ''${#pending[@]} == 0 )); then
      echo "==> no manual steps pending"
      exit 0
    fi

    echo
    echo "==> manual steps pending (re-run provision-mac to re-check):"
    pane=
    for i in "''${pending[@]}"; do
      printf '\n  - %s\n' "''${step_name[$i]}"
      "step_instructions_$i" | sed 's/^/      /'
      "step_action_$i" || true
      if [[ -z $pane ]]; then pane=''${step_pane[$i]}; fi
    done
    if [[ -n $pane ]]; then
      echo
      echo "==> opening System Settings for the first of them"
      open "$pane"
    fi
  '';
}
