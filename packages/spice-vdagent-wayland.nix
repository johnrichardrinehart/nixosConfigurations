{
  alsa-lib,
  autoreconfHook,
  dbus,
  fetchFromGitHub,
  fetchpatch2,
  glib,
  gtk4,
  lib,
  libdrm,
  libpciaccess,
  libxcb,
  libxfixes,
  libxinerama,
  libxrandr,
  pkg-config,
  spice-protocol,
  stdenv,
  systemd,
  wayland,
}:
# spice-vdagent with the Wayland work that upstream 0.23.0 only half has.
# Upstream's --with-gtk4=yes defines USE_GTK_FOR_MONITORS but deliberately not
# USE_GTK_FOR_CLIPBOARD, because its clipboard.c is written against GTK3's
# GtkClipboard, which GTK4 dropped. This fork rewrites that file against
# GdkClipboard and so defines both, which is what makes a Wayland guest able to
# report its layout *and* share a clipboard.
#
# Clipboard is split by direction: host to guest publishes through
# zwlr_data_control_manager_v1 when available and falls back to GdkClipboard;
# guest to host observes through the same data-control protocol. niri
# implements that and wlr-output-management, so both halves land.
stdenv.mkDerivation {
  pname = "spice-vdagent-wayland";
  version = "0.23.0-unstable-2026-09-06";

  src = fetchFromGitHub {
    owner = "bjthompson805";
    repo = "spice-vdagent-wayland";
    rev = "32ed60f27bde7e8acf76f71b0542c70b75a46a47";
    hash = "sha256-95JTHgwRHE+DVVCrsKy3oYwDjf34+DU6WzdPTEr7RH4=";
  };

  postPatch = ''
    substituteInPlace data/spice-vdagent.desktop --replace-fail /usr "$out"
  '';

  # The tree ships no generated configure, unlike the release tarball nixpkgs
  # builds from.
  nativeBuildInputs = [
    autoreconfHook
    pkg-config
  ];

  buildInputs = [
    alsa-lib
    dbus
    glib
    gtk4
    libdrm
    libpciaccess
    libxcb
    libxfixes
    libxinerama
    libxrandr
    spice-protocol
    systemd
    wayland
  ];

  # niri answers org.gnome.Mutter.DisplayConfig for its ScreenCast and
  # ServiceChannel interfaces but reports no monitors through it, and the agent
  # treats that empty-but-successful reply as authoritative, never reaching the
  # GTK backend that can see the outputs.
  patches = [
    # https://github.com/bjthompson805/spice-vdagent-wayland/pull/1
    (fetchpatch2 {
      name = "mutter-empty-display-fallback.patch";
      url = "https://github.com/johnrichardrinehart/spice-vdagent-wayland/commit/7c4a2fc750c2d3df947fe146b7f628d479379b16.patch?full_index=1";
      hash = "sha256-051+WHnLlOSqZ3NxLggCts6izl9iEpXgIh4ahQ0N9zQ=";
    })
    # A headless agent can never set a wl_data_device selection: that needs a
    # serial from an input event it has no surface to receive. Before this
    # patch, the write side goes through GdkClipboard, so on a compositor that
    # enforces the serial - niri does - the host clipboard reaches the agent
    # and stops dead there. Take the selection over
    # zwlr_data_control_device_v1 instead, which exists precisely for
    # focus-less clipboard ownership.
    # https://github.com/bjthompson805/spice-vdagent-wayland/pull/2
    (fetchpatch2 {
      name = "data-control-clipboard-write.patch";
      url = "https://github.com/johnrichardrinehart/spice-vdagent-wayland/commit/d88eb06b9054926a8058af285d85ba0acb937b3a.patch?full_index=1";
      hash = "sha256-6639ldKVL1WZJee/QINIFhx81SN3Y3zzseg32otvJb4=";
    })
  ];

  configureFlags = [ "--with-gtk4=yes" ];

  meta = {
    description = "SPICE guest agent with native Wayland clipboard and monitor support";
    homepage = "https://github.com/bjthompson805/spice-vdagent-wayland";
    license = lib.licenses.gpl3Plus;
    mainProgram = "spice-vdagent";
    platforms = lib.platforms.linux;
  };
}
