{ lib, ... }:
{
  imports = [ ./base.nix ];

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
