# The SPICE client's GTK carries seven quartz fixes, so it has to be a distinct
# build, and spicy fixes of its own. Both live under their own attribute
# names here: gtk3 and spice-gtk keep their usual nixpkgs meaning for
# everything else in the set.
final: prev: {
  gtk3-quartz-patched = prev.gtk3.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      # https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/10388
      (prev.fetchpatch2 {
        name = "quartz-poll-descriptor-race.patch";
        url = "https://gitlab.gnome.org/johnrichardrinehart/gtk/-/commit/dccd93038aa034ab36b768b34fb727418fb83288.patch";
        hash = "sha256-f8jgV5RR3mqjYXt0MzPmtLXl0jgCGT6ErFbBQ51dk4I=";
      })
      # https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/10389
      (prev.fetchpatch2 {
        name = "quartz-clipboard-owner-change.patch";
        url = "https://gitlab.gnome.org/johnrichardrinehart/gtk/-/commit/b33cff2db0d6a021bc9c784b2a68f8735ca7eebd.patch";
        hash = "sha256-aBu9s5UlHxtwoYzXMofoBlbvTugIybd+PX1b7aCNGGc=";
      })
      # https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/10418
      # The TARGETS list advertises public.png as image/png (and any other
      # UTI under its MIME name), but reading contents looked the MIME name
      # up verbatim, so only text and image/tiff ever returned data. spice-gtk
      # announced PNG to the guest, got 0 bytes back and never answered, and
      # every guest reader of image/png hung until the next clipboard change.
      (prev.fetchpatch2 {
        name = "quartz-clipboard-read-uti.patch";
        url = "https://gitlab.gnome.org/johnrichardrinehart/gtk/-/commit/ab37ec7e52cd80c6bb7275dc57e13f6333783da1.patch";
        hash = "sha256-CzKtI9QmYdvAQS57Dorc+zqEP62m8b1usjU/F2tEJxA=";
      })
      # https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/10419
      # The macOS screenshot tool copies images as TIFF alone, and guest
      # consumers such as omp only take PNG. Offer image/png for a TIFF-only
      # pasteboard and convert on request. Applies on top of the patch above.
      (prev.fetchpatch2 {
        name = "quartz-clipboard-tiff-as-png.patch";
        url = "https://gitlab.gnome.org/johnrichardrinehart/gtk/-/commit/b304affecf9df7c637402d502a69506b60b9a884.patch";
        hash = "sha256-fH0HT8qZx08uhPOs2N5qHZq4XNgS4sy7nb41OW544fQ=";
      })
      # https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/10415
      # A modifier key's press or release was judged by the flag both keys
      # of its left/right pair share, so releasing one Shift while holding
      # the other came out as another press: the guest kept that Shift held
      # until spicy lost and regained focus. Decide by the key's own
      # device-dependent bit.
      (prev.fetchpatch2 {
        name = "quartz-modifier-sides.patch";
        url = "https://gitlab.gnome.org/johnrichardrinehart/gtk/-/commit/d6adfa92514a7adbe8aa6f30cea6d0549516a307.patch";
        hash = "sha256-D1l9cVJS1Z1HXsA+wtlWFZgl3DLdqzlneU/su1rdXeY=";
      })
      # https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/10417, merged into
      # gtk-3-24 after 3.24.52.
      # gdk_keymap_get_caps_lock_state() always said FALSE, so spice-gtk's
      # lock sync turned the guest's Caps Lock off on every focus-in. Read
      # the real state.
      (prev.fetchpatch2 {
        name = "quartz-caps-lock-state.patch";
        url = "https://gitlab.gnome.org/GNOME/gtk/-/commit/2cc84440712c9b1d18f8a2a4ac4fbd10823bc818.patch";
        hash = "sha256-B4dxF62cQ4UlwXaa083HixE2Hrie2d0o1quEtXjufTY=";
      })
      # https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/10420
      # gtk_window_maximize() before the window is shown reaches the quartz
      # backend while the window is still unmapped, and it only zoomed mapped
      # windows, so spicy --maximized opened at the default size. Remember
      # the request and zoom once shown.
      (prev.fetchpatch2 {
        name = "quartz-initial-maximize.patch";
        url = "https://gitlab.gnome.org/johnrichardrinehart/gtk/-/commit/9fe1cd3659e172b2e99e7e7de7f0f6fe5fd832a8.patch";
        hash = "sha256-+gaIJ5o31ljwUAyE5pUpEQs1j/RSpe3k9IXYareHRAc=";
      })
    ];
  });

  # Overriding spice-gtk's gtk3 argument is not enough on its own: the GNOME
  # setup hooks bring stock gtk3 into the build as well, and that is the copy
  # its pkg-config run resolves, so the result still links the unpatched
  # library. Building it in a scope where gtk3 itself is the patched one
  # leaves a single candidate. That scope is private to this attribute.
  spice-gtk-quartz-patched =
    let
      inherit (prev) lib stdenv;
      scope = prev.extend (_f: _p: { gtk3 = final.gtk3-quartz-patched; });
    in
    scope.spice-gtk.overrideAttrs (old: {
      # nixpkgs packages 0.42. 0.43 publishes no tarball, so this builds the
      # tag, whose tree lacks the .tarball-version meson reads the version
      # from.
      version = "0.43";
      src = prev.fetchFromGitLab {
        domain = "gitlab.freedesktop.org";
        owner = "spice";
        repo = "spice-gtk";
        tag = "v0.43";
        hash = "sha256-e0B3shnXDwKMPvy1nyz/iNPPRGJbnygh0bqIufq/93g=";
        fetchSubmodules = true;
      };
      postUnpack = (old.postUnpack or "") + ''
        echo 0.43 > "$sourceRoot/.tarball-version"
      '';

      # 0.43 documents its API with gi-docgen instead of gtk-doc, and nixpkgs'
      # meson hook turns its auto gtk_doc feature on. Only spicy is used from
      # this build, so the reference is disabled, and with it the devdoc
      # output that held it.
      outputs = lib.remove "devdoc" old.outputs;
      nativeBuildInputs = lib.subtractLists [
        scope.docbook_xsl
        scope.gtk-doc
      ] old.nativeBuildInputs;
      mesonFlags = old.mesonFlags ++ [ "-Dgtk_doc=disabled" ];

      # nixpkgs' Darwin edit of the version script is for 0.42: 0.43's
      # meson.build goes without one wherever the linker lacks support. What
      # 0.43 needs on Darwin instead is a stand-in for drm/drm_fourcc.h, a
      # Linux uAPI header it takes a single constant from.
      postPatch = ''
        # get rid of absolute path to helper in store so we can use a setuid wrapper
        substituteInPlace src/usb-acl-helper.c \
          --replace-fail 'ACL_HELPER_PATH"/' '"'
        # don't try to setcap/suid in a nix builder
        substituteInPlace src/meson.build \
          --replace-fail "meson.add_install_script('../build-aux/setcap-or-suid'," \
          "# meson.add_install_script('../build-aux/setcap-or-suid',"

        patchShebangs subprojects/keycodemapdb/tools/keymap-gen
      ''
      + lib.optionalString stdenv.hostPlatform.isDarwin ''
        substituteInPlace src/channel-display.c --replace-fail \
          '#include <drm/drm_fourcc.h>' \
          '#define DRM_FORMAT_MOD_INVALID 0x00ffffffffffffffULL'
      '';

      patches = (old.patches or [ ]) ++ [
        # https://gitlab.freedesktop.org/spice/spice-gtk/-/merge_requests/154
        # spicy saves its settings on exit by renaming a new file over the
        # old one, which replaced Home Manager's read-only link with
        # whatever the running window held. Skip the save when the file
        # is not writable.
        (prev.fetchpatch2 {
          name = "spicy-read-only-settings.patch";
          url = "https://gitlab.freedesktop.org/johnrichardrinehart/spice-gtk/-/commit/c98b7d6f47904f8001b76830d39a86eadf5ea698.patch";
          hash = "sha256-Q7SueFKmJFLR8bpkweoiuI1yEqLi/7ijsxEkJk/smo8=";
        })
        # https://gitlab.freedesktop.org/spice/spice-gtk/-/merge_requests/155
        # Adds --no-save-settings, which the VM launcher passes so every
        # session starts from the declared settings. Built on the patch
        # above: both change the same save-on-exit code.
        (prev.fetchpatch2 {
          name = "spicy-no-save-settings.patch";
          url = "https://gitlab.freedesktop.org/johnrichardrinehart/spice-gtk/-/commit/e3aa208a1fa3ae7628c8c5c91f58096c66ad9707.patch";
          hash = "sha256-p/AYC+eBHbaV+UWA3AmV/cGWjXndg2L5Y+kv75zqlvU=";
        })
        # https://gitlab.freedesktop.org/spice/spice-gtk/-/merge_requests/156
        # macOS reports Caps Lock as a press when the lock turns on and a
        # release when it turns off, so the guest turned it off only when
        # the lock sync caught up, a second or two late. Send each change
        # as a whole keystroke.
        (prev.fetchpatch2 {
          name = "spice-widget-quartz-caps-lock-tap.patch";
          url = "https://gitlab.freedesktop.org/johnrichardrinehart/spice-gtk/-/commit/5bb1f2e604f024318a67f54eed2b854e71f025c4.patch";
          hash = "sha256-3eZQ7k6vYriswt8BGx+awyqIh69p7p+YZqMZ/PRBa0M=";
        })
        # https://gitlab.freedesktop.org/spice/spice-gtk/-/merge_requests/157
        # Adds --maximized, which the VM launcher passes so the viewer opens
        # filling the screen instead of at the guest's last, small size.
        # After --no-save-settings above, its first hunk applies with one
        # line of fuzz.
        (prev.fetchpatch2 {
          name = "spicy-maximized.patch";
          url = "https://gitlab.freedesktop.org/johnrichardrinehart/spice-gtk/-/commit/bce44ef3030d43ac58883f6aabe14b5dfb1bde4a.patch";
          hash = "sha256-ByF5OKo+5h8dmEN3jJsxXXbEP/i3ARsk7Z45WBWqzXs=";
        })
      ];
    });
}
