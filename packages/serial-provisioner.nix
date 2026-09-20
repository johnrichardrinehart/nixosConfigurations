{
  guestFlake,
  writeText,
}:
# Drives the installer over the serial console: waits for its shell, brings up
# networking, runs this flake's generated Disko script, and hands the session
# back to the caller.
#
# Every wait is bounded. The installer talks only over the serial line, so a
# guest that dies before reaching its shell, or a Disko run that wedges, would
# otherwise leave the launcher blocked forever with nothing on screen. Each
# phase instead gives up at its deadline and points at the captured log.
writeText "mbp-apple-silicon-provision.expect" ''
  set network [lindex $argv 0]
  set provision [lindex $argv 1]
  set marker [lindex $argv 2]
  set serial_log [lindex $argv 3]
  set boot_timeout [lindex $argv 4]
  set provision_timeout [lindex $argv 5]
  set command [lrange $argv 6 end]

  # The installer's prompt, allowing for the colour escapes bash wraps it in.
  set prompt {nixos@nixos:[^\r\n]*\$(\e\[[0-9;]*[a-zA-Z])* $}

  # Wake up often so a deadline is noticed promptly, but measure the deadlines
  # themselves against the wall clock: exp_continue restarts expect's own timer
  # on every pass, so `timeout` alone can never bound a polling loop.
  set poll 5

  proc abandon {status message} {
    global serial_log
    send_user "\n$message\n"
    send_user "The captured serial output is at $serial_log.\n"
    catch {exec kill -TERM [exp_pid]}
    catch {close}
    catch {wait}
    exit $status
  }

  # Waits for the installer's prompt, reporting progress every 30 seconds. A
  # soft wait warns and carries on instead of tearing the VM down.
  proc await_prompt {what limit {soft 0}} {
    global timeout poll prompt
    set started [clock seconds]
    set next_status 30
    set timeout $poll
    expect {
      -re $prompt {}
      timeout {
        set elapsed [expr {[clock seconds] - $started}]
        if {$elapsed >= $limit} {
          if {$soft} {
            send_user "\nGave up waiting for $what after $elapsed seconds; continuing.\n"
            return
          }
          abandon 124 "Timed out after $elapsed seconds waiting for $what."
        }
        if {$elapsed >= $next_status} {
          send_user "Still waiting for $what ($elapsed seconds)...\n"
          incr next_status 30
        }
        exp_continue
      }
      eof {
        set result [wait]
        exit [lindex $result 3]
      }
    }
  }

  # -a captures the boot phase too, which log_user 0 keeps off the terminal;
  # -noappend starts every run with a fresh log.
  log_file -a -noappend $serial_log
  log_user 0
  spawn -noecho {*}$command
  send_user "Starting VM; serial output is being saved to $serial_log.\n"
  await_prompt "the NixOS installer shell" $boot_timeout

  send_user "\nNixOS installer ready; waiting for guest networking.\n"
  # Every command is sent as a single line and the next one only after the
  # prompt returns: the guest console drops whatever is still queued when a
  # command finishes, so a pasted multi-line script loses everything past
  # its first slow line.
  send -- "$network\r"
  await_prompt "guest networking" $boot_timeout

  log_user 1
  send_user "\nStarting Disko provisioning.\n"
  send -- "$provision\r"
  set started [clock seconds]
  set next_status 120
  set timeout $poll
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
    timeout {
      set elapsed [expr {[clock seconds] - $started}]
      if {$elapsed >= $provision_timeout} {
        abandon 124 "Disko provisioning reported nothing within $elapsed seconds."
      }
      if {$elapsed >= $next_status} {
        send_user "\nStill provisioning ($elapsed seconds)...\n"
        incr next_status 120
      }
      exp_continue
    }
    eof {
      set result [wait]
      exit [lindex $result 3]
    }
  }

  # Provisioning has already reported by this point, so these two only tidy the
  # terminal for the interactive session; never tear the VM down over them.
  await_prompt "the installer shell" 60 1
  send -- "stty sane\r"
  await_prompt "the terminal to settle" 60 1
  interact
  set result [wait]
  exit [lindex $result 3]
''
