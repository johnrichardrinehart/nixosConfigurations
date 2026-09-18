_: {
  # niri rejects a software EGL device outright - the ensure! near the top of
  # Tty::try_initialize_gpu in src/backend/tty.rs - and QEMU's virtio-gpu has no
  # virglrenderer behind it on a macOS host, so Mesa offers only llvmpipe. The
  # compositor therefore starts with no renderer and no outputs at all, which
  # leaves the SPICE displays blank and makes the guest agent report a 0x0
  # desktop that spice-vdagentd discards as coming from an old agent.
  #
  # base.nix already sets NIRI_ALLOW_SOFTWARE_EGL and pins render-drm-device,
  # but the two upstream commits that taught niri to honour them are newer than
  # the pinned release. Carry them until the package catches up.
  #
  # The hook is pkgs.niri rather than programs.niri.package because
  # greetd+niri.nix derives its compositor with
  # `pkgs.niri.overrideAttrs (old: { patches = (old.patches or []) ++ ... })`,
  # so whatever is added here is carried into the package it actually installs.
  # Neither patch touches a Cargo file, so the cargoDeps hash pinned there
  # stays valid.
  nixpkgs.overlays = [
    (_final: prev: {
      niri = prev.niri.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          # https://github.com/niri-wm/niri/pull/4614
          (prev.fetchpatch2 {
            name = "tty-allow-opting-into-software-egl.patch";
            url = "https://github.com/johnrichardrinehart/niri/commit/aaabc0c46be0828d60a8c827ee2acfacb3590487.patch?full_index=1";
            hash = "sha256-J5M9fMkOrtoiUuKwaXUxxlrOZakzjApw3Ucytr4R3o8=";
          })
          # https://github.com/niri-wm/niri/pull/4614
          (prev.fetchpatch2 {
            name = "tty-honor-configured-node-for-software-egl.patch";
            url = "https://github.com/johnrichardrinehart/niri/commit/eb81ec601ba6f10147a32e75ccc7a6e54e789224.patch?full_index=1";
            hash = "sha256-iQdFsZYvAXwAuw/QXFyWU2BM0fSAev/2utE/1IWZzdE=";
          })
        ];
      });
    })
  ];
}
