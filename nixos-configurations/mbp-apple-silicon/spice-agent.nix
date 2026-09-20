{ pkgs, ... }:
{
  # nixpkgs builds spice-vdagent against XRandr and no GTK at all, so the
  # session half of the agent can only read the screen layout through an X
  # server. niri never starts one, so the agent reports no resolution,
  # check_xorg_resolution in src/vdagentd/vdagentd.c never opens the virtio
  # channel, and reds_update_mouse_mode in spice-server therefore sees no
  # agent. With more than one scanout that is the only branch that can grant
  # absolute mouse mode, so the client falls back to relative mode, grabs the
  # host pointer and warps it to the centre of the primary monitor.
  #
  # Upstream cannot fix both halves at once: its GTK4 build gets the Wayland
  # monitor layout but loses the clipboard, because clipboard.c is GTK3-only.
  # The fork carries a GdkClipboard rewrite so one build does both. It replaces
  # spice-vdagent wholesale so services.spice-vdagentd picks it up too.
  nixpkgs.overlays = [
    (final: _prev: {
      spice-vdagent = final.callPackage ../../packages/spice-vdagent-wayland.nix { };
    })
  ];

  # vdagentd places the client's absolute positions through a uinput device it
  # creates once the agent reports a resolution, so the module has to be loaded
  # before it can do so.
  hardware.uinput.enable = true;

  # Even the GTK4 build opens an X display unconditionally: vdagent_display_create
  # in src/vdagent/display.c calls vdagent_x11_create first and gives up when
  # XOpenDisplay returns NULL. niri covers that itself - it listens on :0 and
  # spawns xwayland-satellite on the first connection - so nothing needs adding
  # here beyond pointing the agent at that display.
  #
  # The session agent ships as an XDG autostart entry, which niri does not
  # read. The condition keeps it quiet where no SPICE port is exposed; the
  # restart covers losing the race with spice-vdagentd's socket.
  systemd.user.services.spice-vdagent = {
    description = "SPICE session guest agent";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    unitConfig.ConditionPathExists = "/dev/virtio-ports/com.redhat.spice.0";
    serviceConfig = {
      ExecStart = "${pkgs.spice-vdagent}/bin/spice-vdagent -x";
      Environment = [ "DISPLAY=:0" ];
      Restart = "on-failure";
      RestartSec = 2;
    };
  };
}
