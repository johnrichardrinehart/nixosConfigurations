{
  guestFlake,
  writeText,
}:
# Drives the installer over the serial console: waits for its shell, brings up
# networking, runs this flake's generated Disko script, and hands the session
# back to the caller.
writeText "mbp-apple-silicon-provision.expect" ''
  set timeout 5
  set network [lindex $argv 0]
  set provision [lindex $argv 1]
  set marker [lindex $argv 2]
  set command [lrange $argv 3 end]
  log_user 0
  spawn -noecho {*}$command
  send_user "Starting VM; suppressing boot-time terminal queries while waiting for the installer shell.\n"
  expect {
    -re {nixos@nixos:[^\r\n]*\$(\e\[[0-9;]*[a-zA-Z])* $} {}
    timeout {
      send_user "Still waiting for the NixOS installer shell...\n"
      exp_continue
    }
    eof {
      set result [wait]
      exit [lindex $result 3]
    }
  }
  set timeout -1
  send_user "\nNixOS installer ready; waiting for guest networking.\n"
  # Every command is sent as a single line and the next one only after the
  # prompt returns: the guest console drops whatever is still queued when a
  # command finishes, so a pasted multi-line script loses everything past
  # its first slow line.
  send -- "$network\r"
  expect {
    -re {nixos@nixos:[^\r\n]*\$(\e\[[0-9;]*[a-zA-Z])* $} {}
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
      send_user "\nInstall into /mnt with nixos-install, which builds into the target store:\n"
      send_user "  sudo nixos-install --flake ${guestFlake}#mbp-apple-silicon-bootstrap\n"
      send_user "  sudo nixos-install --flake ${guestFlake}#mbp-apple-silicon\n"
      send_user "\nDo not use nixos-rebuild here: it builds into the installer's own\n"
      send_user "store, which is a RAM disk of about half of MBP_APPLE_VM_MEMORY_MIB.\n"
    }
    -re {__DISKO_PROVISION_STATUS_([0-9]+)__} {
      send_user "\nDisko provisioning failed with status $expect_out(1,string).\n"
    }
    eof {
      set result [wait]
      exit [lindex $result 3]
    }
  }
  expect {
    -re {nixos@nixos:[^\r\n]*\$(\e\[[0-9;]*[a-zA-Z])* $} {}
    eof {
      set result [wait]
      exit [lindex $result 3]
    }
  }
  send -- "stty sane\r"
  expect {
    -re {nixos@nixos:[^\r\n]*\$(\e\[[0-9;]*[a-zA-Z])* $} {}
    eof {
      set result [wait]
      exit [lindex $result 3]
    }
  }
  interact
  set result [wait]
  exit [lindex $result 3]
''
