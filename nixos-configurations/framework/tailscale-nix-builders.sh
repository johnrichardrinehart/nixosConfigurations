# shellcheck shell=bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: tailscale-nix-builders MACHINES_FILE STATE_DIR USERS_FILE SSH_KEY FALLBACK_SSH_USER MAX_JOBS FEATURES
EOF
  exit 2
}

log() {
  printf 'tailscale-nix-builders: %s\n' "$*" >&2
}

if (($# != 7)); then
  usage
fi

machines_file=$1
state_dir=$2
users_file=$3
ssh_key=$4
fallback_ssh_user=$5
max_jobs=$6
supported_features=$7

TAILSCALE_BIN=${TAILSCALE_BIN:-tailscale}
SSH_BIN=${SSH_BIN:-ssh}
SSH_KEYGEN_BIN=${SSH_KEYGEN_BIN:-ssh-keygen}
NIX_BIN=${NIX_BIN:-nix}

if [[ ! $fallback_ssh_user =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
  log "FALLBACK_SSH_USER is not a valid SSH username"
  exit 2
fi
if [[ ! $max_jobs =~ ^[1-9][0-9]*$ ]]; then
  log "MAX_JOBS must be a positive integer"
  exit 2
fi
if [[ ! $supported_features =~ ^[-A-Za-z0-9._+]+(,[-A-Za-z0-9._+]+)*$ ]]; then
  log "FEATURES must be a comma-separated list"
  exit 2
fi
if [[ $ssh_key == *[$'\n\r ?&']* ]]; then
  log "SSH_KEY contains a character that cannot be used in a Nix store URI"
  exit 2
fi

machines_dir=$(dirname -- "$machines_file")
install -d -m 0755 "$machines_dir"
install -d -m 0700 "$state_dir" "$state_dir/known-hosts"

exec 9>"$state_dir/lock"
if ! flock -n 9; then
  log "another refresh is already running"
  exit 0
fi

work_dir=$(mktemp -d "$state_dir/.run.XXXXXX")
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

new_machines=$work_dir/machines
results_dir=$work_dir/results
mkdir "$results_dir"
: >"$new_machines"

publish_machines() {
  local destination_tmp

  chmod 0644 "$new_machines"
  if [[ -f $machines_file && ! -L $machines_file ]] && cmp -s "$new_machines" "$machines_file"; then
    log "machines file unchanged ($(wc -l <"$new_machines") builders)"
    return
  fi

  destination_tmp=$(mktemp "$machines_dir/.machines.XXXXXX")
  install -m 0644 "$new_machines" "$destination_tmp"
  mv -fT "$destination_tmp" "$machines_file"
  log "installed $(wc -l <"$new_machines") builders in $machines_file"
}

fail_closed() {
  log "$1; removing all builders"
  : >"$new_machines"
  publish_machines
  exit 0
}

if [[ ! -r $users_file ]] || ! jq -e '
  type == "object"
  and all(
    to_entries[];
    (.key | test("^[0-9]+$"))
    and (.value | type == "number" and . >= 1 and . == floor)
  )
' "$users_file" >/dev/null; then
  fail_closed "the allowed-user file is invalid"
fi

if [[ ! -r $ssh_key ]]; then
  fail_closed "SSH identity $ssh_key is not readable"
fi

status_file=$work_dir/tailscale-status.json
if ! "$TAILSCALE_BIN" status --json >"$status_file"; then
  fail_closed "tailscale status failed"
fi
if ! jq -e '(.Peer | type == "object") and (.User | type == "object")' "$status_file" >/dev/null; then
  fail_closed "tailscale returned invalid status JSON"
fi

status_destination_tmp=$(mktemp "$state_dir/.tailscale-status.XXXXXX")
install -m 0600 "$status_file" "$status_destination_tmp"
mv -fT "$status_destination_tmp" "$state_dir/tailscale-status.json"

candidates=$work_dir/candidates
if ! jq -r --slurpfile allowed "$users_file" '
  ($allowed[0]) as $users
  | .User as $profiles
  | [
      .Peer[]?
      | select(.Online == true)
      | (.UserID | tostring) as $owner
      | ((.AltSharerUserID // null) | if . == null then null else tostring end) as $sharer
      | (
          if ($sharer != null and $users[$sharer] != null) then $sharer
          elif $users[$owner] != null then $owner
          else empty
          end
        ) as $user_id
      | ($profiles[$user_id].LoginName // "") as $login_name
      | select($login_name | type == "string" and test("^[^\\t\\r\\n]+$"))
      | ((.DNSName // "") | ascii_downcase | rtrimstr(".")) as $dns_name
      | select($dns_name | test(
          "^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*\\.ts\\.net$"
        ))
      | [$user_id, ($users[$user_id] | tostring), $login_name, $dns_name]
    ]
  | unique_by(.[3])
  | sort_by((.[1] | tonumber) * -1, .[0], .[3])
  | .[]
  | @tsv
' "$status_file" >"$candidates"; then
  fail_closed "could not select Tailscale peers"
fi

ssh_user_from_login() {
  local login_name=$1
  local ssh_user=${login_name%%@*}

  ssh_user=${ssh_user,,}
  ssh_user=${ssh_user//[^a-z0-9_-]/}
  if [[ $ssh_user =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    printf '%s\n' "$ssh_user"
  fi
}

probe_builder() {
  local user_id=$1
  local builder_speed_factor=$2
  local login_name=$3
  local dns_name=$4
  local derived_ssh_user
  local host_key
  local host_key_base64
  local known_hosts_file=$state_dir/known-hosts/$dns_name
  local nix_ssh_opts
  local remote_system
  local result_file=$results_dir/$user_id-$dns_name
  local selected_target=
  local ssh_user
  local target
  local -a ssh_users=()
  local -a ssh_options=(
    -o BatchMode=yes
    -o ConnectTimeout=4
    -o ConnectionAttempts=1
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=$known_hosts_file"
    -o GlobalKnownHostsFile=/dev/null
    -o HashKnownHosts=no
    -i "$ssh_key"
  )

  if ! timeout 5s "$TAILSCALE_BIN" ping --until-direct=false --timeout=3s --c 1 "$dns_name" \
    >/dev/null 2>&1; then
    log "skipping $dns_name: Tailscale ping failed"
    return
  fi

  derived_ssh_user=$(ssh_user_from_login "$login_name")
  if [[ -n $derived_ssh_user ]]; then
    ssh_users+=("$derived_ssh_user")
  fi
  if [[ $fallback_ssh_user != "$derived_ssh_user" ]]; then
    ssh_users+=("$fallback_ssh_user")
  fi

  touch "$known_hosts_file"
  chmod 0600 "$known_hosts_file"
  for ssh_user in "${ssh_users[@]}"; do
    target=$ssh_user@$dns_name
    if ! remote_system=$(timeout 8s "$SSH_BIN" "${ssh_options[@]}" "$target" \
      'nix-instantiate --eval --expr builtins.currentSystem' 2>/dev/null); then
      continue
    fi
    if [[ $remote_system != '"x86_64-linux"' ]]; then
      log "skipping $dns_name: remote system is $remote_system"
      return
    fi

    nix_ssh_opts="-o BatchMode=yes -o ConnectTimeout=4 -o ConnectionAttempts=1 -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts_file -o GlobalKnownHostsFile=/dev/null -i $ssh_key"
    if NIX_SSHOPTS=$nix_ssh_opts timeout 12s "$NIX_BIN" \
      --extra-experimental-features nix-command \
      store info --store "ssh-ng://$target?ssh-key=$ssh_key" >/dev/null 2>&1; then
      selected_target=$target
      break
    fi
  done

  if [[ -z $selected_target ]]; then
    log "skipping $dns_name: no derived SSH account exposes an ssh-ng Nix store"
    return
  fi

  host_key=$("$SSH_KEYGEN_BIN" -F "$dns_name" -f "$known_hosts_file" 2>/dev/null |
    awk '!/^#/ && NF >= 3 { print $2 " " $3; exit }')
  if [[ -z $host_key ]]; then
    log "skipping $selected_target: SSH did not record a host key"
    return
  fi
  host_key_base64=$(printf '%s\n' "$host_key" | base64 -w0)

  printf 'ssh-ng://%s x86_64-linux %s %s %s %s - %s\n' \
    "$selected_target" \
    "$ssh_key" \
    "$max_jobs" \
    "$builder_speed_factor" \
    "$supported_features" \
    "$host_key_base64" >"$result_file"
  log "accepted $selected_target"
}

pids=()
while IFS=$'\t' read -r user_id builder_speed_factor login_name dns_name; do
  [[ -n $user_id && -n $builder_speed_factor && -n $login_name && -n $dns_name ]] || continue
  probe_builder "$user_id" "$builder_speed_factor" "$login_name" "$dns_name" &
  pids+=("$!")
done <"$candidates"

for pid in "${pids[@]}"; do
  wait "$pid" || true
done

all_results=$work_dir/all-results
while IFS= read -r result_file; do
  cat "$result_file"
done < <(find "$results_dir" -type f -print | sort) >"$all_results"
sort -k5,5nr -k1,1 "$all_results" >"$new_machines"

publish_machines
