#!/usr/bin/env bash
set -euo pipefail

program=${TAILSCALE_NIX_BUILDERS_PROGRAM:?TAILSCALE_NIX_BUILDERS_PROGRAM is required}
test_root=$(mktemp -d)
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

mock_bin=$test_root/bin
state_dir=$test_root/state
machines_file=$test_root/etc/nix/machines
users_file=$test_root/users.json
ssh_key=$test_root/id_builder
status_file=$test_root/status.json
pingable_file=$test_root/pingable
ssh_failures_file=$test_root/ssh-failures
nix_failures_file=$test_root/nix-failures
remote_systems_file=$test_root/remote-systems
calls_file=$test_root/calls
fallback_ssh_user=builder
features=benchmark,big-parallel,kvm,nixos-test
host_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICnbQJjGcaA1KSw/6Rnqqg3e4lp4RmHUJoWiGsWBNe5U'
host_key_base64=$(printf '%s\n' "$host_key" | base64 -w0)

mkdir -p "$mock_bin"
printf 'test identity\n' >"$ssh_key"
chmod 0600 "$ssh_key"
: >"$pingable_file"
: >"$ssh_failures_file"
: >"$nix_failures_file"
: >"$remote_systems_file"
: >"$calls_file"

cat >"$users_file" <<'EOF'
{
  "1001": 1,
  "2002": 2
}
EOF

printf '#!%s\n' "$BASH" >"$mock_bin/tailscale"
cat >>"$mock_bin/tailscale" <<'EOF'
set -euo pipefail
printf 'tailscale %s\n' "$*" >>"$MOCK_CALLS"
case ${1:-} in
  status)
    if [[ ${MOCK_STATUS_FAIL:-0} == 1 ]]; then
      exit 1
    fi
    cat "$MOCK_STATUS"
    ;;
  ping)
    host=${!#}
    grep -Fqx "$host" "$MOCK_PINGABLE"
    ;;
  *)
    exit 2
    ;;
esac
EOF

