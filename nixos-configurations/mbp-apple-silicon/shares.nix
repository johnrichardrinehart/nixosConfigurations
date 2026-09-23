{
  config,
  lib,
  pkgs,
  ...
}:
let
  primaryUser = config.dev.johnrinehart.users.primary;

  # The uid the host's 9p server acts as, which is whoever starts the
  # launcher: `id -u` on that Mac is the authority, and 501 is only the number
  # macOS happens to give its first account. This is the one place it is
  # written down. Change it here and renumber the guest account to match; the
  # mount service checks the two against what the launcher actually reports and
  # says so when they have drifted apart.
  hostUid = 501;

  # The launcher's manifest_tag. These two strings are the whole protocol: the
  # guest finds one 9p device by a name fixed at build time, and everything
  # else about every other share - where it goes, how it is cached, whether it
  # is remapped - is read out of the manifest.json inside it. A mount tag caps
  # at 31 bytes (MAX_TAG_LEN in QEMU's hw/9pfs/9p.h) and so cannot carry a
  # path, which is why there is a manifest at all.
  manifestTag = "vm-shares";
  manifestMount = "/run/vm-shares";

  # Raw 9p mounts for shares that bindfs then shifts. Kept outside
  # manifestMount because that is itself a read-only 9p mount and nothing can
  # be created inside it.
  lowerRoot = "/run/vm-shares-lower";

  mountShares = pkgs.writeShellApplication {
    name = "vm-mount-shares";
    runtimeInputs = [
      pkgs.bindfs
      pkgs.coreutils
      pkgs.jq
      pkgs.util-linux
    ];
    text = ''
      # A glob rather than ls, so a name with a newline in it cannot be read as
      # two entries and an empty directory cannot be read as one.
      dir_is_empty() {
        local dir=$1
        local -a entries=()
        shopt -s nullglob dotglob
        entries=("$dir"/*)
        shopt -u nullglob dotglob
        (( ''${#entries[@]} == 0 ))
      }

      manifest="${manifestMount}/manifest.json"

      if ! mountpoint -q "${manifestMount}"; then
        mkdir -p "${manifestMount}"
        # No device is not a failure: it is what every boot of a VM started
        # with an empty mapping table looks like.
        if ! mount -t 9p -o trans=virtio,version=9p2000.L,cache=none,msize=512000,ro \
          ${manifestTag} "${manifestMount}" 2>/dev/null; then
          echo "no ${manifestTag} 9p device; this boot exports no host directories"
          exit 0
        fi
      fi

      if [[ ! -e "$manifest" ]]; then
        echo "${manifestTag} carries no manifest.json; exporting nothing" >&2
        exit 0
      fi

      host_uid=$(jq -r '.hostUid' "$manifest")
      host_gid=$(jq -r '.hostGid' "$manifest")
      guest_uid=$(id -u ${primaryUser})
      guest_gid=$(id -g ${primaryUser})

      failed=0
      # A unit separator rather than a tab, which bash counts as IFS
      # whitespace and would collapse runs of.
      while IFS=$'\x1f' read -r tag host guest mode cache msize remap; do
        [[ -n "$tag" ]] || continue

        # The launcher rejects anything that is not absolute before it writes
        # the manifest, so reaching this means the two halves disagree about
        # what a mapping is. Refuse rather than mount something under the
        # working directory of a boot-time service.
        if [[ "$host" != /* || "$guest" != /* ]]; then
          echo "$tag maps $host to $guest, which are not both absolute; skipping" >&2
          failed=1
          continue
        fi

        if mountpoint -q "$guest"; then
          continue
        fi

        # Mounting over a directory that already has something in it neither
        # merges nor replaces it: the old contents stay on the guest's own
        # disk, unreachable and invisible to du until the mount goes away.
        # Doing that silently to somewhere inside a home directory is how a
        # share gets mistaken for data loss - and how an rm -rf aimed at the
        # stale copy travels through the mount and empties the Mac instead.
        # The directory this service creates itself is empty, so this only
        # ever catches something that was already there.
        if [[ -d "$guest" ]] && ! dir_is_empty "$guest"; then
          echo "$guest is not empty; refusing to hide what is in it behind $host." >&2
          echo "Move it aside or remove it, then: systemctl restart vm-shares" >&2
          failed=1
          continue
        fi

        opts="trans=virtio,version=9p2000.L,cache=$cache,msize=$msize"
        if [[ "$mode" == ro ]]; then
          opts="$opts,ro"
        fi

        # Without a remap the 9p mount is the share, and lands directly on the
        # guest path. With one it is only the lower half, and bindfs is what
        # the guest actually sees.
        if [[ "$remap" == true ]]; then
          target="${lowerRoot}/$tag"
        else
          target="$guest"
        fi

        # Both ends up front: the guest path always has to exist, and a
        # remapped share also needs somewhere to put the raw 9p mount that
        # bindfs reads through. Without a remap these are the same directory
        # and the second pass does nothing.
        for dir in "$guest" "$target"; do
          if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            # Whoever has to look at this if a mount below fails.
            chown "${primaryUser}" "$dir" || true
          fi
        done

        # A run that failed part way through can leave the lower half mounted
        # under a guest path that never got its bindfs, and mounting 9p over
        # it again would just stack another one on top.
        if ! mountpoint -q "$target"; then
          if ! mount -t 9p -o "$opts" "$tag" "$target"; then
            echo "could not mount $tag at $target" >&2
            failed=1
            continue
          fi
        fi

        if [[ "$remap" != true ]]; then
          # Without a remap the share carries the host's ownership unchanged,
          # so the account only gets to write it when it answers to the same
          # number. Nothing here can fix that at mount time - the uid is fixed
          # at build time and the account has to be renumbered by hand - but a
          # share that is quietly read-only is worth naming out loud.
          if [[ "$host_uid" != "$guest_uid" ]]; then
            echo "warning: $host is exported by uid $host_uid but ${primaryUser} is $guest_uid," >&2
            echo "         so $guest is effectively read-only. Either set" >&2
            echo "         dev.johnrinehart.users.forceUid.uid to $host_uid and renumber the" >&2
            echo "         account, or give this mapping \"remap\": true." >&2
          fi
          echo "mounted $host at $guest ($mode, cache=$cache)"
          continue
        fi

        # Nothing on this host needs this any more - its account carries the
        # same uid as the Mac's, so the shares arrive already owned correctly -
        # but it stays for the case where the two cannot be reconciled: a host
        # uid already taken in the guest, an account that cannot be renumbered,
        # or a share exported by someone other than the guest's own user.
        #
        # It is a last resort rather than a default, and the reason is
        # measured. Every FUSE lookup is forwarded to userspace and re-stat'ed
        # against the mount below instead of being served from the guest's
        # dentry cache, which works out at about two 9p round trips per path
        # component on every operation. On this guest that was 23ms against
        # 4ms for the same six-component path taken directly, and git status
        # on a small repository went from 3.1s to 0.34s when it came out.
        #
        # attr_timeout and friends default to a second in libfuse, which would
        # put a cache back on top of the very mount that asked for cache=none
        # to be rid of one: a lock file created on the host could sit invisible
        # in here for as long as the entry is held. Zero them all.
        if bindfs \
          --map="$host_uid/$guest_uid:@$host_gid/@$guest_gid" \
          -o allow_other,attr_timeout=0,entry_timeout=0,negative_timeout=0 \
          "$target" "$guest"; then
          echo "mounted $host at $guest ($mode, cache=$cache, $host_uid:$host_gid -> $guest_uid:$guest_gid)"
        else
          echo "could not lay bindfs over $target at $guest" >&2
          umount "$target" || true
          failed=1
        fi
      done < <(jq -r '
        .shares[]
        | [.tag, .host, .guest, .mode, .cache, (.msize | tostring), (.remap | tostring)]
        | join("\u001f")
      ' "$manifest")

      exit "$failed"
    '';
  };

  # Gives a dependency directory inside a share a guest-local directory of the
  # same name, bind-mounted over it: /var/lib/vm-local-dirs/<uid>/<key>. Runs
  # as root through sudo (see security.sudo.extraRules below) for the user
  # named by SUDO_UID, who owns everything on the shares and so could swap any
  # path component for a symlink at any moment. Hence: the name is from an
  # allowlist, the path must already be canonical and inside a mounted share,
  # the mount point is created as the user, and the mount goes onto the
  # directory actually opened and checked (through /proc/self/fd, with
  # canonicalisation off) rather than onto a name resolved again later.
  localDir = pkgs.writeShellApplication {
    name = "vm-local-dir";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.util-linux
    ];
    text = ''
      die() {
        echo "vm-local-dir: $*" >&2
        exit 1
      }

      [[ $# -eq 1 ]] || die "usage: vm-local-dir /share/.../project/{node_modules,.venv}"
      uid=''${SUDO_UID:-}
      gid=''${SUDO_GID:-}
      [[ $uid =~ ^[1-9][0-9]*$ && $gid =~ ^[0-9]+$ ]] || die "run through sudo, not as root"

      path=$1
      name=''${path##*/}
      parent=''${path%/*}
      case "$name" in
        node_modules | .venv) ;;
        *) die "$name is not a directory this helper relocates" ;;
      esac
      [[ $path == /* ]] || die "$path is not absolute"
      # Refused rather than resolved: .., //, or a symlink anywhere along it.
      [[ $(realpath -e -- "$parent") == "$parent" ]] || die "$parent is not a canonical existing path"

      inside=""
      while IFS= read -r root; do
        root=''${root%/}
        [[ -n $root ]] || continue
        if [[ $parent == "$root" || $parent == "$root"/* ]] && mountpoint -q -- "$root"; then
          inside=$root
        fi
      done < <(jq -r '.shares[].guest' ${manifestMount}/manifest.json 2>/dev/null)
      [[ -n $inside ]] || die "$parent is not inside a mounted share"

      if mountpoint -q -- "$path"; then
        exit 0
      fi
      if [[ ! -e $path && ! -L $path ]]; then
        setpriv --reuid="$uid" --regid="$gid" --clear-groups mkdir -- "$path"
      fi
      [[ -d $path && ! -L $path ]] || die "$path is not a directory"

      store=/var/lib/vm-local-dirs
      install -d -m 0755 -o root -g root "$store" "$store/$uid"
      key=$(printf '%s' "$path" | sha1sum | cut -c1-40)
      backing=$store/$uid/$key-$name
      [[ -d $backing ]] || install -d -m 0755 -o "$uid" -g "$gid" "$backing"

      exec {fd}<"$path"
      [[ $(readlink "/proc/self/fd/$fd") == "$path" ]] || die "$path changed while it was being checked"
      # The classic mount(2) follows the /proc magic link to the opened
      # directory; libmount's fd-based path (open_tree/move_mount) rejects it
      # with EINVAL.
      LIBMOUNT_FORCE_MOUNT2=always mount --no-canonicalize --bind "$backing" "/proc/self/fd/$fd"
    '';
  };
in
{
  # 9p autoloads through its module alias when the first mount asks for the
  # virtio transport, but the manifest mount is the earliest thing in the boot
  # that does and there is nothing to be gained from discovering a missing
  # module then.
  boot.kernelModules = [
    "9p"
    "9pnet_virtio"
  ];

  # bindfs runs as root and hands the mount to the primary user, which is
  # exactly the case allow_other exists for.
  programs.fuse.userAllowOther = true;

  # This Mac's uid, so a share arrives already owned by the account that uses
  # it and no bindfs is needed to shift it. Measured on this guest: a stat
  # through bindfs costs about 4ms per path component against 0.7ms on the 9p
  # mount underneath it, because every FUSE lookup is forwarded to userspace
  # and re-stat'ed rather than served from the guest's dentry cache.
  #
  # Set "remap": false in the mapping table once `id -u` in here agrees with
  # this. It cannot be flipped in advance: NixOS leaves an existing account's
  # uid alone, so until the usermod is done the guest still holds its old
  # number and the bindfs layer is the only thing making the share writable.
  dev.johnrinehart.users.forceUid = {
    username = primaryUser;
    uid = hostUid;
  };

  # cache=none keeps no dentries: every lookup of a path component not pinned
  # by the cwd or an open file is a TWALK and a TGETATTR, about 1.4ms on this
  # guest, and a readdir costs the host one lstat per entry. `git status` on a
  # 1500-file worktree under the share came to 7s of that, and the prompt runs
  # one per command. Git's fsmonitor hook takes the stats out of it: the hook
  # asks a watchman on the Mac what changed since the last token - it sees the
  # host's writes and the guest's alike, since the 9p server makes the guest's
  # as ordinary host syscalls - and git stats only those. Measured at 0.3s
  # against 7.4s on the same worktree. The launcher runs the watchman and the
  # bridge to it and names the bridge in the manifest; without them the hook
  # fails and git scans as before, slower but never wrong.
  dev.johnrinehart.programs.git.hostFsmonitor.enable = true;

  # Per-machine state out of trees on the shares, for direnv users in this
  # guest. A share is the Mac's worktree too: whatever a build or an install
  # writes into it lands on 9p (a round trip per operation), is seen by the
  # Mac, and is usually for the wrong OS there - aarch64-linux artifacts,
  # native node modules - so the two sides overwrite each other.
  #
  # - direnv's layout directory (nix-direnv's cached environment, profile and
  #   gc roots; `.direnv` beside the `.envrc` by default) moves to this guest's
  #   cache, keyed by directory. nix-direnv names its profile after the `use
  #   flake` arguments alone, so in-tree the two sides would swap profiles.
  # - CARGO_TARGET_DIR defaults to ~/.cache/cargo-target/<worktree key> when
  #   neither the environment, the project's devShell nor the `.envrc` before
  #   `use flake` chose one: one root, a directory per `.envrc`.
  # - Dependency directories that tools insist on keeping in the tree
  #   (node_modules beside each tracked package.json, .venv beside each
  #   tracked pyproject.toml) get a guest-local directory bind-mounted over
  #   them by vm-local-dir, before the devShell's hooks can write there. The
  #   guest sees its own copy at the usual path; the Mac sees an empty
  #   directory under the mount point and keeps its own.
  #
  # The last two hook `use flake` and `use nix`, where the working directory
  # is the `.envrc`'s: direnvrc itself is sourced from wherever direnv was
  # invoked. All of it applies only when the session says it is in a VM guest
  # (VM_GUEST=1, set by the overlay that runs this configuration as
  # one) and only to trees on a network filesystem. The type comes from the
  # mount table: statfs on 9p reports the host filesystem's magic (APFS).
  home-manager.users.${primaryUser}.programs.direnv.stdlib = ''
    if [[ "''${VM_GUEST:-}" == 1 ]]; then
      _vm_on_share() {
        case "$(${pkgs.util-linux}/bin/findmnt -n -o FSTYPE --target "$1" 2>/dev/null)" in
          9p | nfs | nfs4 | virtiofs | cifs | smb3 | fuse.*) return 0 ;;
        esac
        return 1
      }

      # A name for a directory that is unique (the hash) and readable (the path).
      _vm_dir_key() {
        local hash
        hash=$(printf '%s' "$1" | ${pkgs.coreutils}/bin/sha1sum | ${pkgs.coreutils}/bin/cut -c1-40)
        echo "$hash''${1//[^a-zA-Z0-9]/-}"
      }

      direnv_layout_dir() {
        if [[ -n "''${direnv_layout_dir:-}" ]]; then
          echo "$direnv_layout_dir"
        elif _vm_on_share "$PWD"; then
          echo "''${XDG_CACHE_HOME:-$HOME/.cache}/direnv/layouts/$(_vm_dir_key "$PWD")"
        else
          echo "$PWD/.direnv"
        fi
      }

      _vm_before_env() {
        _vm_on_share "$PWD" || return 0
        local manifest dir name path
        # The index names every tracked manifest without walking the tree.
        while IFS= read -r -d "" manifest; do
          case "''${manifest##*/}" in
            package.json) name=node_modules ;;
            pyproject.toml) name=.venv ;;
            *) continue ;;
          esac
          dir=$PWD/''${manifest%/*}
          [[ $manifest == */* ]] || dir=$PWD
          path=$dir/$name
          ${pkgs.util-linux}/bin/mountpoint -q -- "$path" 2>/dev/null && continue
          /run/wrappers/bin/sudo -n ${localDir}/bin/vm-local-dir "$path" ||
            log_error "could not give $path a guest-local directory; it stays on the share"
        done < <(git -C "$PWD" ls-files -z -- ':(glob)**/package.json' ':(glob)**/pyproject.toml' 2>/dev/null)
      }

      _vm_after_env() {
        _vm_on_share "$PWD" || return 0
        if [[ -z "''${CARGO_TARGET_DIR:-}" ]]; then
          export CARGO_TARGET_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/cargo-target/$(_vm_dir_key "$PWD")"
        fi
      }

      # Wraps nix-direnv's entry points, which its library (loaded before this
      # file) has already defined. An .envrc that source_url's its own
      # nix-direnv replaces them unwrapped, but only when the installed one is
      # older than it asks for.
      _vm_wrap() {
        declare -F "$1" >/dev/null || return 0
        eval "_vm_orig_$1() $(declare -f "$1" | ${pkgs.coreutils}/bin/tail -n +2)"
        eval "$1() { _vm_before_env; _vm_orig_$1 \"\$@\"; local status=\$?; _vm_after_env; return \$status; }"
      }
      _vm_wrap use_flake
      _vm_wrap use_nix
    fi
  '';

  # Only the primary user, only this helper, and the helper refuses anything
  # but an allowlisted directory name inside a mounted share.
  security.sudo.extraRules = [
    {
      users = [ primaryUser ];
      commands = [
        {
          command = "${localDir}/bin/vm-local-dir";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  systemd.services.vm-shares = {
    description = "Mount the host directories exported to this guest over 9p";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    # The session should find its shares already in place rather than racing
    # them. Ordering against a unit that does not exist is a no-op, so this
    # costs nothing on a guest booted without a display.
    before = [ "greetd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe mountShares;
      # A 9p mount against a host that has stopped answering would otherwise
      # hold the boot open indefinitely.
      TimeoutStartSec = "60s";
    };
  };
}
