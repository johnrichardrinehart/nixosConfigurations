# The SPICE client's GTK carries five quartz fixes, so it has to be a distinct
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
      # https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/10417
      # gdk_keymap_get_caps_lock_state() always said FALSE, so spice-gtk's
      # lock sync turned the guest's Caps Lock off on every focus-in. Read
      # the real state.
      (prev.fetchpatch2 {
        name = "quartz-caps-lock-state.patch";
        url = "https://gitlab.gnome.org/johnrichardrinehart/gtk/-/commit/b5baf6c53b67aadecf0b0bd5831d443dad37c5bc.patch";
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
    (prev.extend (_f: _p: { gtk3 = final.gtk3-quartz-patched; })).spice-gtk.overrideAttrs
      (old: {
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
          # filling the screen instead of at the guest's last, small size. The
          # MR targets master; this is its backport onto 0.42 and the patches
          # above (branch spicy-maximized-0.42 on the fork).
          (prev.fetchpatch2 {
            name = "spicy-maximized.patch";
            url = "https://gitlab.freedesktop.org/johnrichardrinehart/spice-gtk/-/commit/46c87707b23522144b96f13e7f24240bcce5967f.patch";
            hash = "sha256-XRJOb3+17avdnwxeelVjSKeXqydeI3UuZ3jUb03qRxQ=";
          })
        ];
      });
}
