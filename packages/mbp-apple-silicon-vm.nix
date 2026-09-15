{
  bootstrapIso,
  coreutils,
  expect,
  guestFlake,
  gvproxy,
  lib,
  libarchive,
  runCommand,
  vfkit,
  writeShellApplication,
  writeText,
}:
let
  bootstrapArtifacts =
    runCommand "nixos-installer-vfkit-boot" { nativeBuildInputs = [ libarchive ]; }
      ''
        mkdir -p "$out"
        bsdtar -xOf ${bootstrapIso} EFI/BOOT/grub.cfg > grub.cfg

        linux_line=$(awk '$1 == "linux" && $2 ~ "^/boot/" { print; exit }' grub.cfg | sed 's|[$]{isoboot}||')
        initrd_line=$(awk '$1 == "initrd" && $2 ~ "^/boot/" { print; exit }' grub.cfg)
        if [[ -z "$linux_line" || -z "$initrd_line" ]]; then
          echo "failed to read the default installer boot entry" >&2
          exit 1
        fi

        kernel_member=$(awk '{ print $2 }' <<< "$linux_line" | sed -e 's|^/||' -e 's|//|/|g')
        initrd_member=$(awk '{ print $2 }' <<< "$initrd_line" | sed -e 's|^/||' -e 's|//|/|g')
        kernel_cmdline=$(awk '{ $1 = ""; $2 = ""; sub(/^ +/, ""); print }' <<< "$linux_line")

        bsdtar -xOf ${bootstrapIso} "$kernel_member" > "$out/Image"
        bsdtar -xOf ${bootstrapIso} "$initrd_member" > "$out/initrd"
        printf '%s console=tty0 console=hvc0\n' "$kernel_cmdline" > "$out/cmdline"
        test -s "$out/Image"
        test -s "$out/initrd"
      '';

  serialProvisioner = writeText "mbp-apple-silicon-provision.expect" ''
    set timeout 5
    set network [lindex $argv 0]
    set provision [lindex $argv 1]
    set marker [lindex $argv 2]
    set serial_log [lindex $argv 3]
    set boot_timeout [lindex $argv 4]
    set command [lrange $argv 5 end]
    set boot_started [clock seconds]
    set next_status 30
    log_file -a -noappend $serial_log
    log_user 0
    spawn -noecho {*}$command
    send_user "Starting VM; serial output is being saved to $serial_log.\n"
    expect {
      -re {\r?\n__NIXOS_INSTALLER_READY_7C18D3__\r?\n} {}
      timeout {
        set elapsed [expr {[clock seconds] - $boot_started}]
        if {$elapsed >= $boot_timeout} {
          send_user "\nInstaller shell did not appear within $boot_timeout seconds.\n"
          send_user "Inspect the captured boot output at $serial_log.\n"
          catch {exec kill -TERM [exp_pid]}
          catch {close}
          catch {wait}
          exit 124
        }
        if {$elapsed >= $next_status} {
          send_user "Still waiting for the NixOS installer shell ($elapsed seconds)...\n"
          incr next_status 30
        }
        send -- "\rprintf '\\n__NIXOS_INSTALLER_READY_7C18D3__\\n'\r"
        exp_continue
      }
      eof {
        set result [wait]
        exit [lindex $result 3]
      }
    }
    set timeout -1
    send_user "\nNixOS installer ready; waiting for guest networking.\n"
    send -- "$network\r"
    expect {
      -re {\r?\n__NIXOS_NETWORK_READY_7C18D3__\r?\n} {}
      eof {
        set result [wait]
        exit [lindex $result 3]
      }
    }
    log_user 1
    send_user "\nStarting Disko provisioning.\n"
    send -- "$provision\r"
    expect {
      -re {__DISKO_PROVISION_STATUS_0__} {
        file delete -force $marker
        send_user "\nDisko provisioned /dev/vda and mounted it under /mnt.\n"
      }
      -re {__DISKO_PROVISION_STATUS_([0-9]+)__} {
        send_user "\nDisko provisioning failed with status $expect_out(1,string).\n"
      }
      eof {
        set result [wait]
        exit [lindex $result 3]
      }
    }
    send -- "stty sane; printf '\\n__NIXOS_INTERACTIVE_READY_7C18D3__\\n'\r"
    expect {
      -re {\r?\n__NIXOS_INTERACTIVE_READY_7C18D3__\r?\n} {}
      eof {
        set result [wait]
        exit [lindex $result 3]
      }
    }
    interact
    set result [wait]
    exit [lindex $result 3]
  '';
