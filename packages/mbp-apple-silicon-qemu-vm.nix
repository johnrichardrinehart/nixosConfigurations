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
  perl,
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
    perl
    socat
    spicyClient
  ];

  text = ''
    usage() {
      cat <<'EOF'
    Usage: mbp-apple-silicon-qemu-vm [--outputs N|auto]
                                     [--display spice|cocoa|none] [--no-client]
                                     [--state-dir PATH] [--guest-flake REF]
                                     [-- QEMU arguments...]
           mbp-apple-silicon-qemu-vm --bootstrap [--reset | --mount] [options as above]
           mbp-apple-silicon-qemu-vm --attach [--state-dir PATH]
           mbp-apple-silicon-qemu-vm --stop [--state-dir PATH]

    Runs the mbp-apple-silicon guest under QEMU with HVF acceleration. QEMU's
    virtio-gpu can carry more than one scanout, so the guest sees --outputs
    separate displays and a SPICE client shows each of them in its own window.

    --outputs defaults to 1, which keeps the absolute pointer described below.
    auto gives the guest one display per monitor attached to this Mac when the
    VM starts. Either way the displays are sized after the Mac's primary
    monitor. Mirrored monitors are counted once. Reconnect a monitor later and
    the guest keeps the outputs it booted with, so restart the VM to pick up
    the new one.

    A regular run boots the installed system through EDK2 and gives the
    terminal nothing of the guest: no console, just the launcher's own output.
    Reach the guest through SPICE or over SSH (127.0.0.1:MBP_APPLE_VM_SSH_PORT).
    Ctrl-C, closing the terminal, or --stop from another one all shut it down
    the same way: unmount the shares, press the virtual power button, and wait
    up to MBP_APPLE_VM_STOP_TIMEOUT for the guest to power itself off before
    SIGTERM and then SIGKILL. A second Ctrl-C skips the wait. QEMU runs in a
    session of its own, so the terminal's signals only ever reach the launcher.

    --bootstrap boots the pinned NixOS ARM installer instead, with its console
    on this terminal (Ctrl-C there goes to the installer). On a disk that is
    new or whose provisioning never finished, it partitions /dev/vda with
    Disko and mounts it under /mnt, then hands over the installer shell;
    install with nixos-install. A regular run refuses such a disk and asks for
    --bootstrap. --reset (with --bootstrap) deletes the disk and EDK2
    variables first and provisions from scratch.

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

    --mount (with --bootstrap) boots the installer and mounts the existing
    filesystems under /mnt with disko's own options, which is how to reinstall
    without reformatting.
    Mounting the ESP by hand instead leaves it world readable and systemd-boot
    writes its random seed into a world accessible file.

    The disko scripts --bootstrap runs are fetched, inside the guest,
    from the flake reference printed as "provisioning from ...". It is this
    flake's own revision when there is one to name; a working tree with
    uncommitted changes has none, so it falls back to the main branch, which
    need not carry this host at all - the guest then fails with "does not
    provide attribute". --guest-flake names a different one: a branch, a
    revision, or anything else nix will fetch from inside the guest. A path on
    this Mac is out of its reach: shares run the other way.

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

    Directories on the guest's own disk are mounted on this Mac over NFS, one
    mount per entry in ~/guest-vm-fs-mappings.json. The data lives in the
    guest, which does nearly all the work on it, and this Mac - which only
    looks now and then - is the side that pays for the network. The file is
    read at every start, so the set of shares changes without rebuilding
    anything. Either a bare array or an object with a "shares" key, whose
    entries are:

      host   Where this Mac mounts the directory. Required. Absolute, no ~.
      guest  The guest directory to export. Required. Absolute, no whitespace.
      mode   "rw" (default) or "ro".
      transport
             "nfs" (default), the only one there is.

    Other keys - cache, msize and tag, and a remap of false - are left over
    from the 9p share this replaced and are ignored; "remap": true is refused.

    The guest's nfsd and mountd are forwarded to MBP_APPLE_VM_NFS_PORT and
    MBP_APPLE_VM_MOUNTD_PORT on this Mac's loopback, and once the guest
    exports a share the launcher mounts it with mount_nfs - as you, not root:
    macOS lets a user mount onto a directory they own. The guest squashes
    every request to its own account, so what this Mac writes lands owned by
    that account; it also means any account on this Mac that can reach its
    loopback can reach the share.

    A host directory has to be empty or missing (it is then created).
    Mounting over one with something in it would hide it, and anything aimed
    at the hidden copy would travel through the mount into the guest instead.
    A .DS_Store is the one thing allowed to be there.

    The mounts are soft and interruptible with deadtimeout=60: when the guest
    stops answering, calls fail rather than hang, and macOS drops the mount
    after a minute. The launcher unmounts them before the guest goes down - on
    exit, and first thing under --stop - so what this Mac has buffered reaches
    the guest while it can still take it. Byte-range locks stay on this Mac
    (locallocks) and never meet the guest's; exclusive create is decided by
    the guest, so lock files do exclude across the boundary.

    This Mac trusts what it has cached about a file or directory for at most
    five seconds (actimeo=5), so a change made in the guest shows up here
    within that. FSEvents does not see the guest's writes, so nothing on this
    Mac should watch the mount: a watchman-backed git fsmonitor would report
    stale status. Let git scan it.

    Environment:
      MBP_APPLE_VM_OUTPUTS          virtio-gpu scanouts, or auto (default: 1)
      MBP_APPLE_VM_DISPLAY          spice, cocoa or none (default: spice)
      MBP_APPLE_VM_SPICE_CLIENT     0 leaves the client to you (default: 1)
      MBP_APPLE_VM_CPUS             Virtual CPU count (default: every host core)
      MBP_APPLE_VM_MEMORY_MIB       Guest memory in MiB (default: 80% of host RAM)
      MBP_APPLE_VM_DISK_SIZE        Sparse persistent disk size (default: 512G)
      MBP_APPLE_VM_DISPLAY_WIDTH    Width of each display (default: host primary)
      MBP_APPLE_VM_DISPLAY_HEIGHT   Height of each display (default: host primary)
      MBP_APPLE_VM_SSH_PORT         Host SSH forwarding port (default: 2223)
      MBP_APPLE_VM_NFS_PORT         Loopback port forwarded to the guest's nfsd
                                    (default: 2225)
      MBP_APPLE_VM_MOUNTD_PORT      Loopback port forwarded to the guest's mountd
                                    (default: 2226)
      MBP_APPLE_VM_NFS_TIMEOUT      Seconds to wait for the guest to export its
                                    shares before giving up on mounting them
                                    (default: 300)
      MBP_APPLE_VM_GUEST_FLAKE      Flake the guest fetches disko scripts from
      MBP_APPLE_VM_MAPPINGS         Shared directory table
                                    (default: ~/guest-vm-fs-mappings.json)
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

    bootstrap=0
    provision=0
    mount_only=0
    reset=0
    stop=0
    attach=0
    client="''${MBP_APPLE_VM_SPICE_CLIENT:-1}"
    outputs="''${MBP_APPLE_VM_OUTPUTS:-1}"
    display="''${MBP_APPLE_VM_DISPLAY:-spice}"
    state_dir="''${MBP_APPLE_VM_STATE_DIR:-''${XDG_DATA_HOME:-$HOME/Library/Application Support}/mbp-apple-silicon-vm}"
    # Where --bootstrap fetches the guest's disko scripts
    # from. The compiled-in default is this flake's own revision, but a working
    # tree with uncommitted changes has no revision to name, so it falls back
    # to a branch that may not carry this host at all. Overridable for exactly
    # that case.
    guest_flake="''${MBP_APPLE_VM_GUEST_FLAKE:-${lib.escapeShellArg guestFlake}}"
    while (( $# > 0 )); do
      case "$1" in
        --bootstrap)
          bootstrap=1
          shift
          ;;
        --reset)
          reset=1
          shift
          ;;
        --mount)
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
    # Every host directory this launcher has mounted from the guest, one per
    # line, so that --stop, from another invocation, can unmount them before
    # the guest goes down.
    mounts_file="$state_dir/nfs-mounts"

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

    # Plain first, so whatever this Mac has buffered reaches the guest while it
    # can still take it; forced when something holds the mount open. With the
    # guest already gone a plain unmount would only sit out the soft mount's
    # retransmissions, so "force" goes straight to it.
    unmount_shares() {
      local how=''${1:-} dir
      [[ -s "$mounts_file" ]] || return 0
      while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        if [[ "$how" != force ]] && /sbin/umount "$dir" 2>/dev/null; then
          echo "unmounted $dir"
        elif /sbin/umount -f "$dir"; then
          echo "unmounted $dir (forced)"
        else
          echo "could not unmount $dir; run: umount -f '$dir'" >&2
        fi
      done <"$mounts_file"
      rm -f "$mounts_file"
    }

    if (( attach && stop )); then
      echo "--attach and --stop are alternatives" >&2
      exit 2
    fi
    if (( (reset || mount_only) && !bootstrap )); then
      echo "--reset and --mount act on the installer; use them with --bootstrap" >&2
      exit 2
    fi
    if (( reset && mount_only )); then
      echo "--reset and --mount are alternatives" >&2
      exit 2
    fi
    installer=$bootstrap

    stop_timeout="''${MBP_APPLE_VM_STOP_TIMEOUT:-120}"
    if [[ ! "$stop_timeout" =~ ^[0-9]+$ ]]; then
      echo "MBP_APPLE_VM_STOP_TIMEOUT must be a non-negative integer" >&2
      exit 1
    fi

    # Shuts down the VM whose QEMU is $1: an ACPI power button press, so the
    # guest unmounts its filesystems on the way down, then SIGTERM once
    # stop_timeout runs out - SIGTERM only ends QEMU, which the guest
    # experiences as the plug coming out - and SIGKILL if even that is
    # ignored. force_stop, set by a second Ctrl-C, cuts the wait short.
    force_stop=0
    power_down() {
      local pid=$1 waited=0
      if [[ -S "$qmp_socket" ]]; then
        echo "asking the guest (pid $pid) to power down"
        printf '%s\n' '{"execute":"qmp_capabilities"}' '{"execute":"system_powerdown"}' \
          | socat -T5 - "UNIX-CONNECT:$qmp_socket" >/dev/null 2>&1 || true
      else
        # A VM from before QMP existed here, or one whose socket was lost.
        echo "no QMP socket at $qmp_socket; sending SIGTERM to pid $pid" >&2
        kill "$pid" 2>/dev/null || true
      fi
      while (( waited < stop_timeout && !force_stop )) && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$(( waited + 1 ))
      done
      if kill -0 "$pid" 2>/dev/null; then
        if (( force_stop )); then
          echo "forcing it: sending SIGTERM" >&2
        else
          echo "guest did not stop within ''${stop_timeout}s; sending SIGTERM" >&2
        fi
        kill "$pid" 2>/dev/null || true
        waited=0
        while (( waited < 10 )) && kill -0 "$pid" 2>/dev/null; do
          sleep 1
          waited=$(( waited + 1 ))
        done
      fi
      if kill -0 "$pid" 2>/dev/null; then
        echo "QEMU ignored SIGTERM; sending SIGKILL" >&2
        kill -9 "$pid" 2>/dev/null || true
      fi
    }

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
      unmount_shares
      power_down "$stop_pid"
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
    rm -f "$qmp_socket" "$qemu_pidfile" "$mounts_file"

    client_pid=""
    qemu_pid=""
    mounter_pid=""
    launched=0
    cleaned=0
    cleanup() {
      if (( cleaned )); then
        return 0
      fi
      cleaned=1
      # Every step has to run whatever the one before it did: a write to a
      # terminal that has gone away fails, and errexit would otherwise end the
      # launcher here and leave QEMU, in its own session, running headless.
      set +e
      # The mounter first, so it cannot mount anything behind the unmount, and
      # then the shares, while the guest can still answer for them.
      if [[ -n "$mounter_pid" ]]; then
        kill "$mounter_pid" 2>/dev/null
        wait "$mounter_pid" 2>/dev/null
      fi
      if vm_pid >/dev/null; then
        unmount_shares
      else
        unmount_shares force
      fi
      # QEMU goes next, and the client after. The client subshell spends its
      # life waiting on spicy in the foreground, so a signal to it would sit
      # undelivered until spicy exited; ending QEMU closes the SPICE socket,
      # which brings spicy down on its own and lets that wait finish promptly.
      #
      # The guest does not outlive its launcher either way. An orphaned QEMU is
      # precisely the state this whole file is trying to avoid: a VM still
      # running, with no display, owned by nobody. The pidfile covers the
      # provisioning path too, where expect owns QEMU; we hold the lock, so
      # whatever is in there is ours.
      if (( launched )) && running=$(vm_pid); then
        power_down "$running"
      fi
      if [[ -n "$qemu_pid" ]]; then
        wait "$qemu_pid" 2>/dev/null
      fi
      if [[ -n "$client_pid" ]]; then
        kill "$client_pid" 2>/dev/null
        wait "$client_pid" 2>/dev/null
      fi
      rm -f "$spice_socket" "$qmp_socket"
      rm -rf "$lock_dir"
    }
    # Ctrl-C and TERM: the --stop sequence, with a second Ctrl-C forcing it.
    # A closed terminal (HUP) the same, logging to the state directory since
    # there is nowhere left to print. EXIT covers QEMU ending on its own.
    # shellcheck disable=SC2329 # invoked by the traps below
    on_signal() {
      trap 'force_stop=1' INT
      echo
      echo "shutting the guest down; Ctrl-C again to force it"
      cleanup
      trap - EXIT
      exit 130
    }
    # shellcheck disable=SC2329 # invoked by the traps below
    on_hangup() {
      exec >>"$state_dir/launcher.log" 2>&1
      echo "$(date): terminal closed; shutting the guest down"
      cleanup
      trap - EXIT
      exit 129
    }
    trap on_signal INT TERM
    trap on_hangup HUP
    trap cleanup EXIT

    if (( reset )); then
      rm -f "$disk" "$firmware_vars" "$needs_provision"
    fi

    if [[ ! -e "$disk" ]]; then
      if (( ! bootstrap )); then
        echo "there is no disk at $disk yet; create and provision one with --bootstrap" >&2
        exit 1
      fi
      truncate -s "''${MBP_APPLE_VM_DISK_SIZE:-512G}" "$disk"
      touch "$needs_provision"
    fi

    if [[ -e "$needs_provision" ]]; then
      if (( ! bootstrap )); then
        echo "$disk was never fully provisioned; finish it with --bootstrap" >&2
        exit 1
      fi
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
    netdev="user,id=net0,hostfwd=tcp:127.0.0.1:$ssh_port-:22"
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
      # --bootstrap: redirected devices need somewhere to attach, and the
      # installer's ISO drive hangs off this same xhci.
      -device "qemu-xhci,id=xhci"
      -drive "if=none,id=root,format=raw,file=$disk"
      -device "virtio-blk-pci,drive=root,bootindex=0"
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
        # The installer's console, on this terminal: raw, so Ctrl-C reaches
        # the installer rather than ending the launcher. Regular runs have
        # none.
        -chardev "stdio,id=console,signal=off"
        -device "virtconsole,chardev=console"
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

    # Guest directories this Mac mounts over NFS; the usage text above has the
    # table and the reasons. The manifest written here tells the guest's
    # vm-shares.service which of its directories to export, and reaches it
    # over the one 9p device left: a read-only export of the manifest's own
    # directory, found by a mount tag fixed at build time.
    mappings_file="''${MBP_APPLE_VM_MAPPINGS:-$HOME/guest-vm-fs-mappings.json}"
    manifest_tag="vm-shares"
    manifest_dir="$state_dir/shares"
    rm -rf "$manifest_dir"
    mkdir -p "$manifest_dir"

    # mountdPort in the guest's shares.nix; the two must agree. nfsd is on
    # 2049 in there.
    guest_mountd_port=20048

    # A glob rather than ls, so a name with a newline in it cannot be read as
    # two entries. Finder leaves a .DS_Store in any directory it has shown, and
    # hiding that under a mount loses nothing.
    dir_is_empty() {
      local entry
      local -a entries=()
      shopt -s nullglob dotglob
      entries=("$1"/*)
      shopt -u nullglob dotglob
      for entry in ''${entries[@]+"''${entries[@]}"}; do
        [[ "''${entry##*/}" == .DS_Store ]] || return 1
      done
    }

    # The mount(8) line for whatever is mounted on $1, if anything.
    mount_line() {
      /sbin/mount | awk -v needle=" on $1 (" 'index($0, needle) { print; exit }'
    }

    # Leaves $1 an empty directory the guest's $2 can be mounted on, or says
    # why it cannot be.
    prepare_mount_point() {
      local dir=$1 guest=$2 line
      line=$(mount_line "$dir")
      if [[ -n "$line" ]]; then
        if [[ "$line" != "127.0.0.1:$guest on $dir ("* ]]; then
          echo "$dir already has something else mounted on it ($line); skipping" >&2
          return 1
        fi
        # From a launcher that never got to clean up; the guest behind it is
        # gone.
        echo "unmounting a stale mount of the guest's $guest at $dir"
        if ! /sbin/umount -f "$dir"; then
          echo "could not unmount it; skipping $dir" >&2
          return 1
        fi
      fi
      if [[ -e "$dir" && ! -d "$dir" ]]; then
        echo "$dir exists and is not a directory; skipping" >&2
        return 1
      fi
      mkdir -p "$dir"
      if ! dir_is_empty "$dir"; then
        echo "$dir is not empty; refusing to hide what is in it behind the guest's $guest." >&2
        echo "Whatever is there belongs in the guest: move it aside and start again." >&2
        return 1
      fi
    }

    shares=()
    if (( installer )); then
      if [[ -e "$mappings_file" ]]; then
        echo "the installer exports nothing; $mappings_file applies once the installed system boots"
      fi
    elif [[ -e "$mappings_file" ]]; then
      if ! shares_tsv=$(jq -r '
            def rows: if type == "array" then . else (.shares // .mappings // []) end;
            rows
            | map(select(type == "object"))
            | .[]
            | [ (.host // ""),
                (.guest // ""),
                (.mode // "rw"),
                (.transport // "nfs"),
                ((.remap // false) | tostring)
              ]
            | join("\u001f")
          ' "$mappings_file" 2>&1); then
        echo "$mappings_file could not be read as a mapping table:" >&2
        echo "$shares_tsv" >&2
        exit 1
      fi

      # A unit separator rather than a tab: bash counts tab as IFS whitespace
      # and collapses runs of it, so an empty field would shift every other
      # one along.
      while IFS=$'\x1f' read -r host guest mode transport remap; do
        # A blank line is what an empty table reads as, not a broken entry.
        if [[ -z "$host$guest" ]]; then
          continue
        fi
        if [[ -z "$host" || -z "$guest" ]]; then
          echo "a mapping needs both host and guest; skipping" >&2
          continue
        fi
        # Both paths are spelled out in full, on both sides of the boundary.
        # Nothing here expands a ~: the launcher's idea of a home directory is
        # not the guest's, and a mapping that reads differently depending on
        # who resolves it is a mapping waiting to land somewhere unintended.
        if [[ "$host" != /* ]]; then
          echo "host path $host is not absolute; skipping" >&2
          continue
        fi
        if [[ "$guest" != /* ]]; then
          echo "guest path $guest is not absolute; skipping" >&2
          continue
        fi
        # The guest writes its path into exports(5), which separates fields
        # with whitespace, and the rows kept below are tab-separated.
        if [[ "$guest" =~ [[:space:]] || "$host" == *$'\t'* ]]; then
          echo "$host: guest paths cannot contain whitespace, nor host paths tabs; skipping" >&2
          continue
        fi
        case "$mode" in
          ro | rw) ;;
          *)
            echo "$host: mode must be ro or rw, not $mode; skipping" >&2
            continue
            ;;
        esac
        if [[ "$transport" != nfs ]]; then
          echo "$host: transport must be nfs, the only one the guest exports over, not $transport; skipping" >&2
          continue
        fi
        if [[ "$remap" != false ]]; then
          echo "$host: remap belonged to the 9p share; the guest already answers as its own account; skipping" >&2
          continue
        fi
        duplicate=0
        for seen in ''${shares[@]+"''${shares[@]}"}; do
          IFS=$'\t' read -r seen_host seen_guest _ <<<"$seen"
          if [[ "$seen_host" == "$host" || "$seen_guest" == "$guest" ]]; then
            duplicate=1
            break
          fi
        done
        if (( duplicate )); then
          echo "$host: another mapping already uses $host or $guest; skipping" >&2
          continue
        fi
        if ! prepare_mount_point "$host" "$guest"; then
          continue
        fi
        shares+=("$host"$'\t'"$guest"$'\t'"$mode")
        echo "mounting the guest's $guest at $host ($mode) once the guest exports it"
      done <<<"$shares_tsv"
    fi

    if (( ''${#shares[@]} > 0 )); then
      nfs_port="''${MBP_APPLE_VM_NFS_PORT:-2225}"
      mountd_port="''${MBP_APPLE_VM_MOUNTD_PORT:-2226}"
      nfs_timeout="''${MBP_APPLE_VM_NFS_TIMEOUT:-300}"
      for setting in "MBP_APPLE_VM_NFS_PORT=$nfs_port" "MBP_APPLE_VM_MOUNTD_PORT=$mountd_port" \
        "MBP_APPLE_VM_NFS_TIMEOUT=$nfs_timeout"; do
        if [[ ! "''${setting#*=}" =~ ^[1-9][0-9]*$ ]]; then
          echo "''${setting%%=*} must be a positive integer, not ''${setting#*=}" >&2
          exit 1
        fi
      done
      if (( nfs_port == mountd_port || nfs_port == ssh_port || mountd_port == ssh_port )); then
        echo "SSH, NFS and mountd need three different host ports, not $ssh_port, $nfs_port and $mountd_port" >&2
        exit 1
      fi
      # As for SSH: QEMU would report a taken port as an unbuildable
      # forwarding rule, long after it has taken over the terminal.
      for port in "$nfs_port" "$mountd_port"; do
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
          echo "host port $port is already in use, so the guest's NFS cannot be forwarded" >&2
          echo "free it, or set MBP_APPLE_VM_NFS_PORT and MBP_APPLE_VM_MOUNTD_PORT to other ports" >&2
          exit 1
        fi
      done
      netdev="$netdev,hostfwd=tcp:127.0.0.1:$nfs_port-:2049,hostfwd=tcp:127.0.0.1:$mountd_port-:$guest_mountd_port"

      # Exported read-only and written before QEMU starts: the guest reads
      # this to learn what to export, and has no business changing it. host is
      # only there for the guest to name in its log.
      printf '%s\n' "''${shares[@]}" | jq -R -s '
        {
          version: 2,
          shares: (
            split("\n")
            | map(select(length > 0) | split("\t") | { host: .[0], guest: .[1], mode: .[2] })
          ),
        }' >"$manifest_dir/manifest.json"
      qemu_args+=(
        -fsdev "local,id=fsmanifest,path=$manifest_dir,security_model=none,readonly=on"
        -device "virtio-9p-pci,id=fsdevmanifest,fsdev=fsmanifest,mount_tag=$manifest_tag"
      )

      # Port and mountport name the forwards, so mount_nfs never asks a
      # portmapper, which is not forwarded. retrycnt=0 makes each attempt a
      # single connection with the quick 8s timeout, since the loop below is
      # the retry; timeout covers an attempt that hangs regardless. actimeo=5
      # caps how stale this Mac's view of a file or directory can get at five
      # seconds, where macOS would otherwise trust an old one for up to 60.
      nfs_mount_options="vers=3,tcp,port=$nfs_port,mountport=$mountd_port,locallocks,soft,intr,deadtimeout=60,retrycnt=0,nobrowse,actimeo=5"

      # Runs in the background while QEMU does: waits for the guest to export
      # each share, mounts it, and records it for unmount_shares.
      mount_shares() {
        local row dir guest mode options err="$state_dir/nfs-mount.err"
        local -a pending=("''${shares[@]}") waiting=()
        local deadline=$(( SECONDS + nfs_timeout ))
        # QEMU writes its pidfile while it starts up, and removes it on the
        # way out.
        for _ in {1..600}; do
          if vm_pid >/dev/null; then
            break
          fi
          sleep 0.1
        done
        while (( ''${#pending[@]} > 0 )); do
          vm_pid >/dev/null || return 0
          waiting=()
          for row in "''${pending[@]}"; do
            IFS=$'\t' read -r dir guest mode <<<"$row"
            options=$nfs_mount_options
            if [[ "$mode" == ro ]]; then
              options="$options,rdonly"
            fi
            if timeout 30 /sbin/mount_nfs -o "$options" "127.0.0.1:$guest" "$dir" 2>"$err"; then
              printf '%s\n' "$dir" >>"$mounts_file"
              echo "mounted the guest's $guest at $dir ($mode)"
            else
              waiting+=("$row")
            fi
          done
          pending=(''${waiting[@]+"''${waiting[@]}"})
          (( ''${#pending[@]} > 0 )) || break
          if (( SECONDS >= deadline )); then
            for row in "''${pending[@]}"; do
              IFS=$'\t' read -r dir guest mode <<<"$row"
              echo "the guest did not export $guest within ''${nfs_timeout}s; $dir stays unmounted" >&2
            done
            echo "the last attempt said: $(cat "$err")" >&2
            echo "mount by hand with: mount_nfs -o $nfs_mount_options 127.0.0.1:GUEST_DIR HOST_DIR" >&2
            return 0
          fi
          sleep 2
        done
      }
    fi

    qemu_args+=(
      -netdev "$netdev"
      -device "virtio-net-pci,netdev=net0"
    )

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
    elif (( bootstrap )); then
      # The bare installer: QEMU in the background with this terminal as its
      # console. A background command with no redirection of its own would be
      # handed /dev/null and lose the virtconsole.
      exec 9<&0
      launched=1
      qemu-system-aarch64 "''${qemu_args[@]}" "$@" <&9 &
      qemu_pid=$!
      status=0
      wait "$qemu_pid" || status=$?
      qemu_pid=""
    else
      if (( ''${#shares[@]} > 0 )); then
        mount_shares &
        mounter_pid=$!
      fi
      # QEMU in a session of its own, reading nothing from this terminal:
      # the terminal's Ctrl-C and hangup go to the launcher alone, which then
      # shuts the guest down properly instead of QEMU dropping it on the spot.
      # bash runs traps while it sits in wait, so they fire promptly.
      launched=1
      perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!\n"; exec { $ARGV[0] } @ARGV or die "exec: $!\n"' \
        qemu-system-aarch64 "''${qemu_args[@]}" "$@" </dev/null &
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
