# The SPICE client's GTK carries four quartz fixes, so it has to be a distinct
# build. Both live under their own attribute names here: gtk3 and spice-gtk
# keep their usual nixpkgs meaning for everything else in the set.
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
      # The TARGETS list advertises public.png as image/png (and any other
      # UTI under its MIME name), but reading contents looked the MIME name
      # up verbatim, so only text and image/tiff ever returned data. spice-gtk
      # announced PNG to the guest, got 0 bytes back and never answered, and
      # every guest reader of image/png hung until the next clipboard change.
      ./gtk3-quartz-clipboard-read-uti.patch
      # The macOS screenshot tool copies images as TIFF alone, and guest
      # consumers such as omp only take PNG. Offer image/png for a TIFF-only
      # pasteboard and convert on request. Applies on top of the patch above.
      ./gtk3-quartz-clipboard-tiff-as-png.patch
    ];
  });

  # Overriding spice-gtk's gtk3 argument is not enough on its own: the GNOME
  # setup hooks bring stock gtk3 into the build as well, and that is the copy
  # its pkg-config run resolves, so the result still links the unpatched
  # library. Building it in a scope where gtk3 itself is the patched one
  # leaves a single candidate. That scope is private to this attribute.
  spice-gtk-quartz-patched = (prev.extend (_f: _p: { gtk3 = final.gtk3-quartz-patched; })).spice-gtk;
}
