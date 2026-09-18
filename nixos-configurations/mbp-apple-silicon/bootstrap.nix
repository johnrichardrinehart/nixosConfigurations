{
  inputs,
  lib,
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [
    ./base.nix
    (modulesPath + "/profiles/minimal.nix")
  ];

  nixpkgs.overlays = [ inputs.nixosModules.overlays.default ];

  system.stateVersion = "24.05";
  documentation.enable = false;
  programs.command-not-found.enable = false;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  networking.useDHCP = lib.mkDefault true;
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  users.users.nixos = {
    isNormalUser = true;
    initialPassword = "nixos";
    extraGroups = [ "wheel" ];
  };
  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = [
    pkgs.gitMinimal
    pkgs.dev.johnrinehart.git-patch-wormhole
  ];
}
