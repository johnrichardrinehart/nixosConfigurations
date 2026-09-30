# How long /tmp keeps files nobody touches.
#
# macOS's own cleaner (the com.apple.tmp_cleaner daemon, running
# /usr/libexec/tmp_cleaner daily at midnight) deletes every file under /tmp
# whose access, modification and change times are all more than 3 days old.
# The 3 is written into that script, which lives on the sealed system volume
# and reads no configuration, so it cannot be adjusted in place. When enabled,
# this module disables the Apple daemon (the setting persists across reboots)
# and runs the same cleaning from its own daemon with its own age limit.
#
# Disabled (the default), it changes nothing, except to undo its own earlier
# work: if it once disabled the Apple daemon, that daemon is enabled again.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkEnableOption mkOption types;
  cfg = config.dev.johnrinehart.mbp-host.tmpCleaner;
  appleJob = "system/com.apple.tmp_cleaner";
  applePlist = "/System/Library/LaunchDaemons/com.apple.tmp_cleaner.plist";
  # Records that this module (not the user) disabled the Apple daemon, so
  # that disabling the module only ever reverts its own change.
  marker = "/var/db/dev.johnrinehart.tmp-cleaner.disabled-apple";

  # /usr/libexec/tmp_cleaner with `days` in place of 3. BSD find, for -dx
  # and -fstype local; the ignore list is Apple's.
  cleaner = pkgs.writeShellScript "tmp-cleaner" ''
    age=+${toString cfg.days}
    ignore=(
      ! -name '.X*-lock' ! -name .X11-unix ! -name .ICE-unix ! -name .font-unix
      ! -name .XIM-unix ! -name quota.user ! -name quota.group
    )
    echo "Removing temporary files untouched for ${toString cfg.days} days:"
    cd /tmp || exit 0
    {
      /usr/bin/find -dx . -fstype local -type f \
        -atime "$age" -mtime "$age" -ctime "$age" "''${ignore[@]}" -delete -print
      /usr/bin/find -dx . -fstype local ! -name . -type d \
        -empty -mtime "$age" ! -name '.vfs_rsrc_streams_*' "''${ignore[@]}" -delete -print
    } | /usr/bin/sed 's,^\.,  /tmp,'
  '';

  appleDisabled = ''launchctl print-disabled system | grep -q '"com.apple.tmp_cleaner" => disabled' '';
in
{
  options.dev.johnrinehart.mbp-host.tmpCleaner = {
    enable = mkEnableOption ''
      replacing macOS's 3-day /tmp cleaner with one that keeps untouched
      files for `days` days
    '';
    days = mkOption {
      type = types.ints.positive;
      default = 7;
      description = "Days a file under /tmp may go unread and unmodified before it is deleted.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      launchd.daemons.tmp-cleaner.serviceConfig = {
        ProgramArguments = [ "${cleaner}" ];
        StartCalendarInterval = [ { Hour = 0; } ];
        LowPriorityIO = true;
        Nice = 1;
        StandardOutPath = "/var/log/tmp-cleaner.log";
        StandardErrorPath = "/var/log/tmp-cleaner.log";
      };

      dev.johnrinehart.provisionMac.summary.tmp-cleaner =
        "/tmp keeps untouched files ${toString cfg.days} days (${config.launchd.labelPrefix}.tmp-cleaner; ${appleJob} disabled)";

      # `disable` only takes effect when the job is next loaded, so the
      # loaded Apple job is also booted out; SIP may refuse that, in which
      # case it runs until the next reboot.
      system.activationScripts.postActivation.text = lib.mkAfter ''
        if ! ${appleDisabled}; then
          echo "disabling macOS's 3-day /tmp cleaner (${appleJob})..." >&2
          launchctl disable ${appleJob}
          touch ${marker}
        fi
        launchctl bootout ${appleJob} 2>/dev/null || true
      '';
    })

    (lib.mkIf (!cfg.enable) {
      system.activationScripts.postActivation.text = lib.mkAfter ''
        if [[ -e ${marker} ]]; then
          echo "re-enabling macOS's 3-day /tmp cleaner (${appleJob})..." >&2
          launchctl enable ${appleJob}
          launchctl bootstrap system ${applePlist} 2>/dev/null || true
          rm -f ${marker}
        fi
      '';
    })
  ];
}
