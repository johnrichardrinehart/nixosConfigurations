# GUI apps, installed from the vendors' own signed release files.
#
# nixpkgs' darwin packages of these unpack the vendor .dmg into the store,
# which drops part of what the code signature covers (codesign: "code has no
# resources but signature indicates they must be present"), so the bundles
# lose the vendor's Team ID. macOS keys Keychain items, TCC grants (Input
# Monitoring, Accessibility) and system-extension approval to that signature.
# Instead each release file is pinned as a fixed-output fetch and installed
# during activation the way a manual install would be: mounted and copied
# with ditto, or run through installer(8) for .pkg releases, whose scripts
# (Karabiner's daemons and driver) need to
# run. The installed bundles are the vendors', byte for byte.
#
# An app is installed only when it is missing or older than declared, so an
# app that updated itself is never downgraded. A running app is left alone.
{ lib, pkgs, ... }:
let
  inherit (pkgs) fetchurl;

  apps = {
    Karabiner-Elements = {
      version = "16.3.0";
      # The .dmg carries a .pkg; installing it sets up the daemons and the
      # DriverKit virtual keyboard, and puts Karabiner-EventViewer next to it.
      pkgInDmg = "Karabiner-Elements.pkg";
      receipt = "org.pqrs.Karabiner-Elements";
      src = fetchurl {
        url = "https://github.com/pqrs-org/Karabiner-Elements/releases/download/v16.3.0/Karabiner-Elements-16.3.0.dmg";
        hash = "sha256-GcznvtPUinIiQspoO9G65Aa2qH/tUgco0ckd7hdbdeQ=";
      };
    };
    KeePassXC = {
      version = "2.7.12";
      bundle = "KeePassXC.app";
      src = fetchurl {
        url = "https://github.com/keepassxreboot/keepassxc/releases/download/2.7.12/KeePassXC-2.7.12-arm64.dmg";
        hash = "sha256-ZfT2NgcYDAoVeUtKQGj4XpntU5HIfB+5MSZI8bNv7UA=";
      };
    };
  };

  sort = "${pkgs.coreutils}/bin/sort";

  installOne =
    name: app:
    let
      inherit (app) version src;
      announce = ''
        app=${lib.escapeShellArg name}
      '';
    in
    if app ? receipt then
      ''
        ${announce}
        have=$(/usr/sbin/pkgutil --pkg-info ${app.receipt} 2>/dev/null | /usr/bin/sed -n 's/^version: //p')
        if needsInstall "$have" ${version}; then
          echo "installing $app ${version} (have: ''${have:-none})" >&2
          ${
            if app ? pkgInDmg then
              ''
                installPkgFromImage ${src} ${lib.escapeShellArg app.pkgInDmg}
              ''
            else
              ''
                /usr/sbin/installer -pkg ${src} -target /
              ''
          }
        fi
      ''
    else
      ''
        ${announce}
        dest=/Applications/${lib.escapeShellArg app.bundle}
        have=$(/usr/bin/defaults read "$dest/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)
        if needsInstall "$have" ${version}; then
          if /usr/bin/pgrep -qf "^$dest/Contents/MacOS/"; then
            echo "not updating $app to ${version} while it is running; quit it and re-run" >&2
          else
            echo "installing $app ${version} (have: ''${have:-none})" >&2
            /bin/rm -rf "$dest"
            copyAppFromImage ${src} ${lib.escapeShellArg app.bundle} "$dest"
          fi
        fi
      '';
in
{
  system.activationScripts.applications.text = lib.mkAfter ''
    echo "installing vendor apps..." >&2

    # needsInstall HAVE WANT: HAVE is empty or sorts before WANT.
    needsInstall() {
      [[ -z $1 ]] || { [[ $1 != "$2" ]] && [[ $(printf '%s\n' "$1" "$2" | ${sort} -V | /usr/bin/head -n1) == "$1" ]]; }
    }

    # fromImage DMG PATH CMD...: mount DMG read-only and run CMD with the
    # absolute path of PATH inside it appended.
    fromImage() {
      local image=$1 inner=$2 mnt status=0
      shift 2
      mnt=$(/usr/bin/mktemp -d)
      /usr/sbin/diskutil image attach --mountOptions nobrowse --readOnly --mountPoint "$mnt" "$image" >/dev/null
      "$@" "$mnt/$inner" || status=$?
      /usr/sbin/diskutil eject "$mnt" >/dev/null || true
      /bin/rmdir "$mnt" 2>/dev/null || true
      return "$status"
    }
    copyAppFromImage() { fromImage "$1" "$2" copyApp "$3"; }
    copyApp() { /usr/bin/ditto "$2" "$1"; }
    installPkgFromImage() { fromImage "$1" "$2" /usr/sbin/installer -target / -pkg; }

    ${lib.concatStrings (lib.mapAttrsToList installOne apps)}
  '';

  # Karabiner's approvals, each detected the way Karabiner itself reports it.
  # Its settings app walks through all three, so opening it is the action.
  dev.johnrinehart.provisionMac.manualSteps =
    let
      openKarabiner = "/usr/bin/open -a Karabiner-Elements";
      permissionFile = ''"$HOME/.local/share/karabiner/tmp/core-service-permission-check-result.json"'';
      permission = key: ''
        /usr/bin/plutil -extract ${key} raw -o - ${permissionFile} | /usr/bin/grep -qx true
      '';
    in
    {
      "Karabiner-Elements: background items" = {
        check = ''
          /bin/launchctl print system/org.pqrs.service.daemon.Karabiner-Core-Service | /usr/bin/grep -q 'state = running'
        '';
        instructions = ''
          Allow Karabiner-Elements' background items (Privileged Daemons,
          Non-Privileged Agents) under General > Login Items & Extensions.
        '';
        action = openKarabiner;
        settingsPane = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension";
      };
      "Karabiner-Elements: driver extension" = {
        check = ''
          /usr/bin/systemextensionsctl list | /usr/bin/grep -q 'org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.*\[activated enabled\]'
        '';
        instructions = ''
          Allow the Karabiner-DriverKit-VirtualHIDDevice driver extension under
          General > Login Items & Extensions > Driver Extensions.
        '';
        action = openKarabiner;
        settingsPane = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension";
      };
      "Karabiner-Elements: Input Monitoring" = {
        check = permission "iohid_listen_event_allowed";
        instructions = ''
          Allow Karabiner-Core-Service under Privacy & Security > Input Monitoring.
        '';
        action = openKarabiner;
        settingsPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent";
      };
      "Karabiner-Elements: Accessibility" = {
        check = permission "accessibility_process_trusted";
        instructions = ''
          Allow Karabiner-Core-Service under Privacy & Security > Accessibility.
        '';
        action = openKarabiner;
        settingsPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
      };
    };
}
