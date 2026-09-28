{
  # Disko installs GRUB to the disk's BIOS boot partition in the generated image.
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/vda";
    # Sparse image size; the root partition and ext4 grow on the Droplet's first boot.
    imageSize = "8G";
    content = {
      type = "gpt";
      partitions = {
        bios = {
          priority = 1;
          type = "EF02";
          size = "1M";
        };
        boot = {
          type = "0700";
          size = "2G";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
