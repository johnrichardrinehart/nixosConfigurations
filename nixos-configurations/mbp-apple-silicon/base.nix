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
    # Bring the display up in stage 1 so early boot is visible on the virtual
    # display.
    initrd.kernelModules = [ "virtio_gpu" ];
    kernelModules = [ "virtio_gpu" ];
    # tty0 puts the kernel log on the virtual display; hvc0 stays last so it
    # remains /dev/console and keeps the serial getty provisioning runs over.
    kernelParams = [
      "console=tty0"
      "console=hvc0"
    ];
    loader = {
      systemd-boot.enable = lib.mkDefault true;
      efi.canTouchEfiVariables = lib.mkDefault false;
    };
  };

  # Lets a SPICE client resize the guest displays and share the clipboard;
  # inert when the guest is run without a SPICE channel.
  services.spice-vdagentd.enable = lib.mkDefault true;

  virtualisation.diskSize = lib.mkDefault (64 * 1024);
}
