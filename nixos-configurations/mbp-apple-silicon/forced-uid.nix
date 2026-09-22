{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.users.forceUid;

  # nixpkgs keeps uids below 1000 for system accounts and asserts that a normal
  # user never holds one:
  #
  #   assertion = user.isNormalUser && user.uid != null -> user.uid >= 1000;
  #
  # Every override below is a consequence of that one assertion. A uid inside
  # the normal range needs none of it, so the option stays out of the way and
  # only pins the number.
  belowNormalRange = cfg != null && cfg.uid < 1000;
in
{
  options.dev.johnrinehart.users.forceUid = lib.mkOption {
    default = null;
    example = {
      username = "john";
      uid = 501;
    };
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          username = lib.mkOption {
            type = lib.types.str;
            description = "Account whose uid is pinned.";
          };
          uid = lib.mkOption {
            type = lib.types.ints.unsigned;
            description = "The uid to pin it to.";
          };
        };
      }
    );
    description = ''
      Pin an account to a particular uid, including one below the normal range.

      This exists for filesystems that carry ownership across a boundary
      without translating it. A virtio-9p export under security_model=none
      reports the host's uid unchanged, so a guest account writes to the share
      only when it answers to the same number. The alternative - laying bindfs
      over the mount to shift ownership - costs a FUSE round trip per path
      component on every operation, measured at roughly five times the
      underlying 9p cost.

      Below 1000 this cannot simply set the uid: nixpkgs asserts that a normal
      user has a uid of at least 1000, so the account has to be declared a
      system user instead. That flips off the six defaults isNormalUser
      supplies, which are restored here as defaults so anything set explicitly
      elsewhere still wins, and it drops the account out of any list derived by
      filtering on isNormalUser - trusted-users among them - which is put back.

      NixOS does not renumber an account that already exists; it warns and
      carries on. An installed system therefore needs a one-time usermod, and
      the activation check below says so with the exact commands.
    '';
  };

  config = lib.mkIf (cfg != null) (
    lib.mkMerge [
      { users.users.${cfg.username}.uid = cfg.uid; }

      (lib.mkIf belowNormalRange {
        users.users.${cfg.username} = {
          isNormalUser = lib.mkForce false;
          isSystemUser = true;

          # The defaults isNormalUser would have supplied, restated at the same
          # priority it used, so an explicit setting elsewhere still wins and
          # the account is otherwise indistinguishable from a normal one.
          group = lib.mkDefault "users";
          createHome = lib.mkDefault true;
          home = lib.mkDefault "${config.users.defaultUserHome}/${cfg.username}";
          homeMode = lib.mkDefault "700";
          useDefaultShell = lib.mkDefault true;
          autoSubUidGidRange = lib.mkDefault true;
        };

        # Derived by filtering users.users on isNormalUser, which this account
        # no longer satisfies. Recomputed rather than appended to because the
        # option carries no type and so has no list merge to rely on.
        dev.johnrinehart.nix.trusted-users = lib.mkDefault (
          builtins.attrNames (lib.filterAttrs (_: v: v.isNormalUser) config.users.users)
          ++ [
            cfg.username
            "@wheel"
          ]
        );

        # update-users-groups.pl refuses to change an existing account's uid -
        # it prints "warning: not applying UID change" and moves on - so a
        # system that predates this option keeps the uid it was allocated and
        # the share silently stays unwritable. Say so where it will be seen,
        # with the commands that fix it.
        system.activationScripts.forceUid = {
          deps = [ "users" ];
          text = ''
            forced_actual=$(${pkgs.coreutils}/bin/id -u ${cfg.username} 2>/dev/null || true)
            if [ -n "$forced_actual" ] && [ "$forced_actual" != "${toString cfg.uid}" ]; then
              echo "warning: ${cfg.username} is uid $forced_actual, not the configured ${toString cfg.uid}." >&2
              echo "         NixOS does not renumber an existing account. To apply it:" >&2
              echo "           usermod -u ${toString cfg.uid} ${cfg.username}" >&2
              echo "           chown -R ${toString cfg.uid} ${config.users.users.${cfg.username}.home}" >&2
              echo "         Until then anything relying on the uid matching will not work." >&2
            fi
          '';
        };
      })
    ]
  );
}
