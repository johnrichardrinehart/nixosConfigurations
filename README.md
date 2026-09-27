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
- `nebula-lighthouse`
- `rock5c-nas`
- `thinkpad_w510`
- `virtualbox`

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

## Framework voice dictation

`framework` uses converted ONNX Moonshine models with OpenVINO. Its package
override removes the ORT-only format setting from the streaming loader.
The frontend model needs three external weights from `frontend.weights.onnx`.
The model build checks their names and shapes against the frontend inputs.
Before switching the system, load the model and process an audio chunk.
The package's unit tests do not exercise model inference.

## Nebula lighthouse installation

`nixosConfigurations.nebula-lighthouse` defines the x86_64 DigitalOcean
custom-image guest. Disko defines the disk layout in
`nixos-configurations/nebula-lighthouse/disko.nix`. The GPT disk has a 1 MiB
GRUB BIOS boot partition, a 2 GiB vfat `/boot`, and an ext4 root.
DigitalOcean custom images do not support UEFI or IPv6.

Build `.#nixosConfigurations.nebula-lighthouse.config.system.build.diskoImagesScript`
on an x86_64 Linux builder, then execute the script from a scratch directory.
It creates `main.raw` **in that directory**, not in the Nix store. The image
is an 8 GiB sparse BIOS-bootable NixOS disk. Compress it with
`gzip -c main.raw > main.img.gz` before upload. The intended
`s-1vcpu-2gb` Droplet has a 50 GiB disk. On first boot, NixOS grows the root
partition and ext4 filesystem to fill that disk. Do not run the destructive
Disko installer against an existing Droplet.

The guest uses IPv4 DHCP, the pinned DigitalOcean guest profile, and
cloud-init with ConfigDrive before DigitalOcean metadata. NixOS handles
network configuration and first-boot SSH host-key generation. Cloud-init
imports the Droplet's SSH public keys. It skips ConfigDrive's per-instance
scripts because DigitalOcean supplies an empty script and an Ubuntu-specific
machine-ID script. The `john@nixos` key remains authorized for root without
metadata, including local QEMU boots. The image contains no SSH host private
key or Nebula credentials. Test a disposable copy of `main.raw` with BIOS
firmware, not OVMF. Booting the upload image itself persists guest identity
in the template.

### The `mycelium` overlay

The Nebula network is named `mycelium` (tun device `nebula.mycelium`, unit
`nebula@mycelium`). Its CA only signs addresses in `10.77.0.0/24`. Hosts use
the nixosModules `dev.johnrinehart.nebula.client` module; the lighthouse
runs `dev.johnrinehart.nebula.registry`.

Certificates carry the identity: the name becomes the host's DNS label and
the networks its overlay address. Every host except the lighthouse carries
the `peer` group. Hosts accept inbound traffic only from `peer`, so the
lighthouse can never open a connection to a host; contact always starts from
a host. The lighthouse's own outbound rules are empty as a second layer.
Discovery, hole punching and relaying are Nebula control traffic and are not
affected.

`framework` (`framie`, `10.77.0.2/24`) contacts the lighthouse at `10.77.0.1`
through `nebula-lighthouse.johnrinehart.dev:4242` from an ephemeral UDP port.
It accepts ICMP and TCP 22 from peers, sends ICMP, TCP 22, DNS and HTTPS only
to the lighthouse, answers punch notifications and uses the lighthouse, also
a Nebula relay, when a direct tunnel fails.

### Peer registry, DNS and dashboard

The lighthouse polls its Nebula debug console (localhost only, keys
generated on the lighthouse under `/var/lib/nebula-console` and
`/var/lib/nebula-registry`) every 10 seconds and keeps every certificate it
has ever seen in `/var/lib/nebula-registry/registry.db`. A peer is online
while it has a tunnel to the lighthouse and goes offline after 30 seconds
without one; events (first seen, online, offline, address and certificate
changes) are kept for 365 days, peers forever.

