{
  bootstrapIso,
  coreutils,
  expect,
  guestFlake,
  gvproxy,
  installerBoot,
  lib,
  serialProvisioner,
  vfkit,
  writeShellApplication,
}:
writeShellApplication {
  name = "mbp-apple-silicon-vm";
  runtimeInputs = [
    coreutils
    expect
    gvproxy
    vfkit
  ];

  text = ''
    usage() {
      cat <<'EOF'
    Usage: mbp-apple-silicon-vm [--installer] [--reset] [--mount] [--no-gui]
                                [--state-dir PATH]
                                [-- VFKit arguments...]

    A newly created disk boots the pinned NixOS ARM installer. The launcher then
    waits for its serial shell, fetches this flake's generated Disko script,
    partitions and formats /dev/vda, and mounts it under /mnt.

    When provisioning finishes, install the small bootstrap system:
      sudo nixos-install \
        --flake github:johnrichardrinehart/nixosConfigurations#mbp-apple-silicon-bootstrap

    nixos-install builds into /mnt, so the target disk holds the closure.
    nixos-rebuild instead builds into the installer's own store, a RAM disk
    of about half the guest memory, and runs out of space on any real system.

    Later runs boot that persistent system. Rebuild it to the full
    mbp-apple-silicon configuration from inside the installed guest, or pass
    that attribute to nixos-install directly to skip the bootstrap step.
    Pass --installer to attach the ISO again.

    --mount boots the installer and mounts the existing filesystems under /mnt
    with disko's own options, which is how to reinstall without reformatting.
    Mounting the ESP by hand instead leaves it world readable and systemd-boot
    writes its random seed into a world accessible file.

    Environment:
      MBP_APPLE_VM_GUI              0 disables the graphical window (default: 1)
      MBP_APPLE_VM_CPUS             Virtual CPU count (default: every host core)
      MBP_APPLE_VM_MEMORY_MIB       Guest memory in MiB (default: 80% of host RAM)
      MBP_APPLE_VM_DISK_SIZE        Sparse persistent disk size (default: 512G)
      MBP_APPLE_VM_DISPLAY_WIDTH    Virtual display width (default: 1920)
      MBP_APPLE_VM_DISPLAY_HEIGHT   Virtual display height (default: 1200)
                                    Virtualization.framework supports a single
                                    scanout, so the guest always sees exactly
                                    one output at this resolution.
      MBP_APPLE_VM_NETWORK_DEVICE   Custom VFKit network descriptor; bypasses gvproxy
      MBP_APPLE_VM_SSH_PORT         Host SSH forwarding port (default: 2223)
      MBP_APPLE_VM_SHARED_DIR       Optional host directory shared as "host"
      MBP_APPLE_VM_STATE_DIR        Persistent VM state directory
      MBP_APPLE_VM_IMAGE            Preinstalled raw disk image copied on first run
    EOF
    }

    installer=0
    provision=0
    mount_only=0
    reset=0
    gui="''${MBP_APPLE_VM_GUI:-1}"
    state_dir="''${MBP_APPLE_VM_STATE_DIR:-''${XDG_DATA_HOME:-$HOME/Library/Application Support}/mbp-apple-silicon-vm}"
    while (( $# > 0 )); do
      case "$1" in
        --installer)
          installer=1
          shift
          ;;
        --reset)
          installer=1
          reset=1
          shift
          ;;
        --mount)
          installer=1
          mount_only=1
          shift
          ;;
        --gui)
          gui=1
          shift
          ;;
        --no-gui)
          gui=0
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
    needs_provision="$state_dir/needs-provision"

    if (( reset )); then
      rm -f "$disk" "$variable_store" "$needs_provision"
    fi

    if [[ ! -e "$disk" ]]; then
      if [[ -n "''${MBP_APPLE_VM_IMAGE:-}" ]]; then
        if [[ ! -f "$MBP_APPLE_VM_IMAGE" ]]; then
          echo "guest image not found: $MBP_APPLE_VM_IMAGE" >&2
          exit 1
        fi
        temporary_disk="$disk.tmp.$$"
        trap 'rm -f "$temporary_disk"' EXIT
        if ! /bin/cp -c "$MBP_APPLE_VM_IMAGE" "$temporary_disk" 2>/dev/null; then
          cp --sparse=always "$MBP_APPLE_VM_IMAGE" "$temporary_disk"
        fi
        chmod u+w "$temporary_disk"
        mv "$temporary_disk" "$disk"
        trap - EXIT
      else
        truncate -s "''${MBP_APPLE_VM_DISK_SIZE:-512G}" "$disk"
        touch "$needs_provision"
        installer=1
      fi
    fi

    if [[ -e "$needs_provision" ]]; then
      installer=1
      provision=1
    fi

    # Default to the whole machine: every core, and 80% of RAM left for the
    # guest with the rest reserved for macOS.
    host_cpus=$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)
    host_memory_bytes=$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 0)
    if (( host_memory_bytes > 0 )); then
      host_memory=$(( host_memory_bytes * 8 / 10 / 1024 / 1024 ))
    else
      host_memory=8192
    fi

    cpus="''${MBP_APPLE_VM_CPUS:-$host_cpus}"
    memory="''${MBP_APPLE_VM_MEMORY_MIB:-$host_memory}"
    display_width="''${MBP_APPLE_VM_DISPLAY_WIDTH:-1920}"
    display_height="''${MBP_APPLE_VM_DISPLAY_HEIGHT:-1200}"
    network_device="''${MBP_APPLE_VM_NETWORK_DEVICE:-}"
    gvproxy_pid=""
    network_socket=""
    cleanup() {
      if [[ -n "$gvproxy_pid" ]]; then
        kill "$gvproxy_pid" 2>/dev/null || true
        wait "$gvproxy_pid" 2>/dev/null || true
        rm -f "$network_socket"
      fi
    }
    trap cleanup EXIT INT TERM

    if [[ -z "$network_device" ]]; then
      network_socket="''${TMPDIR:-/tmp}/mbp-vm-$UID-$$.sock"
      rm -f "$network_socket"
      gvproxy \
        --mtu 1500 \
        --ssh-port "''${MBP_APPLE_VM_SSH_PORT:-2223}" \
        --listen-vfkit "unixgram://$network_socket" \
        --log-file "$state_dir/gvproxy.log" &
      gvproxy_pid=$!
      for _ in {1..100}; do
        if [[ -S "$network_socket" ]]; then
          break
        fi
        if ! kill -0 "$gvproxy_pid" 2>/dev/null; then
          echo "gvproxy exited before creating $network_socket" >&2
          exit 1
        fi
        sleep 0.1
      done
      if [[ ! -S "$network_socket" ]]; then
        echo "timed out waiting for gvproxy socket $network_socket" >&2
        exit 1
      fi
      network_device="virtio-net,unixSocketPath=$network_socket,mac=5a:94:ef:e4:0c:ee"
    fi

    if (( installer )); then
      # Apple's EFI firmware never reaches the serial line either, so the
      # installer is booted straight from the kernel the ISO ships.
      bootloader="linux,kernel=${installerBoot}/Image,initrd=${installerBoot}/initrd,cmdline=\"$(cat ${installerBoot}/cmdline)\""
    else
      bootloader="efi,variable-store=$variable_store,create"
    fi

    vfkit_args=(
      --cpus "$cpus"
      --memory "$memory"
      --bootloader "$bootloader"
      --device "virtio-blk,path=$disk"
      --device "$network_device"
      --device virtio-rng
      --device virtio-balloon
      --device "virtio-gpu,width=$display_width,height=$display_height"
      --device "virtio-input,keyboard"
      --device "virtio-input,pointing"
      --device "virtio-serial,stdio"
    )

    # vfkit only draws a window when asked; without this the virtio-gpu device
    # exists but nothing is ever displayed.
    if (( gui )); then
      vfkit_args+=( --gui )
    fi

    if (( installer )); then
      vfkit_args+=(
        --device "usb-mass-storage,path=${bootstrapIso},readonly"
      )
    fi

    if [[ -n "''${MBP_APPLE_VM_SHARED_DIR:-}" ]]; then
      vfkit_args+=(
        --device "virtio-fs,sharedDir=$MBP_APPLE_VM_SHARED_DIR,mountTag=host"
      )
    fi

    if (( provision || mount_only )); then
      # mountScript only mounts, with the options disko declares (the ESP's
      # umask=0077 among them); diskoScript wipes and formats first. Hand
      # mounting the ESP instead leaves it world readable, which systemd-boot
      # rightly refuses to keep quiet about.
      if (( mount_only )); then
        disko_attr=mountScript
        marker=$state_dir/.no-such-marker
      else
        disko_attr=diskoScript
        marker=$needs_provision
      fi
      guest_flake=${lib.escapeShellArg guestFlake}
      # These two run in the guest shell, so nothing may expand here.
      # shellcheck disable=SC2016
      network_command='network_ready=0; for _ in $(seq 1 60); do if getent hosts github.com >/dev/null 2>&1; then network_ready=1; break; fi; sleep 1; done'
      provision_command=$(cat <<EOF
    if (( network_ready )); then disko_output=\$(nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths '$guest_flake#nixosConfigurations."mbp-apple-silicon-bootstrap".config.system.build.$disko_attr') && sudo "\$disko_output"; status=\$?; else echo 'network did not become ready within 60 seconds' >&2; status=69; fi; printf '\n__DISKO_PROVISION_STATUS_%s__\n' "\$status"
    EOF
      )

      if expect ${serialProvisioner} "$network_command" "$provision_command" "$marker" \
        vfkit "''${vfkit_args[@]}" "$@"; then
        status=0
      else
        status=$?
      fi
    elif vfkit "''${vfkit_args[@]}" "$@"; then
      status=0
    else
      status=$?
    fi
    cleanup
    trap - EXIT INT TERM
    exit "$status"
  '';

  meta = {
    description = "Bootstrap and run a NixOS VM with Apple's Virtualization framework";
    mainProgram = "mbp-apple-silicon-vm";
    platforms = [ "aarch64-darwin" ];
  };
}
