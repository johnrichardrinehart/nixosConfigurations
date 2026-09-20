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
  socat,
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
    socat
    spicyClient
  ];

  text = ''
    usage() {
      cat <<'EOF'
    Usage: mbp-apple-silicon-qemu-vm [--installer] [--reset] [--mount] [--outputs N|auto]
                                     [--display spice|cocoa|none] [--no-client]
                                     [--state-dir PATH] [--guest-flake REF]
                                     [-- QEMU arguments...]
           mbp-apple-silicon-qemu-vm --attach [--state-dir PATH]
           mbp-apple-silicon-qemu-vm --stop [--state-dir PATH]

    Runs the mbp-apple-silicon guest under QEMU with HVF acceleration. QEMU's
    virtio-gpu can carry more than one scanout, so the guest sees --outputs
    separate displays and a SPICE client shows each of them in its own window.

    --outputs defaults to auto: the guest is given one display per monitor
    attached to this Mac when the VM starts, and the displays are sized after
    the Mac's primary monitor. Mirrored monitors are counted once. Reconnect a
    monitor later and the guest keeps the outputs it booted with, so restart
    the VM to pick up the new one.

    A newly created disk boots the pinned NixOS ARM installer, partitions
    /dev/vda with Disko and mounts it under /mnt; install with nixos-install.
    Later runs boot the installed system through EDK2.

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

    The disko scripts those three options run are fetched, inside the guest,
    from the flake reference printed as "provisioning from ...". It is this
    flake's own revision when there is one to name; a working tree with
    uncommitted changes has none, so it falls back to the main branch, which
    need not carry this host at all - the guest then fails with "does not
    provide attribute". --guest-flake names a different one: a branch, a
    revision, or anything else nix will fetch from inside the guest. A path on
    this Mac only works if the guest can reach it, which for now means a share.

    One VM per state directory, held with a lock on it, so a second invocation
    is refused rather than deleting the running VM's SPICE socket on its way to
    failing. The guest is tied to its launcher and goes down with it.

    --attach puts a SPICE client on a VM that is already running, and --stop
    presses its virtual power button over QMP. Between them a guest that has
    lost its display stays reachable, which matters because QEMU cannot be told
    to open a new SPICE socket once it is running: a client is the only way
    back to the screen, and QMP the only clean way out.

    spice-server serves one client at a time, so --attach takes the display
    over rather than adding a second view of it, and whatever was connected is
    dropped the moment the new client arrives. The launcher stands aside for as
    long as an --attach client is up, and resumes its own when that one leaves.

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
      MBP_APPLE_VM_GUEST_FLAKE      Flake the guest fetches disko scripts from
      MBP_APPLE_VM_STATE_DIR        Persistent VM state directory
      MBP_APPLE_VM_BOOT_TIMEOUT     Installer shell timeout in seconds (default: 300)
      MBP_APPLE_VM_PROVISION_TIMEOUT
                                    Disko provisioning timeout in seconds
                                    (default: 1800)
      MBP_APPLE_VM_STOP_TIMEOUT     Seconds --stop waits for the guest to power
                                    itself down before resorting to SIGTERM
                                    (default: 120)
    EOF
    }

    installer=0
    provision=0
    mount_only=0
    reset=0
    stop=0
    attach=0
    client="''${MBP_APPLE_VM_SPICE_CLIENT:-1}"
    outputs="''${MBP_APPLE_VM_OUTPUTS:-auto}"
    display="''${MBP_APPLE_VM_DISPLAY:-spice}"
    state_dir="''${MBP_APPLE_VM_STATE_DIR:-''${XDG_DATA_HOME:-$HOME/Library/Application Support}/mbp-apple-silicon-vm}"
    # Where --installer, --reset and --mount fetch the guest's disko scripts
    # from. The compiled-in default is this flake's own revision, but a working
    # tree with uncommitted changes has no revision to name, so it falls back
    # to a branch that may not carry this host at all. Overridable for exactly
    # that case.
    guest_flake="''${MBP_APPLE_VM_GUEST_FLAKE:-${lib.escapeShellArg guestFlake}}"
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
        --guest-flake)
          if (( $# < 2 )); then
            echo "--guest-flake requires a flake reference" >&2
            exit 2
          fi
          guest_flake=$2
          shift 2
          ;;
        --state-dir)
          if (( $# < 2 )); then
            echo "--state-dir requires a path" >&2
            exit 2
          fi
          state_dir=$2
          shift 2
          ;;
        --stop)
          stop=1
          shift
          ;;
        --attach)
          attach=1
          shift
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

    # Three paths an invocation may need before it knows whether it is starting
    # a VM at all, because --attach and --stop act on one that already exists.
    spice_socket="$state_dir/spice.sock"
    qmp_socket="$state_dir/qmp.sock"
    qemu_pidfile="$state_dir/qemu.pid"
    attach_pidfile="$state_dir/attach.pid"

    # Both sockets are addressed by their path, and sockaddr_un on Darwin holds
    # only 104 bytes of one, terminator included. Left alone, QEMU fails to bind
    # long after it has taken over the terminal, and --attach reports a missing
    # socket without saying why it could never have been there. Check up front,
    # where the message can name the real cause.
    for socket_path in "$spice_socket" "$qmp_socket"; do
      if (( ''${#socket_path} > 103 )); then
        echo "$socket_path is ''${#socket_path} characters long; a unix socket path" >&2
        echo "on macOS cannot exceed 103. Pick a shorter --state-dir." >&2
        exit 1
      fi
    done

    # QEMU writes the pidfile itself and unlinks it on the way out, so a pid in
    # there that is still alive is the one honest answer to "is a VM running
    # against this state directory". Nothing else in here is trustworthy: the
    # sockets outlive crashes and the lock only says a launcher holds the
    # directory.
    vm_pid() {
      local pid
      pid=$(cat "$qemu_pidfile" 2>/dev/null || true)
      [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
      kill -0 "$pid" 2>/dev/null || return 1
      printf '%s\n' "$pid"
    }

    # Who, if anyone, currently holds the display. spice-server serves one
    # client at a time, so this is what keeps --attach and the launcher's own
    # reconnect loop from evicting each other turn about.
    attach_pid() {
      local pid
      pid=$(cat "$attach_pidfile" 2>/dev/null || true)
      [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
      kill -0 "$pid" 2>/dev/null || return 1
      printf '%s\n' "$pid"
    }

    if (( attach && stop )); then
      echo "--attach and --stop are alternatives" >&2
      exit 2
    fi

    if (( attach )); then
      if ! vm_pid >/dev/null; then
        echo "no VM is running against $state_dir" >&2
        exit 1
      fi
      if [[ ! -S "$spice_socket" ]]; then
        echo "the VM is running but $spice_socket is gone, and QEMU has no way" >&2
        echo "to open another one; shut it down with --stop" >&2
        exit 1
      fi
      if holder=$(attach_pid); then
        echo "another --attach client (pid $holder) already holds the display" >&2
        exit 1
      fi
      # Claim the display before connecting, not after: spice-server drops
      # whoever is attached the instant this client arrives, and the launcher's
      # reconnect loop would otherwise simply take it straight back.
      echo "$$" >"$attach_pidfile"
      attach_client=""
      attach_cleanup() {
        if [[ -n "$attach_client" ]] && kill -0 "$attach_client" 2>/dev/null; then
          kill "$attach_client" 2>/dev/null || true
          wait "$attach_client" 2>/dev/null || true
        fi
        rm -f "$attach_pidfile"
      }
      trap attach_cleanup EXIT INT TERM HUP
      # spicy goes in the background so that trap is not deferred behind it:
      # bash runs no trap while a foreground child is still going, which would
      # otherwise leave a killed --attach holding the display and the pidfile
      # until its client happened to exit on its own.
      attach_status=0
      spicy --uri="spice+unix://$spice_socket" &
      attach_client=$!
      wait "$attach_client" || attach_status=$?
      attach_client=""
      attach_cleanup
      trap - EXIT INT TERM HUP
      exit "$attach_status"
    fi

    if (( stop )); then
      if ! stop_pid=$(vm_pid); then
        echo "no VM is running against $state_dir"
        exit 0
      fi
      stop_timeout="''${MBP_APPLE_VM_STOP_TIMEOUT:-120}"
      if [[ ! "$stop_timeout" =~ ^[0-9]+$ ]]; then
        echo "MBP_APPLE_VM_STOP_TIMEOUT must be a non-negative integer" >&2
        exit 1
      fi
      if [[ -S "$qmp_socket" ]]; then
        # An ACPI power button press, so the guest unmounts its filesystems on
        # the way down. SIGTERM only ends QEMU, which the guest experiences as
        # the plug coming out.
        echo "asking the guest (pid $stop_pid) to power down"
        printf '%s\n' '{"execute":"qmp_capabilities"}' '{"execute":"system_powerdown"}' \
          | socat -T5 - "UNIX-CONNECT:$qmp_socket" >/dev/null 2>&1 || true
      else
        # A VM from before QMP existed here, or one whose socket was lost.
        echo "no QMP socket at $qmp_socket; sending SIGTERM to pid $stop_pid" >&2
        kill "$stop_pid" 2>/dev/null || true
      fi
      waited=0
      while (( waited < stop_timeout )) && kill -0 "$stop_pid" 2>/dev/null; do
        sleep 1
        waited=$(( waited + 1 ))
      done
      if kill -0 "$stop_pid" 2>/dev/null; then
        echo "guest did not stop within ''${stop_timeout}s; sending SIGTERM" >&2
        kill "$stop_pid" 2>/dev/null || true
        waited=0
        while (( waited < 10 )) && kill -0 "$stop_pid" 2>/dev/null; do
          sleep 1
          waited=$(( waited + 1 ))
        done
      fi
      if kill -0 "$stop_pid" 2>/dev/null; then
        echo "QEMU ignored SIGTERM; sending SIGKILL" >&2
        kill -9 "$stop_pid" 2>/dev/null || true
      fi
      echo "stopped"
      exit 0
    fi

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

    # Everything below belongs to one VM: the disk, the EDK2 variables and both
    # sockets live in $state_dir. A second launcher pointed at the same
    # directory unlinks the running VM's SPICE socket on its way to failing,
    # and QEMU will not open another one for the life of the guest, so the
    # display is gone for good; --reset would go further and delete the disk
    # out from under it. Claim the directory first, then touch what is inside.
    lock_dir="$state_dir/lock.d"
    if ! mkdir "$lock_dir" 2>/dev/null; then
      holder=$(cat "$lock_dir/pid" 2>/dev/null || true)
      if [[ "$holder" =~ ^[1-9][0-9]*$ ]] && kill -0 "$holder" 2>/dev/null; then
        echo "mbp-apple-silicon-qemu-vm (pid $holder) is already running against $state_dir" >&2
        echo "attach to it with --attach, shut it down with --stop, or set" >&2
        echo "MBP_APPLE_VM_STATE_DIR to run a second VM elsewhere" >&2
        exit 1
      fi
      # Nobody holds it, so it is a leftover from a launcher that was killed.
      rm -rf "$lock_dir"
      mkdir "$lock_dir"
    fi
    echo "$$" >"$lock_dir/pid"

    # Anything still in here belongs to a launcher that is gone, and QEMU will
    # not bind a unix socket onto a path that already exists.
    rm -f "$qmp_socket" "$qemu_pidfile"

    client_pid=""
    qemu_pid=""
    launched=0
    cleaned=0
    cleanup() {
      if (( cleaned )); then
        return 0
      fi
      cleaned=1
      # QEMU goes first, and the client after. The client subshell spends its
      # life waiting on spicy in the foreground, so a signal to it would sit
      # undelivered until spicy exited; ending QEMU closes the SPICE socket,
      # which brings spicy down on its own and lets that wait finish promptly.
      #
      # The guest does not outlive its launcher either way. An orphaned QEMU is
      # precisely the state this whole file is trying to avoid: a VM still
      # running, with no display, owned by nobody.
      if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
      elif (( launched )); then
        # The provisioning path runs QEMU under expect, so the pidfile is the
        # only handle on it. We hold the lock, so whatever is in there is ours.
        stray=$(vm_pid) || stray=""
        if [[ -n "$stray" ]]; then
          kill "$stray" 2>/dev/null || true
        fi
      fi
      if [[ -n "$client_pid" ]]; then
        kill "$client_pid" 2>/dev/null || true
        wait "$client_pid" 2>/dev/null || true
      fi
      rm -f "$spice_socket" "$qmp_socket"
      rm -rf "$lock_dir"
    }
    trap cleanup EXIT INT TERM HUP

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
    # The lock above only covers this state directory; a VM started from
    # another one still competes for the host port, and QEMU reports that as an
    # unbuildable forwarding rule well after it has taken over the terminal.
    if (exec 3<>"/dev/tcp/127.0.0.1/$ssh_port") 2>/dev/null; then
      echo "host port $ssh_port is already in use, so SSH cannot be forwarded" >&2
      echo "free it, or set MBP_APPLE_VM_SSH_PORT to another port" >&2
      exit 1
    fi
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
      # The control channel that survives losing the display: --stop powers the
      # guest down through QMP, and the pidfile is how anything finds this VM
      # without having been told its pid.
      -pidfile "$qemu_pidfile"
      -qmp "unix:$qmp_socket,server=on,wait=off"
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
          # Both the socket and the pidfile appear during QEMU's startup, and
          # the loop below needs each of them, so wait for the pair.
          for _ in {1..600}; do
            if [[ -S "$spice_socket" ]] && vm_pid >/dev/null; then
              break
            fi
            sleep 0.1
          done
          if [[ ! -S "$spice_socket" ]] || ! vm_pid >/dev/null; then
            echo "SPICE socket never appeared; start spicy yourself" >&2
            exit 0
          fi
          # A client going away is not a request to stop watching the VM, and
          # the exit status does not say which kind of going away it was. GTK's
          # macOS event loop aborts in select_thread_collect_poll on
          # g_assert (ufds[i].fd == current_pollfds[i].fd) whenever the
          # descriptor set changes between starting a poll and collecting it,
          # which the agent and clipboard channels do routinely once a guest
          # agent is attached; that arrives as a signal. But unplugging a
          # monitor takes its window with it and ends spicy with an ordinary
          # status, indistinguishable from a deliberate quit, and treating that
          # as "stop reconnecting" is how a running guest ends up on screen
          # nowhere. So reconnect for as long as QEMU is alive, and read two
          # closes in quick succession as someone who really means it.
          # gtk3-quartz-poll-race.patch is what fixes the abort itself.
          closes=0
          while vm_pid >/dev/null; do
            if [[ ! -S "$spice_socket" ]]; then
              echo "$spice_socket has vanished while the VM is still running." >&2
              echo "Nothing can attach to it now; shut the VM down with --stop." >&2
              break
            fi
            # spice-server serves one client at a time, so stand aside while an
            # --attach client owns the display instead of evicting it.
            if attach_pid >/dev/null; then
              sleep 1
              continue
            fi
            started=$SECONDS
            status=0
            spicy --uri="spice+unix://$spice_socket" || status=$?
            vm_pid >/dev/null || break
            if attach_pid >/dev/null; then
              # An --attach arrived and took the display. That is a handover,
              # not someone closing the window, so it must not count as a close.
              continue
            fi
            if (( status >= 128 )); then
              echo "SPICE client died on signal $(( status - 128 )); reconnecting" >&2
              closes=0
            else
              if (( SECONDS - started < 10 )); then
                closes=$(( closes + 1 ))
              else
                closes=1
              fi
              if (( closes >= 2 )); then
                echo "SPICE client closed again; leaving the VM running with no display."
                echo "Reattach with: mbp-apple-silicon-qemu-vm --attach"
                break
              fi
              echo "SPICE client exited with status $status; reconnecting." >&2
              echo "Close it again straight away to stop reconnecting." >&2
            fi
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
      # Named before it is used, because the failure when it is wrong arrives
      # as an opaque "does not provide attribute" from inside the guest.
      echo "provisioning from $guest_flake"
      # These two run in the guest shell, so nothing may expand here.
      # shellcheck disable=SC2016
      network_command='network_ready=0; for _ in $(seq 1 60); do if getent hosts github.com >/dev/null 2>&1; then network_ready=1; break; fi; sleep 1; done'
      provision_command=$(cat <<EOF
    if (( network_ready )); then disko_output=\$(nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths '$guest_flake#nixosConfigurations."mbp-apple-silicon-bootstrap".config.system.build.$disko_attr') && sudo "\$disko_output"; status=\$?; else echo 'network did not become ready within 60 seconds' >&2; status=69; fi; printf '\n__DISKO_PROVISION_STATUS_%s__\n' "\$status"
    EOF
      )

      launched=1
      if expect ${serialProvisioner} "$network_command" "$provision_command" "$marker" \
        "$serial_log" "$boot_timeout" "$provision_timeout" \
        qemu-system-aarch64 "''${qemu_args[@]}" "$@"; then
        status=0
      else
        status=$?
      fi
    else
      # QEMU in the background, with stdin explicitly passed through: bash runs
      # traps while it sits in wait, so a Ctrl-C or a closing terminal tears the
      # guest down instead of orphaning it, and cleanup has a pid to aim at. A
      # background command with no redirection of its own would be handed
      # /dev/null and lose the virtconsole.
      exec 9<&0
      launched=1
      qemu-system-aarch64 "''${qemu_args[@]}" "$@" <&9 &
      qemu_pid=$!
      status=0
      wait "$qemu_pid" || status=$?
      qemu_pid=""
    fi
    cleanup
    trap - EXIT INT TERM HUP
    exit "$status"
  '';

  meta = {
    description = "Run the Apple Silicon NixOS guest under QEMU with multi-head SPICE output";
    mainProgram = "mbp-apple-silicon-qemu-vm";
    platforms = [ "aarch64-darwin" ];
  };
}
