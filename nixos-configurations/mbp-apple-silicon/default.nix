{ lib, ... }:
{
  imports = [
    ./base.nix
    ./niri-software-egl.nix
    ./spice-agent.nix
  ];

  security.rtkit.enable = lib.mkDefault true;
  services.pipewire = {
    enable = lib.mkDefault true;
    alsa.enable = lib.mkDefault true;
    pulse.enable = lib.mkDefault true;
  };

  # users.mutableUsers is on and no password is declared here, so the guest's
  # credentials exist only inside its own /etc/shadow and nothing on the host
  # can log in once the SPICE client has captured the pointer. Trusting this
  # Mac's key gives the launcher's forwarded port a way in that does not depend
  # on the guest's display working.
  users.users.john.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEyW8KR4ZzTEiwfkK3KTMAcW9daoU28inqBas4g0w+Kq John Rinehart Hoth MBP"
  ];

  # mutableUsers stays on, so this is only applied when the account is first
  # created and `passwd` overrides it from then on. It lands the plaintext in
  # the world-readable store, which is the trade for a VM that must be
  # recoverable without a console.
  users.users.john.initialPassword = "john";

  dev.johnrinehart = {
    profiles.laptop.enable = true;
    desktop.greetd_niri.niri.displayModeWatch.enable = lib.mkDefault false;
  };
}