printf '#!%s\n' "$BASH" >"$mock_bin/ssh"
cat >>"$mock_bin/ssh" <<'EOF'
set -euo pipefail
known_hosts=
while (( $# > 0 )); do
  case $1 in
    -o)
      if [[ $2 == UserKnownHostsFile=* ]]; then
        known_hosts=${2#*=}
      fi
      shift 2
      ;;
    -i)
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      target=$1
      shift
      break
      ;;
  esac
done
: "${target:?missing SSH target}"
: "${known_hosts:?missing known-hosts file}"
printf 'ssh %s\n' "$target" >>"$MOCK_CALLS"
if grep -Fqx "$target" "$MOCK_SSH_FAILURES"; then
  exit 255
fi
remote_system=$(awk -F '\t' -v target="$target" '$1 == target { print $2; found = 1; exit } END { if (!found) exit 1 }' "$MOCK_REMOTE_SYSTEMS")
host=${target#*@}
if [[ ! -s $known_hosts ]]; then
  printf '%s %s\n' "$host" "$MOCK_HOST_KEY" >"$known_hosts"
fi
printf '"%s"\n' "$remote_system"
EOF

printf '#!%s\n' "$BASH" >"$mock_bin/nix"
cat >>"$mock_bin/nix" <<'EOF'
set -euo pipefail
store=
while (( $# > 0 )); do
  if [[ $1 == --store ]]; then
    store=$2
    break
  fi
  shift
done
: "${store:?missing Nix store URI}"
target=${store#ssh-ng://}
target=${target%%\?*}
printf 'nix %s\n' "$target" >>"$MOCK_CALLS"
if grep -Fqx "$target" "$MOCK_NIX_FAILURES"; then
  exit 1
fi
printf 'Store URL: %s\n' "$store"
EOF

chmod +x "$mock_bin/tailscale" "$mock_bin/ssh" "$mock_bin/nix"

export TAILSCALE_BIN=$mock_bin/tailscale
export SSH_BIN=$mock_bin/ssh
export NIX_BIN=$mock_bin/nix
export MOCK_STATUS=$status_file
export MOCK_PINGABLE=$pingable_file
export MOCK_SSH_FAILURES=$ssh_failures_file
export MOCK_NIX_FAILURES=$nix_failures_file
export MOCK_REMOTE_SYSTEMS=$remote_systems_file
export MOCK_CALLS=$calls_file
export MOCK_HOST_KEY=$host_key

run_program() {
  "$program" \
    "$machines_file" \
    "$state_dir" \
    "$users_file" \
    "$ssh_key" \
    "$fallback_ssh_user" \
    4 \
    "$features"
}

assert_machines() {
  local expected=$test_root/expected
  cat >"$expected"
  diff -u "$expected" "$machines_file"
}

cat >"$status_file" <<'EOF'
{
  "User": {
    "1001": {
      "LoginName": "remote.owner@example.com"
    },
    "2002": {
      "LoginName": "PreferredAccount@github"
    },
    "3003": {
      "LoginName": "other@example.com"
    }
  },
  "Peer": {
    "standard": {
      "DNSName": "standard-node.standard-tail.ts.net.",
      "UserID": 1001,
      "Online": true
    },
    "preferred": {
      "DNSName": "preferred-node.preferred-tail.ts.net.",
      "UserID": 9009,
      "AltSharerUserID": 2002,
      "Online": true
    },
    "offline": {
      "DNSName": "offline-node.standard-tail.ts.net.",
      "UserID": 1001,
      "Online": false
    },
    "untrusted": {
      "DNSName": "untrusted-node.other-tail.ts.net.",
      "UserID": 3003,
      "Online": true
    },
    "wrong-system": {
      "DNSName": "wrong-system.standard-tail.ts.net.",
      "UserID": 1001,
      "Online": true
    }
  }
}
EOF
cat >"$pingable_file" <<'EOF'
standard-node.standard-tail.ts.net
preferred-node.preferred-tail.ts.net
wrong-system.standard-tail.ts.net
EOF
cat >"$remote_systems_file" <<'EOF'
builder@standard-node.standard-tail.ts.net	x86_64-linux
preferredaccount@preferred-node.preferred-tail.ts.net	x86_64-linux
builder@wrong-system.standard-tail.ts.net	aarch64-linux
EOF

run_program
assert_machines <<EOF
ssh-ng://preferredaccount@preferred-node.preferred-tail.ts.net x86_64-linux $ssh_key 4 2 $features - $host_key_base64
ssh-ng://builder@standard-node.standard-tail.ts.net x86_64-linux $ssh_key 4 1 $features - $host_key_base64
EOF
[[ $(stat -c %a "$machines_file") == 644 ]]
[[ $(stat -c %a "$state_dir/tailscale-status.json") == 600 ]]
if grep -Fq 'untrusted-node.other-tail.ts.net' "$calls_file"; then
  echo "disallowed peer was probed" >&2
  exit 1
fi

original_inode=$(stat -c %i "$machines_file")
run_program
[[ $(stat -c %i "$machines_file") == "$original_inode" ]]

cat >"$status_file" <<'EOF'
{
  "User": {
    "1001": {
      "LoginName": "remote.owner@example.com"
    },
    "2002": {
      "LoginName": "PreferredAccount@github"
    }
  },
  "Peer": {
    "standard": {
      "DNSName": "standard-node.standard-tail.ts.net.",
      "UserID": 1001,
      "Online": true
    },
    "replacement-preferred": {
      "DNSName": "replacement.preferred-tail.ts.net.",
      "UserID": 9009,
      "AltSharerUserID": 2002,
      "Online": true
    },
    "replacement-standard": {
      "DNSName": "replacement.standard-tail.ts.net.",
      "UserID": 1001,
      "Online": true
    }
  }
}
EOF
cat >"$pingable_file" <<'EOF'
standard-node.standard-tail.ts.net
replacement.preferred-tail.ts.net
replacement.standard-tail.ts.net
EOF
cat >"$ssh_failures_file" <<'EOF'
builder@standard-node.standard-tail.ts.net
EOF
cat >"$nix_failures_file" <<'EOF'
builder@replacement.standard-tail.ts.net
EOF
cat >"$remote_systems_file" <<'EOF'
builder@standard-node.standard-tail.ts.net	x86_64-linux
preferredaccount@replacement.preferred-tail.ts.net	x86_64-linux
builder@replacement.standard-tail.ts.net	x86_64-linux
EOF

run_program
assert_machines <<EOF
ssh-ng://preferredaccount@replacement.preferred-tail.ts.net x86_64-linux $ssh_key 4 2 $features - $host_key_base64
EOF

: >"$ssh_failures_file"
: >"$nix_failures_file"
printf 'standard-node.standard-tail.ts.net\n' >"$pingable_file"
run_program
assert_machines <<EOF
ssh-ng://builder@standard-node.standard-tail.ts.net x86_64-linux $ssh_key 4 1 $features - $host_key_base64
EOF

export MOCK_STATUS_FAIL=1
run_program
[[ ! -s $machines_file ]]

printf 'tailscale-nix-builders tests passed\n'
