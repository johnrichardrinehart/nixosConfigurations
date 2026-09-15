{ lib, ... }:
{
  nixpkgs.hostPlatform = "aarch64-linux";

  networking = {
    hostName = lib.mkDefault "mbp-apple-silicon";
    networkmanager.enable = lib.mkDefault true;
  };

  boot = {
    initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_blk"
      "virtio_scsi"
    ];
    kernelModules = [ "virtio_gpu" ];
    kernelParams = [ "console=hvc0" ];
    loader = {
      systemd-boot.enable = lib.mkDefault true;
      efi.canTouchEfiVariables = lib.mkDefault false;
    };
  };

  fileSystems."/" = {
    device = lib.mkDefault "/dev/disk/by-label/nixos";
    fsType = lib.mkDefault "ext4";
  };

  virtualisation.diskSize = lib.mkDefault (64 * 1024);

  security.rtkit.enable = lib.mkDefault true;
  services.pipewire = {
    enable = lib.mkDefault true;
    alsa.enable = lib.mkDefault true;
    pulse.enable = lib.mkDefault true;
  };

  dev.johnrinehart = {
    profiles.laptop.enable = true;
    desktop.greetd_niri.niri.displayModeWatch.enable = lib.mkDefault false;
  };
}
