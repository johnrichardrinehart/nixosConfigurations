{
  inputs,
  lib,
  ...
}:
{
  imports = [
    inputs.apple-silicon.nixosModules.default
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  networking = {
    hostName = lib.mkDefault "mbp-apple-silicon";
    networkmanager.enable = lib.mkDefault true;
  };

  hardware.asahi = {
    enable = true;
    # Downstream hosts should point peripheralFirmwareDirectory at their
    # machine-specific firmware bundle before enabling extraction.
    extractPeripheralFirmware = lib.mkDefault false;
    avd.enable = lib.mkDefault false;
  };
  boot.loader = {
    systemd-boot.enable = lib.mkDefault true;
    efi.canTouchEfiVariables = lib.mkDefault false;
  };

  fileSystems."/" = {
    device = lib.mkDefault "/dev/disk/by-label/nixos";
    fsType = lib.mkDefault "ext4";
  };

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
