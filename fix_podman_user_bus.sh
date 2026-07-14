#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Fix rootless Podman user bus/session issues on RHEL hosts.

Usage:
  sudo ./fix_podman_user_bus.sh -u <remote_user> [options]

Options:
  -u, --user USER            Target non-root user (required)
      --subid-start N        Start ID for /etc/subuid and /etc/subgid (default: 100000)
      --subid-range N        Range size for /etc/subuid and /etc/subgid (default: 65536)
      --enable-podman-socket Enable and start podman.socket in user scope
      --registry-user USER   Optional registry.redhat.io username
      --registry-pass PASS   Optional registry.redhat.io password
      --registry-login       Attempt registry.redhat.io login if credentials are provided
  -h, --help                 Show this help

Examples:
  sudo ./fix_podman_user_bus.sh -u admin --enable-podman-socket
  sudo ./fix_podman_user_bus.sh -u admin --registry-login --registry-user myuser --registry-pass mypass
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

upsert_subid() {
  local file="$1"
  local user="$2"
  local start="$3"
  local range="$4"

  [[ -f "$file" ]] || touch "$file"

  if grep -qE "^${user}:" "$file"; then
    sed -i "s/^${user}:.*/${user}:${start}:${range}/" "$file"
  else
    printf '%s:%s:%s\n' "$user" "$start" "$range" >> "$file"
  fi

  chmod 0644 "$file"
}

run_as_user() {
  local user="$1"
  shift

  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$user" -- "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -u "$user" "$@"
  else
    die "Neither runuser nor sudo is available for user context execution"
  fi
}

wait_for_bus() {
  local uid="$1"
  local timeout="${2:-30}"
  local waited=0
  local bus="/run/user/${uid}/bus"

  while [[ ! -S "$bus" ]]; do
    if [[ "$waited" -ge "$timeout" ]]; then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done

  return 0
}

TARGET_USER=""
SUBID_START="100000"
SUBID_RANGE="65536"
ENABLE_PODMAN_SOCKET="false"
DO_REGISTRY_LOGIN="false"
REGISTRY_USER=""
REGISTRY_PASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)
      TARGET_USER="$2"
      shift 2
      ;;
    --subid-start)
      SUBID_START="$2"
      shift 2
      ;;
    --subid-range)
      SUBID_RANGE="$2"
      shift 2
      ;;
    --enable-podman-socket)
      ENABLE_PODMAN_SOCKET="true"
      shift
      ;;
    --registry-user)
      REGISTRY_USER="$2"
      shift 2
      ;;
    --registry-pass)
      REGISTRY_PASS="$2"
      shift 2
      ;;
    --registry-login)
      DO_REGISTRY_LOGIN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[[ -n "$TARGET_USER" ]] || {
  usage
  die "--user is required"
}

[[ "$EUID" -eq 0 ]] || die "Run as root (or with sudo)."

require_cmd id
require_cmd loginctl
require_cmd systemctl
require_cmd podman

id "$TARGET_USER" >/dev/null 2>&1 || die "User does not exist: $TARGET_USER"
[[ "$TARGET_USER" != "root" ]] || die "Target user must be non-root"

TARGET_UID="$(id -u "$TARGET_USER")"
XDG_RUNTIME_DIR="/run/user/${TARGET_UID}"
DBUS_ADDR="unix:path=${XDG_RUNTIME_DIR}/bus"

log "Configuring /etc/subuid and /etc/subgid for ${TARGET_USER}"
upsert_subid /etc/subuid "$TARGET_USER" "$SUBID_START" "$SUBID_RANGE"
upsert_subid /etc/subgid "$TARGET_USER" "$SUBID_START" "$SUBID_RANGE"

log "Enabling linger for ${TARGET_USER}"
loginctl enable-linger "$TARGET_USER" >/dev/null 2>&1 || warn "loginctl enable-linger failed"

log "Starting user manager user@${TARGET_UID}.service"
systemctl start "user@${TARGET_UID}.service" >/dev/null 2>&1 || warn "Could not start user manager service"

log "Waiting for user DBus socket ${XDG_RUNTIME_DIR}/bus"
if ! wait_for_bus "$TARGET_UID" 30; then
  die "User DBus socket did not appear at ${XDG_RUNTIME_DIR}/bus"
fi

log "Running podman system migrate for ${TARGET_USER}"
run_as_user "$TARGET_USER" env \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
  podman system migrate >/dev/null 2>&1 || warn "podman system migrate returned non-zero"

if [[ "$ENABLE_PODMAN_SOCKET" == "true" ]]; then
  log "Enabling podman.socket for ${TARGET_USER}"
  run_as_user "$TARGET_USER" env \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
    systemctl --user enable --now podman.socket >/dev/null 2>&1 || warn "Could not enable podman.socket"
fi

if [[ "$DO_REGISTRY_LOGIN" == "true" ]]; then
  if [[ -n "$REGISTRY_USER" && -n "$REGISTRY_PASS" ]]; then
    log "Logging into registry.redhat.io as ${TARGET_USER}"
    run_as_user "$TARGET_USER" env \
      XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
      DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
      bash -c "printf '%s\n' \"$REGISTRY_PASS\" | podman login registry.redhat.io --username \"$REGISTRY_USER\" --password-stdin" \
      >/dev/null 2>&1 || warn "registry.redhat.io login failed"
  else
    warn "--registry-login was requested but --registry-user/--registry-pass were not both provided"
  fi
fi

log "Validation: podman info as ${TARGET_USER}"
run_as_user "$TARGET_USER" env \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
  podman info >/dev/null 2>&1 || warn "podman info failed; inspect user session and podman config"

cat <<EOF

Done.

Recommended Ansible extra vars:
  -e ansible_user=${TARGET_USER}
  -e ansible_user_uid=${TARGET_UID}

If your workflow still fails, verify:
  ls -l ${XDG_RUNTIME_DIR}/bus
  sudo -u ${TARGET_USER} XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} DBUS_SESSION_BUS_ADDRESS=${DBUS_ADDR} systemctl --user status podman.socket

EOF
