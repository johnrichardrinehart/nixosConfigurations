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

  # virtio-gpu has no virglrenderer behind it on a macOS host, so Mesa only
  # offers llvmpipe and niri refuses software EGL unless asked. Pairs with
  # 0004-tty-allow-opting-into-software-egl.patch in nixosModules.
  systemd.user.extraConfig = "DefaultEnvironment=NIRI_ALLOW_SOFTWARE_EGL=1";

  # niri's shared config ends with `include optional=true "/tmp/niri.kdl"`, so
  # this is where machine-local overrides go. Point niri's renderer at the
  # primary node: virtio-gpu's render node cannot back a software EGL renderer,
  # and Smithay registers the GPU under card0 instead. Pairs with
  # 0005-tty-honour-configured-node-for-software-egl.patch in nixosModules.
  environment.etc."niri/vm-overrides.kdl".text = ''
    debug {
        render-drm-device "/dev/dri/card0"
    }
  '';
  systemd.tmpfiles.rules = [ "L+ /tmp/niri.kdl - - - - /etc/niri/vm-overrides.kdl" ];

  # Lets a SPICE client resize the guest displays and share the clipboard;
  # inert when the guest is run without a SPICE channel.
  services.spice-vdagentd.enable = lib.mkDefault true;

  virtualisation.diskSize = lib.mkDefault (64 * 1024);
}
