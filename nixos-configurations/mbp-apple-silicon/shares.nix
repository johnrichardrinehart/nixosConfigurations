{
  config,
  lib,
  pkgs,
  ...
}:
let
  primaryUser = config.dev.johnrinehart.users.primary;

  # The Mac's uid: `id -u` on the Mac that runs the launcher is the authority,
  # and 501 is only the number macOS gives its first account. NFSv3 hands the
  # Mac every file's numeric owner unchanged, so with the guest's account on
  # the same number the Mac's user sees its own files as its own - in Finder,
  # in `ls -l`, and in the permission checks its NFS client makes before
  # asking the guest. Writes arrive squashed to the guest account whatever
  # uid the Mac sends (all_squash, in vm-export-shares).
  hostUid = 501;

  # The launcher's manifest_tag. The guest finds one 9p device by a name fixed
  # at build time and reads which of its own directories to export out of the
  # manifest.json inside it. The table lives on the Mac so the set of shares
  # changes without rebuilding either side.
  manifestTag = "vm-shares";
  manifestMount = "/run/vm-shares";

  # exportfs reads /etc/exports.d/*.exports beside /etc/exports, and that
  # directory points here: the exports come from the launcher's table at boot
  # rather than from this configuration, and nfs-server's own `exportfs -r`
  # on a restart finds them again instead of dropping them.
  exportsDir = "/run/vm-shares-exports";

  # Where QEMU's user-mode network presents the Mac. The launcher forwards two
  # loopback ports on the Mac to nfsd and mountd in here, and slirp opens the
  # guest end of each forwarded connection from this address, from whatever
  # unreserved port the Mac's side used - hence `insecure`.
  hostAddress = "10.0.2.2";

  # Pinned because the launcher forwards it by number: guest_mountd_port in
  # packages/mbp-apple-silicon-qemu-vm.nix. The two must agree. nfsd itself is
  # on 2049, which needs no pinning.
  mountdPort = 20048;

  # Mounts the launcher's manifest and checks its version; leaves its path in
  # $manifest, or exits 0 when this boot has none. Shared by the export and
  # mount services, which may start in either order.
  readManifest = ''
    manifest="${manifestMount}/manifest.json"

    if ! mountpoint -q "${manifestMount}"; then
      mkdir -p "${manifestMount}"
      # No device is not a failure: it is what every boot of a VM started
      # with an empty mapping table looks like. A mount the other service
      # made meanwhile is fine too.
      if ! mount -t 9p -o trans=virtio,version=9p2000.L,cache=none,msize=512000,ro \
        ${manifestTag} "${manifestMount}" 2>/dev/null && ! mountpoint -q "${manifestMount}"; then
        echo "no ${manifestTag} 9p device; this boot shares nothing with the host"
        exit 0
      fi
    fi

    if [[ ! -e "$manifest" ]]; then
      echo "${manifestTag} carries no manifest.json; sharing nothing" >&2
      exit 0
    fi

    # Version 1 was the other direction: the guest mounting the Mac's
    # directories. Exporting what an old launcher meant as mount points would
    # hand the Mac empty directories, so refuse and say which side is stale.
    version=$(jq -r '.version' "$manifest")
    if [[ "$version" != 2 ]]; then
      echo "the launcher wrote a version $version manifest; this guest needs version 2." >&2
      echo "Update the launcher on the Mac." >&2
      exit 1
    fi
  '';

  # The Mac's own directories, exported by its nfsd (provision-mac sets that
  # up) and listed in the manifest's host_shares. The Mac serves every request
  # as its user, which is this guest's user too (same uid, hostUid), so the
  # files read as this account's own on both sides.
  #
  # hard: the Mac runs this VM, so its nfsd is never gone while the guest is
  # up, and a write that fails half way is worse than one that waits. The
  # manifest's nfs_port is the launcher's relay to that nfsd, not nfsd
  # itself: macOS nfsd leaves a connection this client closes half open, and
  # a hard mount waits on it forever. nolock: the Mac's lockd would have to
  # call back into the guest, which slirp does not route; locks stay local.
  # actimeo=5 as on the Mac's side.
  mountHostShares = pkgs.writeShellApplication {
    name = "vm-mount-host-shares";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.nfs-utils
      pkgs.util-linux
    ];
    text = ''
      ${readManifest}

      if [[ $(jq '.host_shares // [] | length' "$manifest") == 0 ]]; then
        echo "the host shares none of its own directories"
        exit 0
      fi
      address=$(jq -r '.host_nfs.address' "$manifest")
      nfs_port=$(jq -r '.host_nfs.nfs_port' "$manifest")
      mountd_port=$(jq -r '.host_nfs.mountd_port' "$manifest")
      if [[ ! "$nfs_port" =~ ^[0-9]+$ || ! "$mountd_port" =~ ^[0-9]+$ ]]; then
        echo "the manifest names no usable NFS ports for the host ($nfs_port, $mountd_port)" >&2
        exit 1
      fi
      options="vers=3,proto=tcp,port=$nfs_port,mountport=$mountd_port,mountproto=tcp,nolock,hard,actimeo=5"

      failed=0
      while IFS=$'\x1f' read -r host guest mode; do
        [[ -n "$guest" ]] || continue
        if [[ "$guest" != /* || "$guest" =~ [[:space:]] || "$host" != /* ]]; then
          echo "$host -> $guest: paths must be absolute, the guest's without whitespace; not mounting it" >&2
          failed=1
          continue
        fi
        case "$mode" in
          ro | rw) ;;
          *)
            echo "$guest: mode must be ro or rw, not $mode; not mounting it" >&2
            failed=1
            continue
            ;;
        esac

        if mountpoint -q "$guest"; then
          if [[ $(findmnt -n -o SOURCE --mountpoint "$guest") == "$address:$host" ]]; then
            echo "the host's $host is already mounted at $guest"
            continue
          fi
          echo "$guest already has something else mounted on it; not mounting the host's $host" >&2
          failed=1
          continue
        fi
        if [[ ! -d "$guest" ]]; then
          mkdir -p "$guest"
          chown "${primaryUser}:" "$guest"
        fi
        # Mounting over files would hide them, and whatever used them would
        # silently start using the host's copy instead.
        if [[ -n $(find "$guest" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
          echo "$guest is not empty; refusing to hide it behind the host's $host" >&2
          failed=1
          continue
        fi

        opts=$options
        [[ "$mode" == ro ]] && opts="$opts,ro"
        mounted=0
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          if mount.nfs "$address:$host" "$guest" -o "$opts"; then
            mounted=1
            break
          fi
          sleep 3
        done
        if (( mounted )); then
          echo "mounted the host's $host at $guest ($mode)"
        else
          echo "could not mount the host's $host at $guest" >&2
          failed=1
        fi
      done < <(jq -r '
        .host_shares[]
        | [.host, .guest, .mode]
        | join("\u001f")
      ' "$manifest")

      exit "$failed"
    '';
  };

  unmountHostShares = pkgs.writeShellApplication {
    name = "vm-unmount-host-shares";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      findmnt -rn -t nfs -o TARGET,SOURCE | while read -r target source; do
        if [[ "$source" == ${hostAddress}:* ]]; then
          umount "$target" || umount -l "$target"
        fi
      done
    '';
  };

  exportShares = pkgs.writeShellApplication {
    name = "vm-export-shares";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.nfs-utils
      pkgs.util-linux
    ];
    text = ''
      ${readManifest}

      # all_squash with the guest account as the anonymous identity: whoever
      # the Mac says it is, the guest acts as its own user, so nothing written
      # from the Mac ends up owned by a uid or gid the guest does not have (the
      # Mac sends its staff gid, 20). sync because a write the Mac was told is
      # done should survive the guest going down; the Mac writes rarely, so it
      # costs little.
      uid=$(id -u ${primaryUser})
      gid=$(id -g ${primaryUser})
      options="insecure,no_subtree_check,sync,all_squash,anonuid=$uid,anongid=$gid"

      mkdir -p "${exportsDir}"
      staged=$(mktemp -p "${exportsDir}" .vm-shares.XXXXXX)
      trap 'rm -f "$staged"' EXIT

      failed=0
      # A unit separator rather than a tab, which bash counts as IFS
      # whitespace and would collapse runs of.
      while IFS=$'\x1f' read -r host guest mode; do
        [[ -n "$guest" ]] || continue

        # The launcher checks all of these before it writes the manifest, so
        # reaching one means the two halves disagree about what a mapping is.
        if [[ "$guest" != /* ]]; then
          echo "$guest is not absolute; not exporting it" >&2
          failed=1
          continue
        fi
        # exports(5) separates fields with whitespace.
        if [[ "$guest" =~ [[:space:]] ]]; then
          echo "$guest contains whitespace, which exports(5) cannot carry; not exporting it" >&2
          failed=1
          continue
        fi
        case "$mode" in
          ro | rw) ;;
          *)
            echo "$guest: mode must be ro or rw, not $mode; not exporting it" >&2
            failed=1
            continue
            ;;
        esac

        if [[ ! -d "$guest" ]]; then
          mkdir -p "$guest"
          chown "${primaryUser}:" "$guest"
        fi

        # The point of the direction is that the data sits on this guest's own
        # disk. Exporting a network mount would re-export someone else's
        # filesystem, with both their latency and ours.
        fstype=$(findmnt -n -o FSTYPE --target "$guest")
        case "$fstype" in
          9p | nfs | nfs4 | virtiofs | cifs | smb3 | fuse.*)
            echo "$guest is on $fstype, not on this guest's disk; not exporting it" >&2
            failed=1
            continue
            ;;
        esac

        printf '%s %s(%s,%s)\n' "$guest" "${hostAddress}" "$mode" "$options" >>"$staged"
        echo "exporting $guest to the host as $host ($mode)"
      done < <(jq -r '
        .shares[]
        | [.host, .guest, .mode]
        | join("\u001f")
      ' "$manifest")

      chmod 0644 "$staged"
      mv "$staged" "${exportsDir}/vm-shares.exports"
      exportfs -ra

      exit "$failed"
    '';
  };
in
{
  # Only the manifest still arrives over 9p. It autoloads through its module
  # alias when the first mount asks for the virtio transport, but that is the
  # earliest thing in the boot that does and nothing is gained from finding a
  # missing module then.
  boot.kernelModules = [
    "9p"
    "9pnet_virtio"
  ];

  # See hostUid. NixOS leaves an existing account's uid alone; forced-uid.nix
  # says what to run when the account predates this.
  dev.johnrinehart.users.forceUid = {
    username = primaryUser;
    uid = hostUid;
  };

  services.nfs.server = {
    enable = true;
    inherit mountdPort;
  };

  environment.etc."exports.d".source = exportsDir;
  systemd.tmpfiles.rules = [ "d ${exportsDir} 0755 root root -" ];

  # With user-mode networking nothing but the Mac reaches this guest, and the
  # Mac only through the launcher's forwards on its own loopback. The exports
  # themselves accept no client but ${hostAddress}.
  networking.firewall.allowedTCPPorts = [
    2049
    mountdPort
  ];

  systemd.services.vm-shares = {
    description = "Export the guest directories the host mounts over NFS";
    wantedBy = [ "multi-user.target" ];
    wants = [ "nfs-server.service" ];
    after = [
      "local-fs.target"
      "nfs-server.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe exportShares;
      TimeoutStartSec = "60s";
    };
  };

  systemd.services.vm-host-shares = {
    description = "Mount the directories the host exports over NFS";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "local-fs.target"
      "network-online.target"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe mountHostShares;
      ExecStop = lib.getExe unmountHostShares;
      TimeoutStartSec = "90s";
    };
  };
}
