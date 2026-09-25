# nixosConfigurations

JohnOS host-specific NixOS system configurations.

This repository depends on
[`nixosModules`](https://github.com/johnrichardrinehart/nixosModules) for the
shared modules, overlays, packages, Home Manager modules, and static assets.

It exposes `nixosConfigurations` for the managed hosts:

- `framework`
- `gce`
- `hp_spectre_x360`
- `mbp`
- `rock5c-nas`
- `thinkpad_w510`
- `virtualbox`
- `vultr`

## Mac host (`darwinConfigurations.mbp-host`)

The Apple Silicon MacBook Pro that runs the `mbp-apple-silicon` guest is managed
with nix-darwin and Home Manager from `darwin-configurations/mbp-host`: shell
(zsh, direnv + nix-direnv, zoxide as `j`, the NixOS hosts' oh-my-posh prompt),
Git and SSH identity, Terminal.app's "Clear Dark" profile, the FiraMono Nerd
Font, macOS defaults (Dock placement, input sources, scrolling, appearance), Karabiner
and spicy config, the VM share table, `shotedit` (Cmd+Shift+4 straight into
the screenshot editor), and the GUI apps Karabiner-Elements and KeePassXC.

The apps are installed from the vendors' own signed release files, pinned by
hash in `darwin-configurations/mbp-host/apps.nix`, rather than from nixpkgs'
repackaged bundles, which lose the vendor's code signature (and with it
Keychain access and permission grants). An app is installed when missing or
older than declared; one that updated itself is not downgraded.

```bash
nix run .#provision-mac
```

On a fresh Mac, install Nix first with the official multi-user installer
(`sh <(curl -L https://nixos.org/nix/install)`; nix-darwin takes over its
daemon in place), then run it straight from GitHub, with flakes enabled for
this one command:

```bash
nix --extra-experimental-features 'nix-command flakes' \
  run github:johnrichardrinehart/nixosConfigurations#provision-mac
```

Run it as the primary user; it asks for sudo. It builds the system, retires
the hand-made setup it replaces (moving existing files aside as
`*.before-nix-darwin` / `*.before-home-manager`), and activates. Run it again
to apply later changes.

Some steps macOS only accepts from the user: approving Karabiner's background
items, driver extension, Input Monitoring and Accessibility, Accessibility for
`shotedit` (again after every rebuild of it), and putting the SSH keys in
place. Modules declare these under `dev.johnrinehart.provisionMac.manualSteps`
with a check for each; after activating, `provision-mac` lists the ones still
pending, launches the app that asks for them, and opens System Settings at
the first. Once everything is done it only prints "no manual steps pending".

Downstream flakes extend the host with
`lib.mkMbpHost { modules = [ ... ]; }` and expose a matching provisioner with
`lib.mkProvisionMac`. Per-user additions go under `home-manager.users.john`.
