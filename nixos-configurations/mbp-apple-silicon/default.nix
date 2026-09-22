{ lib, ... }:
{
  imports = [
    ./base.nix
    ./forced-uid.nix
    ./niri-software-egl.nix
    ./shares.nix
    ./spice-agent.nix
  ];

  security.rtkit.enable = lib.mkDefault true;
  services.pipewire = {
    enable = lib.mkDefault true;
    alsa.enable = lib.mkDefault true;
    pulse.enable = lib.mkDefault true;
  };

  # Outputs reachable from a live .drv stay in the store, so collecting garbage
  # or dropping old generations does not force the next rebuild to redo the
  # work behind the generations that were kept. Retention only; it holds no
  # generations itself.
  nix.settings.keep-outputs = true;

  # The Mac's trackpad reaches the guest through the SPICE client as a plain
  # scroll wheel, never as a touchpad, so monstar routes every tick through
  # its `discrete` multiplier and `precision` is never exercised. The default
  # of 3 lines per tick is too many here. 0.75 is tuned with LinearMouse owning
  # scroll on the host side, which drops macOS momentum - an earlier 0.1 was
  # chosen before that and became too slow. Appended rather than restating the
  # shared block so upstream font and theme changes flow through.
  home-manager.users.john.home.file.".config/monstar/config".text = lib.mkAfter ''
    mouse-scroll-multiplier = discrete:0.75
  '';

  # mutableUsers stays on, so this is only applied when the account is first
  # created and `passwd` overrides it from then on. It lands the plaintext in
  # the world-readable store, which is the trade for a VM that must be
  # recoverable without a console.
  users.users.john.initialPassword = "john";

  dev.johnrinehart = {
    profiles.laptop.enable = true;
    desktop.greetd_niri.niri.displayModeWatch.enable = lib.mkDefault false;

    # The guest has no Bluetooth controller. The laptop profile turns on
    # bt-auto-suspend, whose oneshot runs `bluetoothctl devices Connected`
    # with no TimeoutStartSec; without an adapter bluetoothctl blocks forever,
    # the job never finishes and `nixos-rebuild switch` hangs on it whenever
    # the unit is (re)started. Nothing in here uses Bluetooth, so the module
    # goes off whole - bluez, blueman and the timer with it - rather than
    # masking the two units and leaving the rest running against nothing.
    bluetooth.enable = false;

    # The guest has one head - the virtio-gpu scanout the SPICE client draws -
    # and its only input path is that same client's window. hypridle's medium
    # listener runs `niri msg action power-off-monitors`, which disables the
    # scanout; QEMU then publishes a monitors-config with no monitors, and
    # spicy answers by destroying its window and telling the server it no
    # longer wants the display (del_window, spice-gtk tools/spicy.c). Nothing
    # recovers from there: the window is gone, so no input can reach niri to
    # turn the head back on, and the client keeps its channels open so the
    # launcher's reconnect loop never sees a client exit. The listener carries
    # no on-resume, and adding one would not help - there is no longer
    # anything to resume on.
    #
    # The daemon goes off whole rather than losing that one listener, because
    # the other two are already no-ops in here: the short listener asks for a
    # lock niri will not serve ("Session does not support lock screen") and
    # the long one suspends through suspend-then-hibernate, which this guest
    # does not configure ("Sleep verb 'suspend-then-hibernate' is not
    # configured"). Both fail every time they fire.
    desktop.greetd_niri.hypridle.enable = lib.mkDefault false;
  };

  # The option above only governs whether hypridle.conf is written; the unit
  # itself is enabled unconditionally by greetd+niri.nix, so it has to be
  # stopped separately or the daemon would start with no configuration at all.
  services.hypridle.enable = lib.mkForce false;
}
