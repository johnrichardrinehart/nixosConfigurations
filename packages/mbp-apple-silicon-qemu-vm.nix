{
  adwaita-icon-theme,
  bootstrapIso,
  coreutils,
  expect,
  gsettings-desktop-schemas,
  gtk3-quartz-patched,
  guestFlake,
  hicolor-icon-theme,
  installerBoot,
  jq,
  lib,
  librsvg,
  makeWrapper,
  qemu,
  runCommand,
  serialProvisioner,
  shared-mime-info,
  spice-gtk-quartz-patched,
  writeShellApplication,
}:
let
  # spice-gtk-quartz-patched and gtk3-quartz-patched come from
  # packages/spice-quartz-overlay.nix; stock gtk3 and spice-gtk are left alone.
  #
  # spice-gtk ships spicy unwrapped, so on its own it finds neither the SVG
  # pixbuf loader its icons need nor the GSettings schemas GTK expects.
  spicyClient =
    runCommand "spicy-client"
      {
        nativeBuildInputs = [ makeWrapper ];
      }
      ''
        mkdir -p "$out/bin"
        makeWrapper ${spice-gtk-quartz-patched}/bin/spicy "$out/bin/spicy" \
          --set GDK_PIXBUF_MODULE_FILE ${librsvg.out}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
          --prefix XDG_DATA_DIRS : ${gtk3-quartz-patched}/share \
          --prefix XDG_DATA_DIRS : ${gsettings-desktop-schemas}/share \
          --prefix XDG_DATA_DIRS : ${adwaita-icon-theme}/share \
          --prefix XDG_DATA_DIRS : ${hicolor-icon-theme}/share \
          --prefix XDG_DATA_DIRS : ${shared-mime-info}/share
      '';