DNS for `mycelium.nebula.johnrinehart.dev` comes from that history:
`<certificate name>.mycelium.nebula.johnrinehart.dev`, for example
`framework.mycelium.nebula.johnrinehart.dev` and
`lighthouse.mycelium.nebula.johnrinehart.dev`. It is served on `10.77.0.1:53`,
reachable only through Nebula. Hosts route only that zone to the lighthouse
with systemd-resolved; other names resolve as before. Clients without split
DNS, such as Mobile Nebula releases without match domains, send every lookup
to `10.77.0.1`; the registry forwards names outside the overlay to `1.1.1.1`
and then `9.9.9.9`, so the lighthouse and those resolvers see those lookups.

`https://lighthouse.mycelium.nebula.johnrinehart.dev/` (and `/api/peers` as
JSON) shows peers inside the caller's certificate networks. The caller is
identified by the overlay address its request arrives from. The certificate
comes from ACME DNS-01 through Cloudflare once the token is installed as
`CF_DNS_API_TOKEN=…` in `/var/lib/lighthouse-acme/cloudflare.env` (root,
0400) on the lighthouse; until then a self-signed placeholder is served.
After installing it, run
`systemctl start acme-order-renew-lighthouse.mycelium.nebula.johnrinehart.dev`.

To add a host: sign a certificate with `-groups peer` and an address in
`10.77.0.0/24`, deploy it with the client module, and switch the host. It
appears in the registry, DNS and dashboard as soon as it connects.

### Credentials

`secrets/nebula-ca.yaml` contains the encrypted CA signing key.
`secrets/nebula-framework.yaml` contains the public CA certificate and
`framie`'s signed certificate and private key. Both files use the Framework
SSH host key as their only age recipient. The former administrator age
identity cannot decrypt either file. sops-nix installs only the Framework
node files under `/run/secrets` for Nebula. Never copy the CA signing key to
the lighthouse or mount it in the Nebula service. The lighthouse's own
certificate and key live in `/var/lib/nebula/` on the lighthouse only.

Old Git revisions remain encrypted to their original recipient. Rekeying
the current file does not revoke access to those revisions.

Keep a secure recovery copy of the Framework SSH host key. Without it,
neither current encrypted file can be decrypted. Before rotating that key,
re-encrypt both files to the new age recipient while the old key is
available. Verify decryption with the new key before retiring the old key.

To issue a new host certificate, decrypt the CA key as root on Framework
into a root-only tmpfs directory. Set `SOPS_AGE_KEY_CMD` to the absolute
`ssh-to-age` path followed by
`-private-key -i /etc/ssh/ssh_host_ed25519_key`. SOPS captures the native
age identity that the command writes to standard output. Do not copy the
SSH private key into the repository or a user directory. Use
`nebula-cert sign` with
`-ca-crt`, `-ca-key`, `-name`, `-networks <host-address>/24` and, for every
host except the lighthouse, `-groups peer`.
Verify the result with `nebula-cert verify`. Encrypt the new certificate
and host key before updating the configuration. Remove the plaintext files
from tmpfs. The CA signing key stays outside the runtime Nebula service.

On `framie`, build `.#nixosConfigurations.framework.config.system.build.toplevel`.
Switch with `sudo nixos-rebuild switch --flake .#framework` when root access
is available. Verify `nebula@mycelium.service`, `nebula.mycelium`, and a
connection to `10.77.0.1` before removing the imported DigitalOcean image.

The lighthouse holds only the public CA certificate and its own signed
certificate and private key under `/var/lib/nebula/`. Their modes are
`0640 root:nebula-mycelium`. Never put a host's private key or the CA key
in an unencrypted repository file. Before the CA expires, create a new CA
and sign new certificates for both hosts. Update the two encrypted files,
replace the lighthouse files through pinned SSH, and switch `framework`.
Verify peer connectivity before retiring the old CA.
