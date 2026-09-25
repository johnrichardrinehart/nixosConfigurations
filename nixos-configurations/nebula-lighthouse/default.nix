{
  inputs,
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/virtualisation/digital-ocean-config.nix")
    inputs.disko.nixosModules.disko
    ./disko.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";
  networking = {
    hostName = "nebula-lighthouse";
    useDHCP = true;
    enableIPv6 = false;
    firewall.allowedTCPPorts = [ 22 ];
  };

  # The DigitalOcean guest profile enables partition and ext4 growth. Keep
  # both explicit: the 8 GiB image must grow on a 50 GiB Droplet's first boot.
  boot.growPartition = true;
  fileSystems."/".autoResize = true;

  disko.memSize = 2048;

  virtualisation.digitalOcean = {
    # Cloud-init reads the metadata keys; don't race it or rebuild from user data.
    setSshKeys = false;
    seedEntropy = false;
    rebuildFromUserData = false;
  };
  services.cloud-init = {
    enable = true;
    settings = {
      datasource_list = [
        "ConfigDrive"
        "DigitalOcean"
      ];
      # NixOS handles DHCP, the hostname, root growth and SSH host keys.
      network.config = "disabled";
      preserve_hostname = true;
      growpart.mode = "off";
      resize_rootfs = false;
      ssh_deletekeys = false;
      ssh_genkeytypes = [ ];
    };
    # ConfigDrive injects an empty script and an Ubuntu-only machine-ID script.
    # Neither applies to NixOS; keep the other cloud-init stages.
    settings.cloud_final_modules = lib.mkForce [
      "rightscale_userdata"
      "scripts-vendor"
      "scripts-per-once"
      "scripts-per-boot"
      "scripts-user"
      "ssh-authkey-fingerprints"
      "keys-to-console"
      "phone-home"
      "final-message"
      "power-state-change"
    ];
  };

  boot = {
    initrd.availableKernelModules = [
      "ahci"
      "virtio_pci"
      "virtio_blk"
      "virtio_scsi"
    ];
    loader.grub = {
      enable = true;
      # Both Disko and the DigitalOcean profile contribute this device.
      # Select it once for upgrades; the image builder overrides it in its VM.
      devices = lib.mkOverride 90 [ "/dev/vda" ];
    };
  };

  services.openssh = {
    enable = true;
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ61iahx0HtGVD0qtBFIr8nTPivNxQimrqaloBazYCPK john@nixos"
  ];

  systemd.tmpfiles.rules = [ "d /var/lib/nebula 0750 root nebula-nebula -" ];

  # A fresh installation has no credentials yet. Skip Nebula (without a failed
  # service) until the operator installs all three files out of band.
  systemd.services."nebula@nebula".unitConfig.ConditionPathExists = [
    "/var/lib/nebula/ca.crt"
    "/var/lib/nebula/host.crt"
    "/var/lib/nebula/host.key"
  ];

  services.nebula.networks.nebula = {
    ca = "/var/lib/nebula/ca.crt";
    cert = "/var/lib/nebula/host.crt";
    key = "/var/lib/nebula/host.key";
    isLighthouse = true;
    listen.port = 4242;
    # Certificate identity is 10.77.0.1/24. Nebula assigns the tunnel IP from
    # the externally supplied certificate, not from networking.interfaces.
    firewall.inbound = [
      {
        port = "22";
        proto = "tcp";
        cidr = "10.77.0.0/24";
      }
    ];
  };

  system.stateVersion = "26.05";
}