in
writeShellApplication {
  name = "mbp-apple-silicon-qemu-vm";
  runtimeInputs = [
    coreutils
    expect
    jq
    qemu
    spicyClient
  ];

  text = ''
    usage() {
      cat <<'EOF'
    Usage: mbp-apple-silicon-qemu-vm [--installer] [--reset] [--mount] [--outputs N|auto]
                                     [--display spice|cocoa|none] [--no-client]
                                     [--state-dir PATH] [-- QEMU arguments...]

    Runs the same guest disk as mbp-apple-silicon-vm under QEMU with HVF
    acceleration. Unlike Virtualization.framework, QEMU's virtio-gpu can carry
    more than one scanout, so the guest sees --outputs separate displays and a
    SPICE client shows each of them in its own window.

    --outputs defaults to auto: the guest is given one display per monitor
    attached to this Mac when the VM starts, and the displays are sized after
    the Mac's primary monitor. Mirrored monitors are counted once. Reconnect a
    monitor later and the guest keeps the outputs it booted with, so restart
    the VM to pick up the new one.

    A newly created disk boots the pinned NixOS ARM installer, partitions
    /dev/vda with Disko and mounts it under /mnt; install with nixos-install
    exactly as with the vfkit launcher. Later runs boot the installed system
    through EDK2.

    Displays:
      spice   headless QEMU serving SPICE on a unix socket in the state
              directory; spicy is launched against it unless --no-client
      cocoa   QEMU's own window; a single display regardless of --outputs
      none    no local display at all

    A single output gets an absolute pointer, so the host cursor moves in and
    out of the SPICE window freely. Two or more outputs force SPICE into
    relative mouse mode instead: clicking into a window captures the host
    cursor, and spice-gtk keeps warping it to the middle of the primary monitor
    for as long as it is held. Cmd+H releases it; the Ctrl+Alt ungrab only
    reaches the window that took the grab, which is not always the one the warp
    leaves you over. Do not reach for SPICE_NOGRAB to escape: with the grab off
    a server mode click is swallowed rather than forwarded, so the guest stops
    seeing the mouse entirely.

    --mount boots the installer and mounts the existing filesystems under /mnt
    with disko's own options, which is how to reinstall without reformatting.
    Mounting the ESP by hand instead leaves it world readable and systemd-boot
    writes its random seed into a world accessible file.

    Environment:
      MBP_APPLE_VM_OUTPUTS          virtio-gpu scanouts, or auto (default: auto)
      MBP_APPLE_VM_DISPLAY          spice, cocoa or none (default: spice)
      MBP_APPLE_VM_SPICE_CLIENT     0 leaves the client to you (default: 1)
      MBP_APPLE_VM_CPUS             Virtual CPU count (default: every host core)
      MBP_APPLE_VM_MEMORY_MIB       Guest memory in MiB (default: 80% of host RAM)
      MBP_APPLE_VM_DISK_SIZE        Sparse persistent disk size (default: 512G)
      MBP_APPLE_VM_DISPLAY_WIDTH    Width of each display (default: host primary)
      MBP_APPLE_VM_DISPLAY_HEIGHT   Height of each display (default: host primary)
      MBP_APPLE_VM_SSH_PORT         Host SSH forwarding port (default: 2223)
      MBP_APPLE_VM_SHARED_DIR       Optional host directory shared as "host"
      MBP_APPLE_VM_STATE_DIR        Persistent VM state directory
      MBP_APPLE_VM_BOOT_TIMEOUT     Installer shell timeout in seconds (default: 300)
      MBP_APPLE_VM_PROVISION_TIMEOUT
                                    Disko provisioning timeout in seconds
                                    (default: 1800)
    EOF
    }

    installer=0
    provision=0
    mount_only=0
    reset=0
    client="''${MBP_APPLE_VM_SPICE_CLIENT:-1}"
    outputs="''${MBP_APPLE_VM_OUTPUTS:-auto}"
    display="''${MBP_APPLE_VM_DISPLAY:-spice}"
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
        --outputs)
          if (( $# < 2 )); then
            echo "--outputs requires a count" >&2
            exit 2
          fi
          outputs=$2
          shift 2
          ;;
        --display)
          if (( $# < 2 )); then
            echo "--display requires spice, cocoa or none" >&2
            exit 2
          fi
          display=$2
          shift 2
          ;;
        --no-client)
          client=0
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

    # Every monitor macOS currently drives, as "WIDTHxHEIGHT main|other", one
    # per line. Mirrored monitors show the same picture, so they are one entry.
    host_displays() {
      /usr/sbin/system_profiler SPDisplaysDataType -json 2>/dev/null | jq -r '
        .SPDisplaysDataType[]?.spdisplays_ndrvs[]?
        | select((.spdisplays_online // "spdisplays_yes") == "spdisplays_yes")
        | select((.spdisplays_mirror // "spdisplays_off") != "spdisplays_on")
        | ((._spdisplays_pixels // "0 x 0") | gsub(" "; ""))
          + " "
          + (if .spdisplays_main == "spdisplays_yes" then "main" else "other" end)
      '
    }

    detected=()
    if [[ "$outputs" == auto || -z "''${MBP_APPLE_VM_DISPLAY_WIDTH:-}''${MBP_APPLE_VM_DISPLAY_HEIGHT:-}" ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && detected+=("$line")
      done < <(host_displays || true)
    fi

    if [[ "$outputs" == auto ]]; then
      outputs=''${#detected[@]}
      if (( outputs < 1 )); then
        outputs=1
        echo "could not read this Mac's displays; giving the guest one output" >&2
      elif (( outputs > 16 )); then
        # virtio-gpu tops out at 16 scanouts.
        echo "clamping ''${#detected[@]} host displays to virtio-gpu's limit of 16" >&2
        outputs=16
      else
        echo "giving the guest $outputs output(s), one per monitor on this Mac"
      fi
    fi

    if [[ ! "$outputs" =~ ^[0-9]+$ ]] || (( outputs < 1 )); then
      echo "--outputs must be a positive number or auto" >&2
      exit 2
    fi

    # Size the guest displays after the Mac's primary monitor unless told
    # otherwise; the SPICE client resizes each head once its window is placed.
    primary=""
    for entry in ''${detected[@]+"''${detected[@]}"}; do
      if [[ "$entry" == *" main" ]]; then
        primary=''${entry%% *}
        break
      fi
    done
    if [[ -z "$primary" && ''${#detected[@]} -gt 0 ]]; then
      primary=''${detected[0]%% *}
    fi

    case "$display" in
      spice|cocoa|none) ;;
      *)
        echo "--display must be spice, cocoa or none" >&2
        exit 2
        ;;
    esac

    mkdir -p "$state_dir"
    disk="$state_dir/root.img"
    firmware_vars="$state_dir/edk2-vars.fd"
    needs_provision="$state_dir/needs-provision"
    spice_socket="$state_dir/spice.sock"

    if (( reset )); then
      rm -f "$disk" "$firmware_vars" "$needs_provision"
    fi

    if [[ ! -e "$disk" ]]; then
      truncate -s "''${MBP_APPLE_VM_DISK_SIZE:-512G}" "$disk"
      touch "$needs_provision"
      installer=1
    fi

    if [[ -e "$needs_provision" ]]; then
      installer=1
      provision=1
    fi

    if [[ ! -e "$firmware_vars" ]]; then
      # EDK2 wants a writable variable store the same size as its code image.
      install -m 0600 ${qemu}/share/qemu/edk2-arm-vars.fd "$firmware_vars"
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
    display_width="''${MBP_APPLE_VM_DISPLAY_WIDTH:-''${primary%x*}}"
    display_height="''${MBP_APPLE_VM_DISPLAY_HEIGHT:-''${primary#*x}}"
    display_width="''${display_width:-1920}"
    display_height="''${display_height:-1200}"
    ssh_port="''${MBP_APPLE_VM_SSH_PORT:-2223}"
    # Every serial wait is bounded, so a guest that never reaches its shell
    # fails instead of blocking the launcher forever.
    boot_timeout="''${MBP_APPLE_VM_BOOT_TIMEOUT:-300}"
    provision_timeout="''${MBP_APPLE_VM_PROVISION_TIMEOUT:-1800}"
    if [[ ! "$boot_timeout" =~ ^[1-9][0-9]*$ ]]; then
      echo "MBP_APPLE_VM_BOOT_TIMEOUT must be a positive integer" >&2
      exit 1
    fi
    if [[ ! "$provision_timeout" =~ ^[1-9][0-9]*$ ]]; then
      echo "MBP_APPLE_VM_PROVISION_TIMEOUT must be a positive integer" >&2
      exit 1
    fi
    serial_log="$state_dir/installer-serial.log"

    client_pid=""
    cleanup() {
      if [[ -n "$client_pid" ]]; then
        kill "$client_pid" 2>/dev/null || true
        wait "$client_pid" 2>/dev/null || true
      fi
      rm -f "$spice_socket"
    }
    trap cleanup EXIT INT TERM

    qemu_args=(
      -machine "virt,accel=hvf"
      -cpu host
      -smp "$cpus"
      -m "$memory"
      -device virtio-rng-pci
      -device "virtio-gpu-pci,max_outputs=$outputs,xres=$display_width,yres=$display_height"
      -device virtio-keyboard-pci
      -device virtio-tablet-pci
      -device virtio-serial-pci
      # A USB controller is here unconditionally rather than only under
      # --installer: redirected devices need somewhere to attach, and the
      # installer's ISO drive hangs off this same xhci.
      -device "qemu-xhci,id=xhci"
      -chardev "stdio,id=console,signal=off"
      -device "virtconsole,chardev=console"
      -drive "if=none,id=root,format=raw,file=$disk"
      -device "virtio-blk-pci,drive=root,bootindex=0"
      -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$ssh_port-:22"
      -device "virtio-net-pci,netdev=net0"
      -serial none
      -monitor none
    )

    if (( outputs > 1 )); then
      # spice-server only grants the client absolute ("client") mouse mode when
      # a single display channel is up, or when a spice-vdagent in the guest is
      # attached to place each position on its own head; see
      # reds_update_mouse_mode in server/reds.cpp. Neither holds once there is
      # more than one scanout, so SPICE drops to relative ("server") mode and
      # the tablet above stops receiving events. Without a relative device the
      # guest pointer would then sit still while spice-gtk goes on grabbing the
      # host cursor and warping it to the centre of the primary monitor.
      qemu_args+=( -device virtio-mouse-pci )
    fi

    if (( installer )); then
      # The ISO's GRUB never reaches a serial line, so boot its kernel directly
      # and attach the image itself for the initrd to find by label.
      qemu_args+=(
        -kernel "${installerBoot}/Image"
        -initrd "${installerBoot}/initrd"
        -append "$(cat ${installerBoot}/cmdline)"
        # The ISO is an immutable store path, so QEMU cannot take its usual
        # image lock on it.
        -drive "if=none,id=iso,format=raw,readonly=on,file=${bootstrapIso},file.locking=off"
        -device "usb-storage,drive=iso,bus=xhci.0"
      )
    else
      qemu_args+=(
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=${qemu}/share/qemu/edk2-aarch64-code.fd"
        -drive "if=pflash,format=raw,unit=1,file=$firmware_vars"
      )
    fi

    if [[ -n "''${MBP_APPLE_VM_SHARED_DIR:-}" ]]; then
      qemu_args+=(
        -virtfs "local,path=$MBP_APPLE_VM_SHARED_DIR,mount_tag=host,security_model=none"
      )
    fi

    case "$display" in
      spice)
        rm -f "$spice_socket"
        qemu_args+=(
          -display none
          -spice "unix=on,addr=$spice_socket,disable-ticketing=on"
          -chardev "spicevmc,id=vdagent,name=vdagent"
          -device "virtserialport,chardev=vdagent,name=com.redhat.spice.0"
        )
        # Redirection channels for the client's USB support. A spicevmc chardev
        # only exists while SPICE is serving, so these belong here rather than
        # beside the controller above. Each channel carries one redirected
        # device at a time; three is the usual allowance.
        for slot in 0 1 2; do
          qemu_args+=(
            -chardev "spicevmc,id=usbredir$slot,name=usbredir"
            -device "usb-redir,chardev=usbredir$slot,id=usbredirdev$slot,bus=xhci.0"
          )
        done
        ;;
      cocoa)
        qemu_args+=( -display cocoa )
        ;;
      none)
        qemu_args+=( -display none )
        ;;
    esac

    if [[ "$display" == spice ]]; then
      echo "SPICE socket: $spice_socket"
      echo "Connect with: spicy --uri=spice+unix://$spice_socket"
      if (( client )); then
        (
          for _ in {1..200}; do
            [[ -S "$spice_socket" ]] && break
            sleep 0.1
          done
          if [[ ! -S "$spice_socket" ]]; then
            echo "SPICE socket never appeared; start spicy yourself" >&2
            exit 0
          fi
          # GTK's macOS event loop aborts in select_thread_collect_poll on
          # g_assert (ufds[i].fd == current_pollfds[i].fd) whenever the
          # descriptor set changes between starting a poll and collecting it,
          # which the agent and clipboard channels do routinely once a guest
          # agent is attached. QEMU is untouched when the client dies, so
          # reconnect rather than leave a running guest with no display. A
          # clean quit, or any ordinary non-zero exit, still ends the loop;
          # only death by a signal reconnects. gtk3-quartz-poll-race.patch is
          # what actually fixes that abort; this is only here so an unrelated
          # crash does not leave a running guest with no way to see it.
          while [[ -S "$spice_socket" ]]; do
            status=0
            spicy --uri="spice+unix://$spice_socket" || status=$?
            (( status >= 128 )) || break
            echo "SPICE client died on signal $(( status - 128 )); reconnecting" >&2
            sleep 1
          done
        ) &
        client_pid=$!
      fi
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
        "$serial_log" "$boot_timeout" "$provision_timeout" \
        qemu-system-aarch64 "''${qemu_args[@]}" "$@"; then
        status=0
      else
        status=$?
      fi
    elif qemu-system-aarch64 "''${qemu_args[@]}" "$@"; then
      status=0
    else
      status=$?
    fi
    cleanup
    trap - EXIT INT TERM
    exit "$status"
  '';

  meta = {
    description = "Run the Apple Silicon NixOS guest under QEMU with multi-head SPICE output";
    mainProgram = "mbp-apple-silicon-qemu-vm";
    platforms = [ "aarch64-darwin" ];
  };
}
