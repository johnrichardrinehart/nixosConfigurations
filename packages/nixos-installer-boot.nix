{
  bootstrapIso,
  libarchive,
  runCommand,
}:
# The published ISO boots through GRUB with no console= parameter, so a guest
# driven over a serial line stays silent forever: the installer only ever
# speaks to the framebuffer. Pull the ISO's own kernel and initrd out of the
# image so a hypervisor can boot them directly with a console of our choosing.
# hvc0 is where QEMU's virtconsole shows up inside the guest.
runCommand "nixos-installer-boot"
  {
    nativeBuildInputs = [ libarchive ];
  }
  ''
    mkdir -p "$out"
    bsdtar -xOf ${bootstrapIso} EFI/BOOT/grub.cfg > grub.cfg

    # GRUB only sets ''${isoboot} when the ISO is chainloaded from another
    # bootloader; dropping it leaves the entry the ISO boots by default.
    linux_line=$(grep -m1 -E '^[[:space:]]*linux /boot/' grub.cfg | sed 's|[$]{isoboot}||')
    initrd_line=$(grep -m1 -E '^[[:space:]]*initrd /boot/' grub.cfg)
    if [[ -z $linux_line || -z $initrd_line ]]; then
      echo "no installer boot entry found in the ISO's grub.cfg" >&2
      exit 1
    fi

    kernel_member=$(awk '{ print $2 }' <<< "$linux_line" | sed -e 's|^/||' -e 's|//|/|g')
    initrd_member=$(awk '{ print $2 }' <<< "$initrd_line" | sed -e 's|^/||' -e 's|//|/|g')
    cmdline=$(awk '{ $1 = ""; $2 = ""; sub(/^ +/, ""); print }' <<< "$linux_line")

    bsdtar -xOf ${bootstrapIso} "$kernel_member" > "$out/Image"
    bsdtar -xOf ${bootstrapIso} "$initrd_member" > "$out/initrd"
    printf '%s console=hvc0' "$cmdline" > "$out/cmdline"

    test -s "$out/Image"
    test -s "$out/initrd"
  ''