in
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
    Usage: mbp-apple-silicon-vm [--installer] [--reset] [--state-dir PATH] [-- VFKit arguments...]

    A newly created disk boots the pinned NixOS ARM installer. The launcher then
    waits for its serial shell, fetches this flake's generated Disko script,
    partitions and formats /dev/vda, and mounts it under /mnt.

    When provisioning finishes, install the small bootstrap system:
      sudo nixos-install \
        --flake github:johnrichardrinehart/nixosConfigurations#mbp-apple-silicon-bootstrap

    Later runs boot that persistent system. Rebuild it to the full
    mbp-apple-silicon configuration from inside the installed guest.
    Pass --installer to attach the ISO again.

    Environment:
      MBP_APPLE_VM_CPUS             Virtual CPU count (default: 4)
      MBP_APPLE_VM_MEMORY_MIB       Guest memory in MiB (default: 8192)
      MBP_APPLE_VM_DISK_SIZE        Sparse persistent disk size (default: 64G)
      MBP_APPLE_VM_DISPLAY_WIDTH    Virtual display width (default: 1920)
      MBP_APPLE_VM_DISPLAY_HEIGHT   Virtual display height (default: 1200)
      MBP_APPLE_VM_NETWORK_DEVICE   Custom VFKit network descriptor; bypasses gvproxy
      MBP_APPLE_VM_SSH_PORT         Host SSH forwarding port (default: 2223)
      MBP_APPLE_VM_SHARED_DIR       Optional host directory shared as "host"
      MBP_APPLE_VM_STATE_DIR        Persistent VM state directory
      MBP_APPLE_VM_IMAGE            Preinstalled raw disk image copied on first run
      MBP_APPLE_VM_BOOT_TIMEOUT      Installer shell timeout in seconds (default: 300)
    EOF
    }

    installer=0
    provision=0
    reset=0
    default_state_dir="$HOME/Library/Application Support/mbp-apple-silicon-vm"
    state_dir="''${MBP_APPLE_VM_STATE_DIR:-$default_state_dir}"
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
    if [[
      "$state_dir" == "$default_state_dir"
      && -n "''${XDG_DATA_HOME:-}"
      && ! -e "$state_dir"
      && -d "$XDG_DATA_HOME/mbp-apple-silicon-vm"
    ]]; then
      mkdir -p "$(dirname "$default_state_dir")"
      mv "$XDG_DATA_HOME/mbp-apple-silicon-vm" "$default_state_dir"
    fi


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
        truncate -s "''${MBP_APPLE_VM_DISK_SIZE:-64G}" "$disk"
        touch "$needs_provision"
        installer=1
      fi
    fi

    if [[ -e "$needs_provision" ]]; then
      installer=1
      provision=1
    fi

    cpus="''${MBP_APPLE_VM_CPUS:-4}"
    memory="''${MBP_APPLE_VM_MEMORY_MIB:-8192}"
    display_width="''${MBP_APPLE_VM_DISPLAY_WIDTH:-1920}"
    display_height="''${MBP_APPLE_VM_DISPLAY_HEIGHT:-1200}"
    network_device="''${MBP_APPLE_VM_NETWORK_DEVICE:-}"
    boot_timeout="''${MBP_APPLE_VM_BOOT_TIMEOUT:-300}"
    if [[ ! "$boot_timeout" =~ ^[1-9][0-9]*$ ]]; then
      echo "MBP_APPLE_VM_BOOT_TIMEOUT must be a positive integer" >&2
      exit 2
    fi
    serial_log="$state_dir/installer-serial.log"
    touch "$serial_log"
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
      boot_cmdline=$(<${bootstrapArtifacts}/cmdline)
      bootloader="linux,kernel=${bootstrapArtifacts}/Image,initrd=${bootstrapArtifacts}/initrd,cmdline=\"$boot_cmdline\""
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

    if (( provision )); then
      guest_flake=${lib.escapeShellArg guestFlake}
      network_command="network_ready=0; for _ in \$(seq 1 60); do if getent hosts github.com >/dev/null 2>&1; then network_ready=1; break; fi; sleep 1; done; printf '\\n__NIXOS_NETWORK_READY_7C18D3__\\n'"
      provision_command=$(cat <<EOF
    if (( network_ready )); then disko_output=\$(nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths '$guest_flake#nixosConfigurations."mbp-apple-silicon-bootstrap".config.system.build.diskoScript') && sudo "\$disko_output"; status=\$?; else echo 'network did not become ready within 60 seconds' >&2; status=69; fi; printf '\n__DISKO_PROVISION_STATUS_%s__\n' "\$status"
    EOF
      )

      if expect ${serialProvisioner} "$network_command" "$provision_command" "$needs_provision" \
        "$serial_log" "$boot_timeout" vfkit "''${vfkit_args[@]}" "$@"; then
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
