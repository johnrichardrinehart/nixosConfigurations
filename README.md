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
