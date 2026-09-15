{
  inputs,
  lib,
  ...
}:
{
  imports = [
    ./disko.nix
    inputs.disko.nixosModules.disko
  ];

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

  virtualisation.diskSize = lib.mkDefault (64 * 1024);
}
