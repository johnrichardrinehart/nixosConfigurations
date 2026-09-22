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
  # this is where machine-local overrides go.
  #
  # debug: point niri's renderer at the primary node: virtio-gpu's render node
  # cannot back a software EGL renderer, and Smithay registers the GPU under
  # card0 instead. Pairs with
  # 0005-tty-honour-configured-node-for-software-egl.patch in nixosModules.
  #
  # output: QEMU advertises the MacBook panel's native mode (3024x1898) to the
  # guest at scale 1, which leaves the bar, windows and text tiny. 1.5 gives a
  # logical 2016x1265 - readable, with more room than an integer 2x. The
  # launcher sizes every Virtual-N after the Mac's primary monitor, so this
  # assumes the panel is primary and only names the first head.
  environment.etc."niri/vm-overrides.kdl".text = ''
    debug {
        render-drm-device "/dev/dri/card0"
    }

    output "Virtual-1" {
        scale 1.5
    }
  '';
  systemd.tmpfiles.rules = [ "L+ /tmp/niri.kdl - - - - /etc/niri/vm-overrides.kdl" ];

  # Lets a SPICE client resize the guest displays and share the clipboard;
  # inert when the guest is run without a SPICE channel.
  services.spice-vdagentd.enable = lib.mkDefault true;

  virtualisation.diskSize = lib.mkDefault (64 * 1024);
}
