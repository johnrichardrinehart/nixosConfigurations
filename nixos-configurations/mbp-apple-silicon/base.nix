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
    # Bring the display up in stage 1 so early boot is visible in vfkit's window.
    initrd.kernelModules = [ "virtio_gpu" ];
    kernelModules = [ "virtio_gpu" ];
    # tty0 puts the kernel log on the virtual display; hvc0 stays last so it
    # remains /dev/console and keeps the serial getty vfkit talks to.
    kernelParams = [
      "console=tty0"
      "console=hvc0"
    ];
    loader = {
      systemd-boot.enable = lib.mkDefault true;
      efi.canTouchEfiVariables = lib.mkDefault false;
    };
  };

  virtualisation.diskSize = lib.mkDefault (64 * 1024);
}
