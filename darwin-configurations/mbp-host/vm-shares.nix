# Directories shared between this Mac and the mbp-apple-silicon guest, in
# both directions, over NFSv3.
#
# Each share's data lives on one side and is mounted on the other:
#
#   source = "guest"  the guest exports its own directory and the launcher
#                     mounts it on this Mac (vm-shares.service in the guest).
#   source = "host"   this Mac exports its own directory and the guest mounts
#                     it (vm-host-shares.service in the guest).
#
# The table becomes ~/guest-vm-fs-mappings.json, which the launcher reads at
# every start and forwards to the guest in its share manifest. For
# source = "host" shares this module also runs the Mac's nfsd: /etc/exports
# and the /etc/nfs.conf settings below, rewritten on every activation. The
# guest reaches nfsd through a relay the launcher runs, which closes each
# connection properly when the guest closes it; macOS nfsd does not.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.dev.johnrinehart.mbp-host.vmShares;
  user = config.system.primaryUser;

  hostShares = lib.filter (share: share.source == "host") cfg;

  # The guest mounts through QEMU's user-mode network, which delivers its
  # connections to this Mac's loopback from unprivileged ports. The mountd
  # port is pinned so the guest can name it rather than ask the portmapper;
  # packages/mbp-apple-silicon-qemu-vm.nix reads the live value from rpcinfo
  # regardless.
  mountdPort = 20048;
  nfsConf = ''
    # Managed by nixosConfigurations darwin-configurations/mbp-host/vm-shares.nix.
    nfs.server.require_resv_port = 0
    nfs.server.mount.require_resv_port = 0
    nfs.server.mount.port = ${toString mountdPort}
  '';
in
{
  options.dev.johnrinehart.mbp-host.vmShares = mkOption {
    description = "Directories shared with the mbp-apple-silicon guest over NFS.";
    default = [ ];
    type = types.listOf (
      types.submodule {
        options = {
          host = mkOption {
            type = types.strMatching "/[^[:space:]]*";
            description = "Absolute path on this Mac: mount point, or exported directory.";
          };
          guest = mkOption {
            type = types.strMatching "/[^[:space:]]*";
            description = "Absolute path in the guest: exported directory, or mount point.";
          };
          mode = mkOption {
            type = types.enum [
              "rw"
              "ro"
            ];
            default = "rw";
          };
          source = mkOption {
            type = types.enum [
              "guest"
              "host"
            ];
            default = "guest";
            description = "Which side the data lives on and is exported from.";
          };
        };
      }
    );
  };

  config = {
    home-manager.users.${user}.home.file."guest-vm-fs-mappings.json".text = builtins.toJSON {
      shares = map (share: {
        inherit (share)
          host
          guest
          mode
          source
          ;
        transport = "nfs";
      }) cfg;
    };

    # /etc/exports and /etc/nfs.conf are written as real files: nfsd reads
    # them itself and is sandboxed, so a link into the store is not something
    # to depend on. With no host shares nfsd is turned off again.
    system.activationScripts.postActivation.text = lib.mkAfter (
      if hostShares == [ ] then
        ''
          if [[ -s /etc/exports ]] && grep -q 'vm-shares.nix' /etc/exports; then
            echo "no VM host shares; stopping nfsd" >&2
            : >/etc/exports
            /sbin/nfsd disable || true
          fi
        ''
      else
        ''
          echo "setting up NFS exports for the VM guest..." >&2
          uid=$(id -u ${lib.escapeShellArg user})
          gid=$(id -g ${lib.escapeShellArg user})
          ${lib.concatMapStrings (share: ''
            if [[ ! -d ${lib.escapeShellArg share.host} ]]; then
              install -d -m 0700 -o "$uid" -g "$gid" ${lib.escapeShellArg share.host}
            fi
          '') hostShares}

          # Every request is served as the primary user whoever the guest says
          # it is, and only the loopback (where QEMU delivers the guest) may
          # mount.
          exports=$(mktemp)
          {
            echo '# Managed by nixosConfigurations darwin-configurations/mbp-host/vm-shares.nix.'
            ${lib.concatMapStrings (share: ''
              printf '%s -mapall=%s:%s%s localhost\n' ${lib.escapeShellArg share.host} "$uid" "$gid" ${
                if share.mode == "ro" then "' -ro'" else "''"
              }
            '') hostShares}
          } >"$exports"

          changed=0
          if ! cmp -s "$exports" /etc/exports; then
            install -m 0644 "$exports" /etc/exports
            changed=1
          fi
          rm -f "$exports"
          if ! cmp -s <(printf '%s' ${lib.escapeShellArg nfsConf}) /etc/nfs.conf; then
            printf '%s' ${lib.escapeShellArg nfsConf} >/etc/nfs.conf
            changed=1
          fi

          if ! /sbin/nfsd status | grep -q 'is running'; then
            /sbin/nfsd enable
          elif (( changed )); then
            /sbin/nfsd restart
          fi
          # checkexports also asks whether the nfsd daemon's sandbox could
          # read each path, and says no for directories in a home folder. The
          # kernel NFS server does the serving and is not bound by that, so
          # those lines are only warnings; any other complaint is fatal.
          if ! report=$(/sbin/nfsd checkexports 2>&1); then
            if grep -v -e 'sandbox_check failed' -e "can't verify exports permissions" <<<"$report" | grep -q .; then
              printf '%s\n' "$report" >&2
              echo "error: nfsd rejected /etc/exports" >&2
              exit 1
            fi
            printf 'warning (harmless): %s\n' "$report" >&2
          fi
        ''
    );
  };
}
