{
  coreutils,
  guestImage,
  guestImageFile,
  lib,
  vfkit,
  writeShellApplication,
}:
writeShellApplication {
  name = "mbp-apple-silicon-vm";
  runtimeInputs = [
    coreutils
    vfkit
  ];

  text = ''
    usage() {
      cat <<'EOF'
    Usage: mbp-apple-silicon-vm [--reset] [--state-dir PATH] [-- VFKit arguments...]

    Environment:
      MBP_APPLE_VM_CPUS             Virtual CPU count (default: 4)
      MBP_APPLE_VM_MEMORY_MIB       Guest memory in MiB (default: 8192)
      MBP_APPLE_VM_DISPLAY_WIDTH    Virtual display width (default: 1920)
      MBP_APPLE_VM_DISPLAY_HEIGHT   Virtual display height (default: 1200)
      MBP_APPLE_VM_NETWORK_DEVICE   VFKit network descriptor (default: virtio-net,nat)
      MBP_APPLE_VM_SHARED_DIR       Optional host directory shared as "host"
      MBP_APPLE_VM_STATE_DIR        Persistent VM state directory
    EOF
    }

    reset=0
    state_dir="''${MBP_APPLE_VM_STATE_DIR:-''${XDG_DATA_HOME:-$HOME/Library/Application Support}/mbp-apple-silicon-vm}"
    while (( $# > 0 )); do
      case "$1" in
        --reset)
          reset=1
          shift
          ;;
        --state-dir)
          if (( $# < 2 )); then
            echo "--state-dir requires a path" >&2
            exit 2
          fi
          state_dir=$2
          shift 2
          ;;
        --help|-h)
          usage
          exit 0
          ;;
        --)
          shift
          break
          ;;
        *)
          break
          ;;
      esac
    done

    mkdir -p "$state_dir"
    disk="$state_dir/root.img"
    variable_store="$state_dir/efi-variable-store"
    template=${lib.escapeShellArg "${guestImage}/${guestImageFile}"}

    if (( reset )); then
      rm -f "$disk" "$variable_store"
    fi

    if [[ ! -e "$disk" ]]; then
      temporary_disk="$disk.tmp.$$"
      trap 'rm -f "$temporary_disk"' EXIT
      if ! /bin/cp -c "$template" "$temporary_disk" 2>/dev/null; then
        cp --sparse=always "$template" "$temporary_disk"
      fi
      chmod u+w "$temporary_disk"
      mv "$temporary_disk" "$disk"
      trap - EXIT
    fi

    cpus="''${MBP_APPLE_VM_CPUS:-4}"
    memory="''${MBP_APPLE_VM_MEMORY_MIB:-8192}"
    display_width="''${MBP_APPLE_VM_DISPLAY_WIDTH:-1920}"
    display_height="''${MBP_APPLE_VM_DISPLAY_HEIGHT:-1200}"
    network_device="''${MBP_APPLE_VM_NETWORK_DEVICE:-virtio-net,nat}"

    vfkit_args=(
      --cpus "$cpus"
      --memory "$memory"
      --bootloader "efi,variable-store=$variable_store,create"
      --device "virtio-blk,path=$disk"
      --device "$network_device"
      --device virtio-rng
      --device virtio-balloon
      --device "virtio-gpu,width=$display_width,height=$display_height"
      --device "virtio-input,keyboard"
      --device "virtio-input,pointing"
      --device "virtio-serial,stdio"
    )

    if [[ -n "''${MBP_APPLE_VM_SHARED_DIR:-}" ]]; then
      vfkit_args+=(
        --device "virtio-fs,sharedDir=$MBP_APPLE_VM_SHARED_DIR,mountTag=host"
      )
    fi

    exec vfkit "''${vfkit_args[@]}" "$@"
  '';

  meta = {
    description = "Run the mbp-apple-silicon NixOS guest with Apple's Virtualization framework";
    mainProgram = "mbp-apple-silicon-vm";
    platforms = [ "aarch64-darwin" ];
  };
}
