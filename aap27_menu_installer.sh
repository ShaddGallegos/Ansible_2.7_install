#!/usr/bin/env bash
set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "Bash is required to run this script." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

get_user_home() {
  local user_name="$1"
  local home
  home="$(getent passwd "${user_name}" | cut -d: -f6 || true)"
  printf '%s' "${home:-/home/${user_name}}"
}

get_default_admin_home() {
  if [[ ${EUID} -eq 0 ]]; then
    printf '%s' '/home/admin'
    return 0
  fi
  printf '%s' "${HOME:-/home/${USER:-$(whoami)}}"
}

ADMIN_HOME="${AAP_ADMIN_HOME:-$(get_default_admin_home)}"
DOWNLOAD_DIR="${AAP_DOWNLOAD_DIR:-${ADMIN_HOME}/Downloads}"
if [[ ! -w "$(dirname "${DOWNLOAD_DIR}")" ]] && [[ ${EUID} -ne 0 ]]; then
  DOWNLOAD_DIR="${HOME}/.aap27_downloads"
fi
REMOTE_DOWNLOAD_DIR_DEFAULT="/home/admin/Downloads"
BUNDLE_FILE="ansible-automation-platform-containerized-setup-bundle-2.7-3-x86_64.tar.gz"
BUNDLE_DIR_NAME="ansible-automation-platform-containerized-setup-bundle-2.7-3-x86_64"
BUNDLE_URL_DEFAULT="https://access.cdn.redhat.com/content/origin/files/sha256/e5/e554eb7fa63caad0ed756e458e2909f211839d2031ee27df742b18fb3800eb53/ansible-automation-platform-containerized-setup-bundle-2.7-3-x86_64.tar.gz?user=dfb5278729bd015d083f488da113c04b&_auth_=1785475461_03f0fad0765defe3b7165a0a9ac6677a"
BUNDLE_URL_CANDIDATES=(
  "${BUNDLE_URL_DEFAULT}"
  "https://access.cdn.redhat.com/content/origin/files/sha256/07/07e15c8111a769e9a55f2bc71765f03edb6e129d9ab63acb35f6798714d9bed7/ansible-automation-platform-containerized-setup-2.7-3.tar.gz?user=dfb5278729bd015d083f488da113c04b&_auth_=1785475461_37871272ca0f61e89a9df8de2116eaff"
  "https://access.cdn.redhat.com/content/origin/files/sha256/5c/5c0e1834c1ae609ce840865b5aa279b5c5bde9118856b326f77cc5c8bf92d9af/ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64.tar.gz"
  "https://access.cdn.redhat.com/content/origin/files/sha256/e5/e554eb7fa63caad0ed756e458e2909f211839d2031ee27df742b18fb3800eb53/ansible-automation-platform-containerized-setup-bundle-2.7-3-x86_64.tar.gz"
)
DEFAULT_REMOTE_HOST="192.168.122.84"
DEFAULT_REMOTE_PASSWORD="redhat"
DEFAULT_ADMIN_PASSWORD="redhat"
DEFAULT_ENV_FILE="${HOME}/.ansible/conf/env.yml"
DEFAULT_VAULTPASS_FILE="${HOME}/.ansible/conf/.vaultpass.txt"
ENV_FILE="${ENV_FILE:-${DEFAULT_ENV_FILE}}"
VAULTPASS_FILE="${VAULTPASS_FILE:-${DEFAULT_VAULTPASS_FILE}}"
INVENTORY_FILE="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}/inventory-growth"
DEFAULT_MCP_TOOLS_IMAGE="registry.redhat.io/ansible-automation-platform-26/mcp-tools-rhel9:2.6.20260715-1783920640"
DEFAULT_MCP_SERVER_IMAGE="registry.redhat.io/ansible-automation-platform-27/mcp-server-rhel9:2.7.20260603.2-1783916914"
REMOTE_HOSTKEY_CACHE="|"

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
BLU='\033[0;34m'
NC='\033[0m'

log() { printf '%b\n' "${BLU}[INFO]${NC} $*"; }
warn() { printf '%b\n' "${YEL}[WARN]${NC} $*"; }
err() { printf '%b\n' "${RED}[ERR ]${NC} $*"; }
ok() { printf '%b\n' "${GRN}[ OK ]${NC} $*"; }

handle_interrupt() {
  printf '\n'
  err "Interrupted by user"
  exit 130
}

disable_inherited_xtrace() {
  if [[ "${AAP_DEBUG_TRACE:-0}" != "1" ]] && [[ "$-" == *x* ]]; then
    set +x
  fi
}

shell_single_quote() {
  local value="$1"
  value="${value//\'/\'\"\'\"\'}"
  printf "'%s'" "${value}"
}

start_spinner() {
  local message="$1"
  local spinner_chars='|/-\\'
  local i=0
  while :; do
    printf '\r%b' "${BLU}[RUN ]${NC} ${message} ${spinner_chars:i++%4:1}"
    sleep 0.1
  done
}

stop_spinner() {
  printf '\r\033[2K'
}

run_with_spinner() {
  local message="$1"
  local rc=0
  local cmd_output_file=""
  shift

  # Animated spinner is disabled for interactive/manual runs to avoid prompt corruption.
  if is_interactive_mode || [[ ! -t 1 ]] || [[ "${AAP_ENABLE_SPINNER:-1}" == "0" ]]; then
    if "$@"; then
      return 0
    fi
    return $?
  fi

  cmd_output_file="$(mktemp "${TMPDIR:-/tmp}/aap27_spinner.XXXXXX")"
  start_spinner "${message}" &
  local spinner_pid=$!

  if "$@" >"${cmd_output_file}" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  kill "${spinner_pid}" >/dev/null 2>&1 || true
  wait "${spinner_pid}" 2>/dev/null || true
  stop_spinner
  if [[ -s "${cmd_output_file}" ]]; then
    cat "${cmd_output_file}"
  fi
  rm -f "${cmd_output_file}"
  if [[ "${rc}" -eq 0 ]]; then
    printf '%b\n' "${GRN}[ OK ]${NC} ${message}"
  else
    printf '%b\n' "${RED}[ERR ]${NC} ${message}"
  fi
  return "${rc}"
}

usage() {
  cat <<'USAGE'
AAP 2.7 installer usage
=======================
Default behavior: run non-interactively whenever required values are present.
Use --manual to re-enable prompts.

Options:
  -h, --help                  Show this help and exit.
  --manual                    Re-enable interactive prompts.
  --non-interactive           Disable prompts and run hands-free.
  --no-prompt                 Alias for --non-interactive.
  --reset-env                Re-prompt settings and rewrite env file.
  --playbook NAME             Override playbook selection.
  --install-scope local|remote
  --remote-host HOST         Set remote host IP/hostname.
  --remote-fqdn FQDN         Set remote host FQDN.
  --remote-ip IP             Legacy alias for --remote-host.
  --controller-ip IP         Local Ansible controller IP (this machine).
  --controller-fqdn FQDN     Local Ansible controller FQDN (this machine).
  --remote-user USER         Set remote non-root user.
  --remote-bootstrap-user USER  Set bootstrap SSH user.
  --remote-password PASS     Set shared SSH password fallback.
  --remote-bootstrap-password PASS  Set bootstrap SSH password.
  --remote-admin-password PASS      Set admin SSH password.
  --local-user USER          Set local user for SSH sharing.
  --admin-password PASS      Set admin password.
  --rhsm-user USER           Set RHSM username.
  --rhsm-password PASS       Set RHSM password.
  --rhsm-offline-token TOKEN Set RHSM offline token.
  --rhsm-org-id ID           Set RHSM org ID.
  --rhsm-activation-key KEY  Set RHSM activation key.
  --bundle-url URL           Override bundle URL.
  --download-auth-mode MODE  Download auth mode: auto|basic-auth|bearer|basic-token|anonymous.
  --allow-anon-download 0|1  Allow anonymous download fallback in auto mode.
  --patch-archive-before-extract 0|1  Inject collection patches into archive before extraction.
  --remote-force-tty 0|1     Force SSH TTY allocation for remote commands.
  --enable-spinner 0|1       Enable/disable spinner output.
  --download-progress 0|1    Enable/disable bundle download progress bars.
  --debug-trace 0|1          Enable/disable debug xtrace handling.
  --ansible-verbosity VALUE  Set Ansible verbosity (none, -v, -vv, -vvv).
USAGE
}

is_interactive_mode() {
  local mode="${AAP_INTERACTIVE_MODE:-${AAP_INTERACTIVE:-}}"
  case "${mode,,}" in
    manual|interactive|1|true|yes|y)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

pause_enter() {
  if ! is_interactive_mode; then
    return 0
  fi
  read -r -p "Press ENTER to continue..." _unused
}

should_prompt_for_input() {
  if [[ "${AAP_NO_PROMPTS:-0}" == "1" ]]; then
    return 1
  fi
  if [[ "${AAP_RESET_ENV:-0}" == "1" ]]; then
    return 0
  fi
  if is_interactive_mode; then
    return 0
  fi
  return 1
}

prompt_for_value() {
  local var_name="$1"
  local prompt_message="$2"
  local default_value="${3:-}"
  local secret_mode="${4:-0}"
  local value=""

  if [[ -n "${!var_name:-}" ]]; then
    return 0
  fi
  if ! should_prompt_for_input; then
    return 1
  fi

  if [[ "${secret_mode}" == "secret" ]]; then
    read -r -s -p "${prompt_message}${default_value:+ [${default_value}]}: " value
    echo
  else
    read -r -p "${prompt_message}${default_value:+ [${default_value}]}: " value
  fi

  if [[ -z "${value}" ]]; then
    value="${default_value:-}"
  fi

  if [[ -n "${value}" ]]; then
    printf -v "${var_name}" '%s' "${value}"
    return 0
  fi
  return 1
}

get_local_user() {
  local user="${LOCAL_USER:-${AAP_LOCAL_USER:-${SUDO_USER:-${USER:-}}}}"
  user="${user:-$(whoami 2>/dev/null || true)}"
  printf '%s' "${user}"
}

get_remote_target_host() {
  local host="${AAP_REMOTE_IP:-${REMOTE_IP:-${AAP_REMOTE_HOST:-${REMOTE_HOST:-}}}}"
  if [[ -z "${host}" ]]; then
    host="${AAP_REMOTE_FQDN:-${REMOTE_FQDN:-}}"
  fi
  if [[ -z "${host}" ]]; then
    host="${DEFAULT_REMOTE_HOST:-}"
  fi
  printf '%s' "${host}"
}

require_root() {
  if [[ ${EUID} -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    err "Run as root or install sudo."
    exit 1
  fi
}

run_privileged() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_as_user() {
  local user_name="$1"
  shift
  if [[ ${EUID} -eq 0 ]] && command -v runuser >/dev/null 2>&1; then
    runuser -u "${user_name}" -- "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -u "${user_name}" "$@"
  else
    "$@"
  fi
}

is_remote_install_scope() {
  local explicit_scope="${AAP_INSTALL_SCOPE:-${INSTALL_SCOPE:-}}"
  local configured_host="${AAP_REMOTE_IP:-${REMOTE_IP:-${AAP_REMOTE_HOST:-${REMOTE_HOST:-${AAP_REMOTE_FQDN:-${REMOTE_FQDN:-}}}}}}"

  case "${explicit_scope,,}" in
    remote)
      return 0
      ;;
    local)
      return 1
      ;;
  esac

  case "${configured_host}" in
    ""|localhost|127.0.0.1)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

get_remote_ssh_user() {
  local user_name="${AAP_REMOTE_USER:-$(get_local_user)}"
  user_name="${user_name:-root}"
  printf '%s' "${user_name}"
}

get_remote_bootstrap_user() {
  local bootstrap_user="${AAP_REMOTE_BOOTSTRAP_USER:-root}"
  bootstrap_user="${bootstrap_user:-root}"
  printf '%s' "${bootstrap_user}"
}

get_remote_password_for_user() {
  local ssh_user="$1"
  local bootstrap_user="$(get_remote_bootstrap_user)"
  local remote_user="$(get_remote_ssh_user)"

  if [[ "${ssh_user}" == "${bootstrap_user}" ]] && [[ -n "${AAP_REMOTE_BOOTSTRAP_PASSWORD:-}" ]]; then
    printf '%s' "${AAP_REMOTE_BOOTSTRAP_PASSWORD}"
    return 0
  fi
  if [[ "${ssh_user}" == "${remote_user}" ]] && [[ -n "${AAP_REMOTE_ADMIN_PASSWORD:-}" ]]; then
    printf '%s' "${AAP_REMOTE_ADMIN_PASSWORD}"
    return 0
  fi
  if [[ -n "${AAP_REMOTE_PASSWORD:-}" ]]; then
    printf '%s' "${AAP_REMOTE_PASSWORD}"
    return 0
  fi
  printf '%s' "${DEFAULT_REMOTE_PASSWORD}"
}

get_local_public_key() {
  local local_user="$(get_local_user)"
  local local_home="$(get_user_home "${local_user}")"
  local key_file=""
  local -a candidates=(
    "${AAP_LOCAL_PUBLIC_KEY_FILE:-}"
    "${local_home}/.ssh/id_ed25519.pub"
    "${local_home}/.ssh/id_rsa.pub"
  )

  for key_file in "${candidates[@]}"; do
    if [[ -n "${key_file}" ]] && [[ -r "${key_file}" ]]; then
      cat "${key_file}"
      return 0
    fi
  done
  printf '%s' ""
}

get_remote_ssh_target() {
  local target_host="${AAP_REMOTE_IP:-${REMOTE_IP:-${AAP_REMOTE_HOST:-${REMOTE_HOST:-}}}}"
  if [[ -z "${target_host}" ]]; then
    target_host="${AAP_REMOTE_FQDN:-${REMOTE_FQDN:-}}"
  fi
  if [[ -z "${target_host}" ]]; then
    target_host="${DEFAULT_REMOTE_HOST}"
  fi
  printf '%s' "${target_host}"
}

resolve_download_dir() {
  if is_remote_install_scope; then
    printf '%s' "${REMOTE_DOWNLOAD_DIR_DEFAULT}"
    return 0
  fi
  printf '%s' "${DOWNLOAD_DIR:-${AAP_DOWNLOAD_DIR:-${ADMIN_HOME}/Downloads}}"
}

refresh_runtime_paths() {
  DOWNLOAD_DIR="$(resolve_download_dir)"
  INVENTORY_FILE="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}/inventory-growth"
}

ensure_remote_host_key() {
  local target_host="$1"
  local ssh_user="$2"
  local known_hosts_file="${HOME:-/root}/.ssh/known_hosts"
  local cache_key="|${target_host}|"

  # Avoid repeated preauth connections from frequent ssh-keyscan calls.
  if [[ "${REMOTE_HOSTKEY_CACHE}" == *"${cache_key}"* ]]; then
    return 0
  fi

  if [[ -z "${target_host}" ]] || [[ "${target_host}" == "localhost" ]] || [[ "${target_host}" == "127.0.0.1" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "${known_hosts_file}")"
  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -R "${target_host}" -f "${known_hosts_file}" >/dev/null 2>&1 || true
    ssh-keygen -R "[${target_host}]:22" -f "${known_hosts_file}" >/dev/null 2>&1 || true
  fi
  if command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -F "${target_host}" -f "${known_hosts_file}" >/dev/null 2>&1; then
    REMOTE_HOSTKEY_CACHE+="${target_host}|"
    return 0
  fi

  if command -v ssh-keyscan >/dev/null 2>&1; then
    ssh-keyscan -H "${target_host}" 2>/dev/null >> "${known_hosts_file}" 2>/dev/null || true
    chmod 600 "${known_hosts_file}" 2>/dev/null || true
  fi

  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -F "${target_host}" -f "${known_hosts_file}" >/dev/null 2>&1 || true
  fi

  REMOTE_HOSTKEY_CACHE+="${target_host}|"
}

validate_bundle_archive() {
  local archive_path="$1"
  if [[ ! -f "${archive_path}" ]]; then
    return 1
  fi
  if tar -tzf "${archive_path}" >/dev/null 2>&1; then
    return 0
  fi
  if command -v gzip >/dev/null 2>&1 && gzip -t "${archive_path}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

compute_file_sha256() {
  local file_path="$1"
  local checksum=""
  if [[ ! -f "${file_path}" ]]; then
    return 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    checksum="$(sha256sum "${file_path}" 2>/dev/null | awk '{print $1}' || true)"
  elif command -v shasum >/dev/null 2>&1; then
    checksum="$(shasum -a 256 "${file_path}" 2>/dev/null | awk '{print $1}' || true)"
  elif command -v openssl >/dev/null 2>&1; then
    checksum="$(openssl dgst -sha256 "${file_path}" 2>/dev/null | awk '{print $NF}' || true)"
  fi
  if [[ -z "${checksum}" ]]; then
    return 1
  fi
  printf '%s' "${checksum}"
}

detect_archive_root_dir() {
  local archive_path="$1"
  local detected_root=""
  local first_entry=""
  first_entry="$(tar -tzf "${archive_path}" 2>/dev/null | sed -n '1p' || true)"
  case "${first_entry}" in
    */*)
      detected_root="${first_entry%%/*}"
      ;;
    *)
      detected_root=""
      ;;
  esac
  printf '%s' "${detected_root}"
}

bundle_url_points_to_error_page() {
  local bundle_url="$1"
  if [[ -z "${bundle_url}" ]]; then
    return 1
  fi
  if [[ "${bundle_url}" == *'/downloads/content/error?code=403'* ]]; then
    return 0
  fi
  if [[ "${bundle_url}" == *'/downloads/content/error'* ]] && [[ "${bundle_url}" == *'code=403'* ]]; then
    return 0
  fi
  return 1
}

run_remote_command() {
  local target_host="$1"
  local ssh_user="$2"
  shift 2
  local -a ssh_args=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o GlobalKnownHostsFile=/dev/null -o PreferredAuthentications=publickey,password -o PasswordAuthentication=yes -o PubkeyAuthentication=yes -o LogLevel=ERROR)
  local -a ssh_cmd=(ssh)
  local selected_password=""
  local remote_command=""
  local quoted_arg=""

  if [[ -z "${target_host}" ]] || [[ "${target_host}" == "localhost" ]] || [[ "${target_host}" == "127.0.0.1" ]]; then
    "$@"
    return $?
  fi

  if ! command -v ssh >/dev/null 2>&1; then
    err "ssh is required to manage remote hosts"
    return 1
  fi

  if [[ "${AAP_REMOTE_FORCE_TTY:-0}" == "1" ]]; then
    ssh_args+=(-tt)
  fi

  ensure_remote_host_key "${target_host}" "${ssh_user}"

  selected_password="$(get_remote_password_for_user "${ssh_user}")"
  if [[ -n "${selected_password}" ]]; then
    if command -v sshpass >/dev/null 2>&1; then
      ssh_cmd=(sshpass -e ssh)
      export SSHPASS="${selected_password}"
    else
      warn "sshpass is not installed; falling back to key-based SSH"
    fi
  fi

  for quoted_arg in "$@"; do
    quoted_arg="${quoted_arg//\'/\'\"\'\"\'}"
    if [[ -n "${remote_command}" ]]; then
      remote_command+=" "
    fi
    remote_command+="'${quoted_arg}'"
  done

  "${ssh_cmd[@]}" "${ssh_args[@]}" "${ssh_user}@${target_host}" -- "${remote_command}"
}

ensure_vaultpass_file() {
  local vaultpass_dir=""
  local generated_value=""

  vaultpass_dir="$(dirname "${VAULTPASS_FILE}")"
  mkdir -p "${vaultpass_dir}"

  if [[ -f "${VAULTPASS_FILE}" ]] && [[ -s "${VAULTPASS_FILE}" ]]; then
    chmod 600 "${VAULTPASS_FILE}" 2>/dev/null || true
    return 0
  fi

  if [[ -n "${ANSIBLE_VAULT_PASSWORD:-}" ]]; then
    printf '%s\n' "${ANSIBLE_VAULT_PASSWORD}" > "${VAULTPASS_FILE}"
  else
    generated_value="$(openssl rand -base64 24 2>/dev/null || tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    if [[ -z "${generated_value}" ]]; then
      generated_value="aap27-${USER:-root}-vault"
    fi
    printf '%s\n' "${generated_value}" > "${VAULTPASS_FILE}"
  fi

  chmod 600 "${VAULTPASS_FILE}" 2>/dev/null || true
}

initialize_env_file() {
  local env_dir=""
  local candidate=""
  ensure_vaultpass_file

  env_dir="$(dirname "${ENV_FILE}")"
  if mkdir -p "${env_dir}" 2>/dev/null && touch "${ENV_FILE}" 2>/dev/null; then
    chmod 600 "${ENV_FILE}" 2>/dev/null || true
    return 0
  fi

  for candidate in "${HOME}/.aap27_install.env" "/tmp/.aap27_install_${USER:-$(id -u)}.env" "${PWD}/.aap27_install.env"; do
    env_dir="$(dirname "${candidate}")"
    mkdir -p "${env_dir}" 2>/dev/null || continue
    if touch "${candidate}" 2>/dev/null; then
      warn "Unable to write to ${ENV_FILE}; falling back to ${candidate}"
      ENV_FILE="${candidate}"
      chmod 600 "${ENV_FILE}" 2>/dev/null || true
      return 0
    fi
  done

  err "Unable to initialize installer state file."
  exit 1
}

encrypt_env_file() {
  local plaintext_file="$1"
  ensure_vaultpass_file
  mkdir -p "$(dirname "${ENV_FILE}")"

  if command -v ansible-vault >/dev/null 2>&1; then
    ansible-vault encrypt --vault-password-file "${VAULTPASS_FILE}" --output "${ENV_FILE}" "${plaintext_file}" >/dev/null 2>&1 || return 1
  elif command -v gpg >/dev/null 2>&1; then
    printf '%s' "$(<"${VAULTPASS_FILE}")" | gpg --batch --yes --passphrase-fd 0 --pinentry-mode loopback --symmetric --cipher-algo AES256 -o "${ENV_FILE}" "${plaintext_file}" >/dev/null 2>&1 || return 1
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$(<"${VAULTPASS_FILE}")" | openssl enc -aes-256-cbc -pbkdf2 -salt -in "${plaintext_file}" -out "${ENV_FILE}" -pass stdin >/dev/null 2>&1 || return 1
  else
    cp "${plaintext_file}" "${ENV_FILE}"
  fi

  chmod 600 "${ENV_FILE}" 2>/dev/null || true
}

decrypt_env_file() {
  local encrypted_file="$1"
  local plaintext_file="$2"
  ensure_vaultpass_file

  if [[ ! -f "${encrypted_file}" ]]; then
    : > "${plaintext_file}"
    return 0
  fi

  if command -v ansible-vault >/dev/null 2>&1; then
    ansible-vault decrypt --vault-password-file "${VAULTPASS_FILE}" --output "${plaintext_file}" "${encrypted_file}" >/dev/null 2>&1 && return 0
  elif command -v gpg >/dev/null 2>&1; then
    printf '%s' "$(<"${VAULTPASS_FILE}")" | gpg --batch --yes --passphrase-fd 0 --pinentry-mode loopback --decrypt --output "${plaintext_file}" "${encrypted_file}" >/dev/null 2>&1 && return 0
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$(<"${VAULTPASS_FILE}")" | openssl enc -d -aes-256-cbc -pbkdf2 -in "${encrypted_file}" -out "${plaintext_file}" -pass stdin >/dev/null 2>&1 && return 0
  else
    cp "${encrypted_file}" "${plaintext_file}"
    return 0
  fi

  if grep -qE '^[A-Za-z_][A-Za-z0-9_]*=' "${encrypted_file}"; then
    cp "${encrypted_file}" "${plaintext_file}"
    return 0
  fi

  return 1
}

load_env() {
  local had_xtrace=0
  local tmp_env_file=""
  local line=""
  local key=""
  local value=""

  case "$-" in
    *x*)
      had_xtrace=1
      set +x
      ;;
  esac

  if [[ -f "${ENV_FILE}" ]]; then
    tmp_env_file="$(mktemp "${TMPDIR:-/tmp}/aap27_env.XXXXXX")"
    if decrypt_env_file "${ENV_FILE}" "${tmp_env_file}"; then
      while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        if [[ -n "${key}" ]]; then
          # Preserve explicitly provided env/CLI values over persisted file values.
          if [[ -n "${!key:-}" ]]; then
            continue
          fi
          printf -v "${key}" '%s' "${value}"
        fi
      done < "${tmp_env_file}"
    fi
    rm -f "${tmp_env_file}"
  fi

  if [[ ${had_xtrace} -eq 1 ]]; then
    set -x
  fi
}

save_env_kv() {
  local key="$1"
  local value="$2"
  local tmp_env_file=""
  local tmp_line=""

  mkdir -p "$(dirname "${ENV_FILE}")"
  tmp_env_file="$(mktemp "${TMPDIR:-/tmp}/aap27_env.XXXXXX")"

  if [[ -f "${ENV_FILE}" ]]; then
    if ! decrypt_env_file "${ENV_FILE}" "${tmp_env_file}"; then
      : > "${tmp_env_file}"
    fi
  else
    : > "${tmp_env_file}"
  fi

  tmp_line="${key}=${value}"
  if grep -qE "^${key}=" "${tmp_env_file}"; then
    sed -i "s|^${key}=.*|${tmp_line}|" "${tmp_env_file}"
  else
    printf '%s\n' "${tmp_line}" >> "${tmp_env_file}"
  fi

  encrypt_env_file "${tmp_env_file}"
  rm -f "${tmp_env_file}"
}

read_secret_prompt() {
  local var_name="$1"
  local prompt_message="$2"
  local required_mode="${3:-optional}"
  local default_value="${4:-}"
  local value=""

  if [[ -n "${!var_name:-}" ]]; then
    return 0
  fi
  if ! should_prompt_for_input; then
    err "${prompt_message} is required in non-interactive mode."
    return 1
  fi

  read -r -s -p "${prompt_message}${default_value:+ [${default_value}]}: " value
  echo
  if [[ -z "${value}" ]]; then
    value="${default_value:-}"
  fi
  if [[ "${required_mode}" == "required" ]] && [[ -z "${value}" ]]; then
    err "${prompt_message} cannot be empty."
    return 1
  fi
  printf -v "${var_name}" '%s' "${value}"
}

reset_env_and_reprompt() {
  local scope_input=""
  local scope_lower=""
  local had_xtrace=0

  if ! should_prompt_for_input; then
    err "--reset-env requires interactive input"
    return 1
  fi

  case "$-" in
    *x*)
      had_xtrace=1
      set +x
      ;;
  esac

  mkdir -p "$(dirname "${ENV_FILE}")"
  : > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}" 2>/dev/null || true

  unset INSTALL_SCOPE AAP_INSTALL_SCOPE
  unset AAP_CONTROLLER_IP AAP_CONTROLLER_FQDN AAP_REMOTE_IP AAP_REMOTE_FQDN
  unset AAP_REMOTE_USER AAP_REMOTE_BOOTSTRAP_USER
  unset AAP_REMOTE_PASSWORD AAP_REMOTE_BOOTSTRAP_PASSWORD AAP_REMOTE_ADMIN_PASSWORD
  unset AAP_PLAYBOOK ANSIBLE_VERBOSITY CLI_ANSIBLE_VERBOSITY
  unset BUNDLE_URL
  unset RHSM_USERNAME RHSM_PASSWORD RHSM_OFFLINE_TOKEN RHSM_ORG_ID RHSM_ACTIVATION_KEY
  unset ADMIN_PASSWORD AAP_ADMIN_PASSWORD

  prompt_for_value scope_input "Install scope (local/remote)" "remote" || return 1
  scope_lower="${scope_input,,}"
  case "${scope_lower}" in
    local|remote) ;;
    *)
      err "Invalid install scope: ${scope_input}"
      return 1
      ;;
  esac
  INSTALL_SCOPE="${scope_lower}"
  AAP_INSTALL_SCOPE="${scope_lower}"
  save_env_kv "INSTALL_SCOPE" "${INSTALL_SCOPE}"

  prompt_for_value AAP_PLAYBOOK "Playbook name" "install" || return 1
  save_env_kv "AAP_PLAYBOOK" "${AAP_PLAYBOOK}"

  prompt_for_value ANSIBLE_VERBOSITY "Ansible verbosity (none, -v, -vv, -vvv)" "none" || return 1
  save_env_kv "ANSIBLE_VERBOSITY" "${ANSIBLE_VERBOSITY}"

  prompt_for_value BUNDLE_URL "Bundle download URL" "${BUNDLE_URL_DEFAULT}" || return 1
  save_env_kv "BUNDLE_URL" "${BUNDLE_URL}"

  prompt_for_value RHSM_USERNAME "RHSM username" "" || return 1
  save_env_kv "RHSM_USERNAME" "${RHSM_USERNAME}"

  read_secret_prompt RHSM_PASSWORD "RHSM password" required || return 1
  save_env_kv "RHSM_PASSWORD" "${RHSM_PASSWORD}"

  prompt_for_value RHSM_OFFLINE_TOKEN "RHSM offline token (optional)" "" secret || true
  save_env_kv "RHSM_OFFLINE_TOKEN" "${RHSM_OFFLINE_TOKEN:-}"

  prompt_for_value RHSM_ORG_ID "RHSM org ID (optional)" "" || true
  save_env_kv "RHSM_ORG_ID" "${RHSM_ORG_ID:-}"

  prompt_for_value RHSM_ACTIVATION_KEY "RHSM activation key (optional)" "" secret || true
  save_env_kv "RHSM_ACTIVATION_KEY" "${RHSM_ACTIVATION_KEY:-}"

  if [[ "${INSTALL_SCOPE}" == "remote" ]]; then
    prompt_for_value AAP_REMOTE_IP "Remote host IP/hostname" "${DEFAULT_REMOTE_HOST}" || return 1
    save_env_kv "AAP_REMOTE_IP" "${AAP_REMOTE_IP}"

    prompt_for_value AAP_REMOTE_USER "Remote SSH user" "admin" || return 1
    save_env_kv "AAP_REMOTE_USER" "${AAP_REMOTE_USER}"

    prompt_for_value AAP_REMOTE_BOOTSTRAP_USER "Remote bootstrap SSH user" "root" || return 1
    save_env_kv "AAP_REMOTE_BOOTSTRAP_USER" "${AAP_REMOTE_BOOTSTRAP_USER}"

    prompt_for_value AAP_REMOTE_PASSWORD "Remote SSH password (shared default)" "${DEFAULT_REMOTE_PASSWORD}" secret || return 1
    save_env_kv "AAP_REMOTE_PASSWORD" "${AAP_REMOTE_PASSWORD}"

    prompt_for_value AAP_REMOTE_BOOTSTRAP_PASSWORD "Remote bootstrap password override (optional)" "${DEFAULT_REMOTE_PASSWORD}" secret || true
    save_env_kv "AAP_REMOTE_BOOTSTRAP_PASSWORD" "${AAP_REMOTE_BOOTSTRAP_PASSWORD:-}"

    prompt_for_value AAP_REMOTE_ADMIN_PASSWORD "Remote admin password override (optional)" "${DEFAULT_REMOTE_PASSWORD}" secret || true
    save_env_kv "AAP_REMOTE_ADMIN_PASSWORD" "${AAP_REMOTE_ADMIN_PASSWORD:-}"
  else
    save_env_kv "AAP_REMOTE_IP" ""
    save_env_kv "AAP_REMOTE_USER" ""
    save_env_kv "AAP_REMOTE_BOOTSTRAP_USER" ""
    save_env_kv "AAP_REMOTE_PASSWORD" ""
    save_env_kv "AAP_REMOTE_BOOTSTRAP_PASSWORD" ""
    save_env_kv "AAP_REMOTE_ADMIN_PASSWORD" ""
  fi

  read_secret_prompt ADMIN_PASSWORD "Platform admin password" required "${DEFAULT_ADMIN_PASSWORD}" || return 1
  AAP_ADMIN_PASSWORD="${ADMIN_PASSWORD}"
  save_env_kv "ADMIN_PASSWORD" "${ADMIN_PASSWORD}"
  save_env_kv "AAP_ADMIN_PASSWORD" "${AAP_ADMIN_PASSWORD}"

  if [[ ${had_xtrace} -eq 1 ]]; then
    set -x
  fi

  ok "Rewrote ${ENV_FILE} with prompted values"
}

prompt_for_missing_runtime_settings() {
  local remote_host=""
  local remote_user=""

  if [[ -z "${BUNDLE_URL:-}" ]] && should_prompt_for_input; then
    if prompt_for_value BUNDLE_URL "Enter bundle download URL (optional)" "${BUNDLE_URL_DEFAULT}"; then
      BUNDLE_URL="${BUNDLE_URL:-${BUNDLE_URL_DEFAULT}}"
      save_env_kv "BUNDLE_URL" "${BUNDLE_URL}"
    fi
  fi

  if [[ -z "${RHSM_USERNAME:-}" ]] || [[ -z "${RHSM_PASSWORD:-}" ]]; then
    ensure_registry_credentials || true
  fi

  if [[ -z "${ADMIN_PASSWORD:-}" && -z "${AAP_ADMIN_PASSWORD:-}" ]]; then
    if should_prompt_for_input; then
      if prompt_for_value ADMIN_PASSWORD "Enter platform admin password" "${DEFAULT_ADMIN_PASSWORD}" secret; then
        AAP_ADMIN_PASSWORD="${ADMIN_PASSWORD:-${DEFAULT_ADMIN_PASSWORD}}"
        save_env_kv "ADMIN_PASSWORD" "${AAP_ADMIN_PASSWORD}"
        save_env_kv "AAP_ADMIN_PASSWORD" "${AAP_ADMIN_PASSWORD}"
      fi
    else
      AAP_ADMIN_PASSWORD="${DEFAULT_ADMIN_PASSWORD}"
      ADMIN_PASSWORD="${DEFAULT_ADMIN_PASSWORD}"
      save_env_kv "ADMIN_PASSWORD" "${AAP_ADMIN_PASSWORD}"
      save_env_kv "AAP_ADMIN_PASSWORD" "${AAP_ADMIN_PASSWORD}"
    fi
  fi

  if ! is_remote_install_scope; then
    return 0
  fi

  remote_host="$(get_remote_target_host)"
  if [[ -z "${AAP_REMOTE_IP:-${REMOTE_IP:-}}" && -z "${AAP_REMOTE_FQDN:-${REMOTE_FQDN:-}}" ]]; then
    if prompt_for_value AAP_REMOTE_IP "Enter remote host IP/hostname" "${remote_host:-${DEFAULT_REMOTE_HOST}}"; then
      AAP_REMOTE_IP="${AAP_REMOTE_IP:-${DEFAULT_REMOTE_HOST}}"
      save_env_kv "AAP_REMOTE_IP" "${AAP_REMOTE_IP}"
    fi
  fi

  if [[ -z "${AAP_REMOTE_USER:-${REMOTE_USER:-}}" ]]; then
    if prompt_for_value AAP_REMOTE_USER "Enter remote SSH user for later steps" "admin"; then
      AAP_REMOTE_USER="${AAP_REMOTE_USER:-admin}"
      save_env_kv "AAP_REMOTE_USER" "${AAP_REMOTE_USER}"
    fi
  fi

  if [[ -z "${AAP_REMOTE_BOOTSTRAP_USER:-}" ]]; then
    if prompt_for_value AAP_REMOTE_BOOTSTRAP_USER "Enter remote bootstrap SSH user" "root"; then
      AAP_REMOTE_BOOTSTRAP_USER="${AAP_REMOTE_BOOTSTRAP_USER:-root}"
      save_env_kv "AAP_REMOTE_BOOTSTRAP_USER" "${AAP_REMOTE_BOOTSTRAP_USER}"
    fi
  fi

  if should_prompt_for_input; then
    if [[ -z "${AAP_REMOTE_PASSWORD:-}" ]]; then
      AAP_REMOTE_PASSWORD="${DEFAULT_REMOTE_PASSWORD}"
      save_env_kv "AAP_REMOTE_PASSWORD" "${AAP_REMOTE_PASSWORD}"
    fi
    if [[ -z "${AAP_REMOTE_BOOTSTRAP_PASSWORD:-}" ]] && [[ -z "${AAP_REMOTE_PASSWORD:-}" ]]; then
      read_secret_prompt AAP_REMOTE_BOOTSTRAP_PASSWORD "Enter remote bootstrap SSH password" optional "${DEFAULT_REMOTE_PASSWORD}"
      save_env_kv "AAP_REMOTE_BOOTSTRAP_PASSWORD" "${AAP_REMOTE_BOOTSTRAP_PASSWORD}"
    fi
    if [[ -z "${AAP_REMOTE_ADMIN_PASSWORD:-}" ]] && [[ -z "${AAP_REMOTE_PASSWORD:-}" ]]; then
      read_secret_prompt AAP_REMOTE_ADMIN_PASSWORD "Enter remote admin SSH password" optional "${DEFAULT_REMOTE_PASSWORD}"
      save_env_kv "AAP_REMOTE_ADMIN_PASSWORD" "${AAP_REMOTE_ADMIN_PASSWORD}"
    fi
  fi

}

validate_non_interactive_requirements() {
  local -a missing=()
  local install_scope="${AAP_INSTALL_SCOPE:-${INSTALL_SCOPE:-}}"
  local download_auth_mode="${AAP_DOWNLOAD_AUTH_MODE:-auto}"
  local remote_host=""
  local have_rhsm_registration_method=0

  if [[ "${AAP_NO_PROMPTS:-0}" != "1" ]]; then
    return 0
  fi

  if [[ -z "${install_scope}" ]]; then
    if is_remote_install_scope; then
      install_scope="remote"
    else
      install_scope="local"
    fi
  fi

  if [[ -z "${BUNDLE_URL:-}" ]]; then
    BUNDLE_URL="${BUNDLE_URL_DEFAULT}"
  fi

  if [[ -z "${AAP_ADMIN_PASSWORD:-${ADMIN_PASSWORD:-}}" ]]; then
    missing+=("platform admin password (--admin-password)")
  fi

  case "${download_auth_mode}" in
    auto|anonymous)
      ;;
    basic-auth)
      if [[ -z "${RHSM_USERNAME:-}" || -z "${RHSM_PASSWORD:-}" ]]; then
        missing+=("download auth basic-auth requires --rhsm-user and --rhsm-password")
      fi
      ;;
    bearer)
      if [[ -z "${RHSM_OFFLINE_TOKEN:-}" ]]; then
        missing+=("download auth bearer requires --rhsm-offline-token")
      fi
      ;;
    basic-token)
      if [[ -z "${RHSM_USERNAME:-}" || -z "${RHSM_OFFLINE_TOKEN:-}" ]]; then
        missing+=("download auth basic-token requires --rhsm-user and --rhsm-offline-token")
      fi
      ;;
    *)
      missing+=("valid --download-auth-mode (auto|basic-auth|bearer|basic-token|anonymous)")
      ;;
  esac

  if [[ "${install_scope,,}" == "remote" ]]; then
    remote_host="$(get_remote_target_host)"
    if [[ -z "${remote_host}" ]]; then
      missing+=("remote host (--remote-host/--remote-fqdn/--remote-ip)")
    fi
    if [[ -z "${AAP_REMOTE_USER:-}" ]]; then
      missing+=("remote SSH user (--remote-user)")
    fi
    if [[ -z "${AAP_REMOTE_PASSWORD:-}" && -z "${AAP_REMOTE_BOOTSTRAP_PASSWORD:-}" && -z "${AAP_REMOTE_ADMIN_PASSWORD:-}" ]]; then
      missing+=("remote SSH password (--remote-password or --remote-bootstrap-password/--remote-admin-password)")
    fi
    if [[ -n "${RHSM_ORG_ID:-}" && -n "${RHSM_ACTIVATION_KEY:-}" ]]; then
      have_rhsm_registration_method=1
    fi
    if [[ -n "${RHSM_USERNAME:-}" && -n "${RHSM_PASSWORD:-}" ]]; then
      have_rhsm_registration_method=1
    fi
    if [[ ${have_rhsm_registration_method} -eq 0 ]]; then
      missing+=("RHSM registration credentials (either --rhsm-user + --rhsm-password, or --rhsm-org-id + --rhsm-activation-key)")
    fi
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Non-interactive run is missing required inputs:"
    local missing_item=""
    for missing_item in "${missing[@]}"; do
      err "  - ${missing_item}"
    done
    err "Provide the missing flags or env vars and rerun with --non-interactive"
    return 1
  fi

  return 0
}

prompt_for_remote_password_if_needed() {
  local ssh_user="$1"
  local bootstrap_user="$(get_remote_bootstrap_user)"
  local remote_user="$(get_remote_ssh_user)"

  if [[ -n "$(get_remote_password_for_user "${ssh_user}")" ]]; then
    return 0
  fi
  if ! should_prompt_for_input; then
    return 1
  fi

  if [[ "${ssh_user}" == "${bootstrap_user}" ]]; then
    read_secret_prompt AAP_REMOTE_BOOTSTRAP_PASSWORD "Enter remote bootstrap SSH password" optional "${DEFAULT_REMOTE_PASSWORD}"
    save_env_kv "AAP_REMOTE_BOOTSTRAP_PASSWORD" "${AAP_REMOTE_BOOTSTRAP_PASSWORD}"
    return 0
  fi
  if [[ "${ssh_user}" == "${remote_user}" ]]; then
    read_secret_prompt AAP_REMOTE_ADMIN_PASSWORD "Enter remote admin SSH password" optional "${DEFAULT_REMOTE_PASSWORD}"
    save_env_kv "AAP_REMOTE_ADMIN_PASSWORD" "${AAP_REMOTE_ADMIN_PASSWORD}"
    return 0
  fi

  read_secret_prompt AAP_REMOTE_PASSWORD "Enter remote SSH password" optional "${DEFAULT_REMOTE_PASSWORD}"
  save_env_kv "AAP_REMOTE_PASSWORD" "${AAP_REMOTE_PASSWORD}"
}

ensure_admin_user_exists() {
  local target_host=""
  local target_user=""
  local bootstrap_user=""
  local admin_exists_before=0
  local local_public_key=""
  local -a attempt_users=()
  local attempt_user=""
  local remote_output=""
  local remote_script="set -euo pipefail; priv=''; if [[ \$(id -u) -ne 0 ]]; then if command -v sudo >/dev/null 2>&1; then priv='sudo'; else exit 1; fi; fi; if ! id admin >/dev/null 2>&1; then \${priv} /usr/sbin/useradd -m -s /bin/bash admin >/dev/null 2>&1 || true; fi; \${priv} mkdir -p /home/admin /home/admin/Downloads /home/admin/.ssh >/dev/null 2>&1 || true; if ! \${priv} grep -q '^admin\\s\+ALL=(ALL)\\s\+NOPASSWD: ALL' /etc/sudoers.d/admin >/dev/null 2>&1; then printf 'admin       ALL=(ALL)       NOPASSWD: ALL\n' | \${priv} tee /etc/sudoers.d/admin >/dev/null; \${priv} chmod 0440 /etc/sudoers.d/admin; fi; if command -v /usr/sbin/usermod >/dev/null 2>&1; then \${priv} /usr/sbin/usermod -aG wheel admin >/dev/null 2>&1 || true; fi; if [[ -n \"\${LOCAL_ADMIN_PUBKEY:-}\" ]]; then auth_keys='/home/admin/.ssh/authorized_keys'; tmp_auth_keys=\"\$(mktemp /tmp/admin-authorized_keys.XXXXXX)\"; if [[ -f \"\${auth_keys}\" ]]; then grep -vxF \"\${LOCAL_ADMIN_PUBKEY}\" \"\${auth_keys}\" > \"\${tmp_auth_keys}\" || true; else : > \"\${tmp_auth_keys}\"; fi; printf '%s\n' \"\${LOCAL_ADMIN_PUBKEY}\" >> \"\${tmp_auth_keys}\"; \${priv} tee \"\${auth_keys}\" >/dev/null < \"\${tmp_auth_keys}\"; rm -f \"\${tmp_auth_keys}\"; fi; \${priv} chmod 700 /home/admin/.ssh >/dev/null 2>&1 || true; \${priv} chmod 600 /home/admin/.ssh/authorized_keys >/dev/null 2>&1 || true; \${priv} chown -R admin:admin /home/admin >/dev/null 2>&1 || true"

  if is_remote_install_scope; then
    target_host="$(get_remote_ssh_target)"
    target_user="$(get_remote_ssh_user)"
    bootstrap_user="$(get_remote_bootstrap_user)"
    local_public_key="$(get_local_public_key)"

    # Try admin first, then bootstrap root, then any explicitly configured user.
    attempt_users=("admin")
    if [[ -n "${bootstrap_user}" && "${bootstrap_user}" != "admin" ]]; then
      attempt_users+=("${bootstrap_user}")
    fi
    if [[ -n "${target_user}" && "${target_user}" != "admin" && "${target_user}" != "${bootstrap_user}" ]]; then
      attempt_users+=("${target_user}")
    fi

    for attempt_user in "${attempt_users[@]}"; do
      if run_remote_command "${target_host}" "${attempt_user}" bash --noprofile --norc -c "id admin >/dev/null 2>&1" >/dev/null 2>&1; then
        admin_exists_before=1
        break
      fi
    done

    if [[ ${admin_exists_before} -eq 0 ]]; then
      warn "admin user does not exist on ${target_host}; creating it now"
    fi
    for attempt_user in "${attempt_users[@]}"; do
      if should_prompt_for_input; then
        prompt_for_remote_password_if_needed "${attempt_user}" || true
      fi
      case "$-" in
        *x*)
          had_xtrace=1
          set +x
          ;;
        *) had_xtrace=0 ;;
      esac
      run_remote_command "${target_host}" "${attempt_user}" env "LOCAL_ADMIN_PUBKEY=${local_public_key}" bash --noprofile --norc -c "${remote_script}" >/dev/null 2>&1
      remote_rc=$?
      if [[ ${had_xtrace} -eq 1 ]]; then
        set -x
      fi
      if [[ ${remote_rc} -eq 0 ]]; then
        if [[ ${admin_exists_before} -eq 0 ]]; then
          ok "admin user created on ${target_host} via ${attempt_user}"
        else
          ok "admin user already exists on ${target_host}; ensured configuration via ${attempt_user}"
        fi
        return 0
      fi
      warn "SSH provisioning attempt as ${attempt_user} failed (connection/authentication error)."
      if [[ "${attempt_user}" != "${target_user}" ]]; then
        warn "Retrying with ${target_user}"
      fi
    done

    warn "Remote admin provisioning via SSH failed."
    warn "Manual remediation on ${target_host}:"
    warn "  1. SSH to ${target_host} as ${bootstrap_user}"
    warn "  2. Run: /usr/sbin/useradd -m -s /bin/bash admin"
    warn "  3. Run: sudo mkdir -p /home/admin/Downloads && sudo chown -R admin:admin /home/admin"
    warn "  4. If needed, add sudo access: printf 'admin       ALL=(ALL)       NOPASSWD: ALL\n' | sudo tee /etc/sudoers.d/admin"
    warn "  5. Re-run the installer after the account exists"
    return 1
  fi

  # Local controller changes are intentionally skipped.
  return 0
}

ensure_user_home_ownership() {
  local user_name="$1"
  local home=""
  local target_host=""
  local target_user=""
  local bootstrap_user=""
  local remote_script=""
  if is_remote_install_scope; then
    target_host="$(get_remote_ssh_target)"
    target_user="$(get_remote_ssh_user)"
    bootstrap_user="$(get_remote_bootstrap_user)"
    remote_script="if ! id '${user_name}' >/dev/null 2>&1; then exit 0; fi; home=\$(getent passwd '${user_name}' | cut -d: -f6); home=\${home:-/home/${user_name}}; mkdir -p \"\${home}\" \"\${home}/Downloads\"; if [[ \$(id -u) -eq 0 ]]; then chown -R '${user_name}:${user_name}' \"\${home}\" >/dev/null 2>&1 || true; elif command -v sudo >/dev/null 2>&1; then sudo chown -R '${user_name}:${user_name}' \"\${home}\" >/dev/null 2>&1 || true; else chown -R '${user_name}:${user_name}' \"\${home}\" >/dev/null 2>&1 || true; fi"

    if run_remote_command "${target_host}" "${target_user}" bash --noprofile --norc -c "${remote_script}" >/dev/null 2>&1; then
      return 0
    fi
    if [[ -n "${bootstrap_user}" && "${bootstrap_user}" != "${target_user}" ]]; then
      if run_remote_command "${target_host}" "${bootstrap_user}" bash --noprofile --norc -c "${remote_script}" >/dev/null 2>&1; then
        return 0
      fi
    fi
    return 0
  fi
  if ! id "${user_name}" >/dev/null 2>&1; then
    return 0
  fi
  home="$(get_user_home "${user_name}")"
  run_privileged mkdir -p "${home}" 2>/dev/null || true
  run_privileged chown -R "${user_name}:${user_name}" "${home}" 2>/dev/null || true
}

ensure_user_dbus_session() {
  local user_name="$1"
  local uid=""
  local bus_path=""
  if ! command -v loginctl >/dev/null 2>&1; then
    warn "loginctl not found; skipping lingering DBus setup"
    return 0
  fi
  uid="$(id -u "${user_name}" 2>/dev/null || true)"
  if [[ -z "${uid}" ]]; then
    return 0
  fi
  run_privileged loginctl enable-linger "${user_name}" >/dev/null 2>&1 || true
  run_privileged systemctl start "user@${uid}.service" >/dev/null 2>&1 || true
  bus_path="/run/user/${uid}/bus"
  for _ in {1..20}; do
    if [[ -S "${bus_path}" ]]; then
      return 0
    fi
    sleep 1
  done
  warn "user DBus socket not ready at ${bus_path}"
}

ensure_subid_entry() {
  local subid_file="$1"
  local user_name="$2"
  local start_id="$3"
  local range_size="$4"
  if [[ ! -f "${subid_file}" ]]; then
    run_privileged touch "${subid_file}"
  fi
  if run_privileged grep -qE "^${user_name}:" "${subid_file}"; then
    run_privileged sed -i "s|^${user_name}:.*|${user_name}:${start_id}:${range_size}|" "${subid_file}"
  else
    printf '%s:%s:%s\n' "${user_name}" "${start_id}" "${range_size}" | run_privileged tee -a "${subid_file}" >/dev/null
  fi
}

setup_admin_rootless_podman() {
  local target_user="$1"
  local home=""
  local uid=""
  local xdg_runtime=""
  local dbus_addr=""
  if [[ -z "${target_user}" ]]; then
    target_user="admin"
  fi
  if ! id "${target_user}" >/dev/null 2>&1; then
    warn "${target_user} does not exist; skipping rootless podman setup"
    return 0
  fi
  home="$(get_user_home "${target_user}")"
  uid="$(id -u "${target_user}" 2>/dev/null || echo 1000)"
  xdg_runtime="/run/user/${uid}"
  dbus_addr="unix:path=${xdg_runtime}/bus"
  run_privileged mkdir -p "${xdg_runtime}" "${home}/.config/containers"
  run_privileged chown -R "${target_user}:${target_user}" "${home}/.config/containers" "${xdg_runtime}" 2>/dev/null || true
  ensure_subid_entry /etc/subuid "${target_user}" 200000 65536
  ensure_subid_entry /etc/subgid "${target_user}" 200000 65536
  run_as_user "${target_user}" env HOME="${home}" XDG_RUNTIME_DIR="${xdg_runtime}" DBUS_SESSION_BUS_ADDRESS="${dbus_addr}" podman info >/dev/null 2>&1 || true
  ensure_user_dbus_session "${target_user}" >/dev/null 2>&1 || true
}

login_registry_as_admin() {
  local registry_user="$1"
  local registry_pass="$2"
  local target_user="$3"
  local home=""
  local uid=""
  local xdg_runtime=""
  local dbus_addr=""
  if [[ -z "${registry_user}" || -z "${registry_pass}" ]]; then
    return 0
  fi
  if ! id "${target_user}" >/dev/null 2>&1; then
    return 0
  fi
  home="$(get_user_home "${target_user}")"
  uid="$(id -u "${target_user}" 2>/dev/null || echo 1000)"
  xdg_runtime="/run/user/${uid}"
  dbus_addr="unix:path=${xdg_runtime}/bus"
  run_as_user "${target_user}" env HOME="${home}" XDG_RUNTIME_DIR="${xdg_runtime}" DBUS_SESSION_BUS_ADDRESS="${dbus_addr}" podman login --username "${registry_user}" --password-stdin registry.redhat.io <<< "${registry_pass}" >/dev/null 2>&1 || true
}

run_podman_user_bus_fix() {
  local target_user="$1"
  local registry_user="$2"
  local registry_pass="$3"
  if [[ -z "${target_user}" ]]; then
    target_user="admin"
  fi
  if ! command -v podman >/dev/null 2>&1; then
    warn "podman is not installed; skipping podman user-bus repair"
    return 0
  fi
  log "Ensuring rootless podman setup for ${target_user}"
  setup_admin_rootless_podman "${target_user}"
  if [[ -n "${registry_user}" && -n "${registry_pass}" ]]; then
    login_registry_as_admin "${registry_user}" "${registry_pass}" "${target_user}" >/dev/null 2>&1 || true
  fi
}

ensure_mcp_container_images() {
  local target_user="$1"
  local home=""
  local uid=""
  local xdg_runtime=""
  local dbus_addr=""
  local mcp_tools_image="${MCP_TOOLS_IMAGE:-${DEFAULT_MCP_TOOLS_IMAGE}}"
  local mcp_server_image="${MCP_SERVER_IMAGE:-${DEFAULT_MCP_SERVER_IMAGE}}"
  if [[ -z "${target_user}" ]]; then
    target_user="admin"
  fi
  if ! id "${target_user}" >/dev/null 2>&1; then
    warn "${target_user} is not available; skipping MCP image pulls"
    return 0
  fi
  if ! command -v podman >/dev/null 2>&1; then
    warn "podman is not installed; skipping MCP image pulls"
    return 0
  fi
  home="$(get_user_home "${target_user}")"
  uid="$(id -u "${target_user}" 2>/dev/null || echo 1000)"
  xdg_runtime="/run/user/${uid}"
  dbus_addr="unix:path=${xdg_runtime}/bus"
  save_env_kv "MCP_TOOLS_IMAGE" "${mcp_tools_image}"
  save_env_kv "MCP_SERVER_IMAGE" "${mcp_server_image}"
  run_podman_user_bus_fix "${target_user}" "${RHSM_USERNAME:-}" "${RHSM_PASSWORD:-}" >/dev/null 2>&1 || true
  for image_name in "${mcp_tools_image}" "${mcp_server_image}"; do
    if run_as_user "${target_user}" env HOME="${home}" XDG_RUNTIME_DIR="${xdg_runtime}" DBUS_SESSION_BUS_ADDRESS="${dbus_addr}" podman pull "${image_name}" >/dev/null 2>&1; then
      ok "Pulled MCP image ${image_name}"
    else
      warn "Unable to pull MCP image ${image_name}"
    fi
  done
}

ensure_registry_credentials() {
  load_env
  if [[ -z "${RHSM_USERNAME:-}" ]]; then
    if should_prompt_for_input; then
      prompt_for_value RHSM_USERNAME "Enter RHSM username" "" || return 1
      save_env_kv "RHSM_USERNAME" "${RHSM_USERNAME}"
    else
      err "RHSM_USERNAME is required in non-interactive mode"
      return 1
    fi
  fi

  if [[ -z "${RHSM_PASSWORD:-}" ]]; then
    if should_prompt_for_input; then
      read_secret_prompt RHSM_PASSWORD "Enter RHSM password" required
      save_env_kv "RHSM_PASSWORD" "${RHSM_PASSWORD}"
    else
      err "RHSM_PASSWORD is required in non-interactive mode"
      return 1
    fi
  fi

  if [[ -z "${RHSM_OFFLINE_TOKEN:-}" ]] && is_interactive_mode; then
    read_secret_prompt RHSM_OFFLINE_TOKEN "Enter Red Hat offline token (optional)"
    save_env_kv "RHSM_OFFLINE_TOKEN" "${RHSM_OFFLINE_TOKEN}"
  fi
}

normalize_ansible_verbosity() {
  case "${1:-}" in
    ""|0|none|NONE) printf '' ;;
    1|v|-v) printf '%s' '-v' ;;
    2|vv|-vv) printf '%s' '-vv' ;;
    3|vvv|-vvv) printf '%s' '-vvv' ;;
    *) printf '' ;;
  esac
}

ensure_inventory_baseline_backup() {
  local inventory_file="$1"
  local backup_file="${inventory_file}.pre_script.bak"
  if [[ -f "${inventory_file}" ]] && [[ ! -f "${backup_file}" ]]; then
    cp -p "${inventory_file}" "${backup_file}"
  fi
}

modify_inventory_growth() {
  refresh_runtime_paths
  local inventory_file="${INVENTORY_FILE}"
  local target_fqdn=""
  if is_remote_install_scope; then
    target_fqdn="${AAP_REMOTE_FQDN:-${AAP_REMOTE_IP:-${REMOTE_IP:-}}}"
    if [[ -z "${target_fqdn}" ]]; then
      target_fqdn="$(get_remote_ssh_target)"
    fi
  else
    target_fqdn="$(hostname -f 2>/dev/null || hostname)"
  fi
  if [[ -z "${target_fqdn}" ]]; then
    target_fqdn="$(hostname -f 2>/dev/null || hostname)"
  fi
  local target_domain="${target_fqdn#*.}"
  local remote_user=""
  local admin_password="${AAP_ADMIN_PASSWORD:-${ADMIN_PASSWORD:-}}"
  local escaped_admin_password=""
  local remote_host=""
  local remote_bootstrap_user=""
  local remote_inventory_file=""
  local temp_inventory_file=""

  if [[ -z "${target_domain}" || "${target_domain}" == "${target_fqdn}" ]]; then
    target_domain="localdomain"
  fi

  if is_remote_install_scope; then
    remote_user="${AAP_REMOTE_USER:-admin}"
  else
    remote_user="${AAP_REMOTE_USER:-$(get_local_user)}"
  fi

  ensure_registry_credentials || true
  if [[ -z "${admin_password}" ]]; then
    if is_interactive_mode; then
      read_secret_prompt ADMIN_PASSWORD "Enter platform admin password" optional "${DEFAULT_ADMIN_PASSWORD}"
      admin_password="${ADMIN_PASSWORD}"
    else
      admin_password="${AAP_ADMIN_PASSWORD:-}"
    fi
    save_env_kv "ADMIN_PASSWORD" "${admin_password}"
    AAP_ADMIN_PASSWORD="${admin_password}"
  fi
  escaped_admin_password="$(printf '%s' "${admin_password}" | sed -e 's/[\\/&]/\\&/g')"

  if is_remote_install_scope; then
    remote_host="$(get_remote_ssh_target)"
    remote_bootstrap_user="$(get_remote_bootstrap_user)"
    remote_inventory_file="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}/inventory-growth"
    temp_inventory_file="$(mktemp "${TMPDIR:-/tmp}/inventory-growth.XXXXXX")"
    if ! run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "cat '${remote_inventory_file}'" > "${temp_inventory_file}"; then
      rm -f "${temp_inventory_file}"
      err "Unable to read inventory file from ${remote_inventory_file}"
      return 1
    fi
    inventory_file="${temp_inventory_file}"
  else
    if [[ ! -f "${inventory_file}" ]]; then
      err "Inventory file not found: ${inventory_file}"
      return 1
    fi
  fi

  ensure_inventory_baseline_backup "${inventory_file}"
  sed -E -i "s@aap\\.example\\.(com|org)@${target_fqdn}@g" "${inventory_file}"
  sed -E -i "s@(^|[^[:alnum:]_])example\\.(com|org)([^[:alnum:]_]|$)@\\1${target_domain}\\3@g" "${inventory_file}"
  sed -i "s|password=<set your own>|password={{ admin_password }}|g" "${inventory_file}"
  sed -E -i "s@\\{\\{[[:space:]]*admin_password[[:space:]]*\\}\\}@${escaped_admin_password}@g" "${inventory_file}"
  sed -i "s|collections=false|collections=true|g" "${inventory_file}"

  if ! grep -q '^\[all:vars\]' "${inventory_file}"; then
    printf '\n[all:vars]\n' >> "${inventory_file}"
  fi

  if ! grep -q '^ansible_user=' "${inventory_file}"; then
    printf 'ansible_user=%s\n' "${remote_user}" >> "${inventory_file}"
  else
    sed -i "s|^ansible_user=.*|ansible_user=${remote_user}|" "${inventory_file}"
  fi
  if ! grep -q '^ansible_become=' "${inventory_file}"; then
    printf 'ansible_become=true\n' >> "${inventory_file}"
  else
    sed -i "s|^ansible_become=.*|ansible_become=true|" "${inventory_file}"
  fi
  if ! grep -q '^ansible_become_method=' "${inventory_file}"; then
    printf 'ansible_become_method=sudo\n' >> "${inventory_file}"
  else
    sed -i "s|^ansible_become_method=.*|ansible_become_method=sudo|" "${inventory_file}"
  fi
  if is_remote_install_scope; then
    if ! grep -q '^ansible_connection=' "${inventory_file}"; then
      printf 'ansible_connection=local\n' >> "${inventory_file}"
    else
      sed -i "s|^ansible_connection=.*|ansible_connection=local|" "${inventory_file}"
    fi
  fi
  if ! grep -q '^registry_username=' "${inventory_file}"; then
    printf 'registry_username=%s\n' "${RHSM_USERNAME:-}" >> "${inventory_file}"
  else
    sed -i "s|^registry_username=.*|registry_username=${RHSM_USERNAME:-}|" "${inventory_file}"
  fi
  if ! grep -q '^registry_password=' "${inventory_file}"; then
    printf 'registry_password=%s\n' "${RHSM_PASSWORD:-}" >> "${inventory_file}"
  else
    sed -i "s|^registry_password=.*|registry_password=${RHSM_PASSWORD:-}|" "${inventory_file}"
  fi
  if ! grep -q '^redis_mode=' "${inventory_file}"; then
    printf 'redis_mode=standalone\n' >> "${inventory_file}"
  else
    sed -i "s|^redis_mode=.*|redis_mode=standalone|" "${inventory_file}"
  fi
  if ! grep -q '^postgresql_admin_password=' "${inventory_file}"; then
    printf 'postgresql_admin_password=redhat\n' >> "${inventory_file}"
  fi
  if ! grep -q '^controller_admin_password=' "${inventory_file}"; then
    printf 'controller_admin_password=redhat\n' >> "${inventory_file}"
  fi
  if ! grep -q '^controller_pg_password=' "${inventory_file}"; then
    printf 'controller_pg_password=redhat\n' >> "${inventory_file}"
  fi
  if ! grep -q '^gateway_admin_password=' "${inventory_file}"; then
    printf 'gateway_admin_password=redhat\n' >> "${inventory_file}"
  fi
  if ! grep -q '^gateway_pg_password=' "${inventory_file}"; then
    printf 'gateway_pg_password=redhat\n' >> "${inventory_file}"
  fi

  # Enforce a uniform password value while preserving RHSM registry credentials.
  sed -E -i "/^[[:space:]]*#/! { /^[[:space:]]*registry_password[[:space:]]*=/! s/^([[:space:]]*[A-Za-z0-9_]*password[A-Za-z0-9_]*[[:space:]]*=).*/\1redhat/ }" "${inventory_file}"

  if is_remote_install_scope; then
    cat "${inventory_file}" | run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "mkdir -p '$(dirname "${remote_inventory_file}")' && cat > '${remote_inventory_file}'" >/dev/null 2>&1 || return 1
    rm -f "${temp_inventory_file}"
  fi

  ok "Inventory updated ${inventory_file}"
}

get_inventory_var() {
  local inventory_file="$1"
  local key="$2"
  local raw=""
  raw="$(grep -E "^${key}=" "${inventory_file}" | tail -n1 | cut -d= -f2- || true)"
  printf '%s' "${raw}"
}

playbook_recap_is_clean() {
  local playbook_output_file="$1"
  awk '
    /^PLAY RECAP/ { in_recap=1; next }
    in_recap && /^[[:space:]]*$/ { next }
    in_recap {
      if ($0 ~ /failed=[1-9][0-9]*/ || $0 ~ /unreachable=[1-9][0-9]*/) {
        bad=1
      }
      if ($0 ~ /ok=[0-9]+/ || $0 ~ /changed=[0-9]+/) {
        saw_recap=1
      }
    }
    END {
      if (saw_recap && !bad) {
        exit 0
      }
      exit 1
    }
  ' "${playbook_output_file}"
}

run_execution_playbook() {
  local playbook_name="$1"
  local install_dir="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}"
  local ansible_verbosity=""
  local remote_user=""
  local remote_uid=""
  local controller_user=""
  local controller_home=""
  local controller_key=""
  local runtime_user=""
  local runtime_conn=""
  local runtime_become=""
  local runtime_redis_mode=""
  local runtime_host_line=""
  local remote_host=""
  local remote_bootstrap_user=""
  local remote_script=""
  local registry_user=""
  local registry_password=""
  local registry_user_q="''"
  local registry_password_q="''"
  local playbook_output_file=""
  local had_remote_force_tty=0
  local previous_remote_force_tty=""
  local -a ansible_cmd=()
  local playbook_rc=0

  load_env
  refresh_runtime_paths
  ensure_bundle_images_dir || return 1
  apply_collection_patches || return 1
  ansible_verbosity="$(normalize_ansible_verbosity "${CLI_ANSIBLE_VERBOSITY:-${ANSIBLE_VERBOSITY:-}}")"
  remote_user="${AAP_REMOTE_USER:-$(get_local_user)}"
  remote_uid="$(id -u "${remote_user}" 2>/dev/null || echo 1000)"
  controller_user="${AAP_CONTROLLER_USER:-$(whoami)}"
  controller_home="$(get_user_home "${controller_user}")"
  controller_key="${AAP_CONTROLLER_SSH_KEY:-${controller_home}/.ssh/id_ed25519}"

  if is_remote_install_scope; then
    remote_host="$(get_remote_ssh_target)"
    remote_bootstrap_user="$(get_remote_bootstrap_user)"
    install_dir="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}"
    registry_user="${RHSM_USERNAME:-}"
    registry_password="${RHSM_PASSWORD:-}"
    registry_user_q="$(shell_single_quote "${registry_user}")"
    registry_password_q="$(shell_single_quote "${registry_password}")"
    remote_script="set -euo pipefail
export PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\${PATH:-}\"
if ! command -v ansible-playbook >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    if [[ \$(id -u) -eq 0 ]]; then
      dnf install -y ansible-core >/dev/null 2>&1 || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo dnf install -y ansible-core >/dev/null 2>&1 || true
    fi
  elif command -v yum >/dev/null 2>&1; then
    if [[ \$(id -u) -eq 0 ]]; then
      yum install -y ansible-core >/dev/null 2>&1 || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo yum install -y ansible-core >/dev/null 2>&1 || true
    fi
  fi
fi
if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo 'ansible-playbook is not installed on remote host; install ansible-core and rerun.' >&2
  exit 127
fi
if ! id admin >/dev/null 2>&1; then
  echo 'admin user is required on remote host before running installer playbook' >&2
  exit 126
fi
admin_uid=\"\$(id -u admin 2>/dev/null || echo 0)\"
if [[ \"\${admin_uid}\" -eq 0 ]]; then
  echo 'admin user must be non-root (uid != 0)' >&2
  exit 126
fi
admin_home=\$(getent passwd admin | cut -d: -f6 || true)
admin_home=\${admin_home:-/home/admin}
admin_auth_file=\${admin_home}/.config/containers/auth.json
run_as_admin=''
if [[ \"\$(id -un)\" != \"admin\" ]]; then
  if command -v sudo >/dev/null 2>&1; then
    run_as_admin='sudo -H -u admin'
  elif command -v runuser >/dev/null 2>&1; then
    run_as_admin='runuser -u admin --'
  else
    echo 'unable to switch execution context to admin (sudo/runuser missing)' >&2
    exit 126
  fi
fi
registry_user=${registry_user_q}
registry_password=${registry_password_q}
if [[ -z "\${registry_user}" || -z "\${registry_password}" ]]; then
  echo 'Registry credentials are empty. Set RHSM_USERNAME/RHSM_PASSWORD.' >&2
  exit 124
fi
if ! \${run_as_admin} mkdir -p "\${admin_home}/.config/containers" >/dev/null 2>&1; then
  echo 'Unable to prepare admin container auth directory.' >&2
  exit 125
fi
cd "\${admin_home}"
login_err_file=\$(mktemp /tmp/aap27_podman_login.XXXXXX 2>/dev/null || true)
if [[ -z \${login_err_file} ]]; then
  login_err_file=/tmp/aap27_podman_login.err
fi
login_ok=0
if printf '%s\n' "\${registry_password}" | \${run_as_admin} env HOME=\${admin_home} podman login --authfile "\${admin_auth_file}" --username "\${registry_user}" --password-stdin registry.redhat.io >/dev/null 2>\${login_err_file}; then
  login_ok=1
fi
if [[ \${login_ok} -ne 1 ]]; then
  if printf '%s\n' "\${registry_password}" | \${run_as_admin} env HOME=\${admin_home} podman login --username "\${registry_user}" --password-stdin registry.redhat.io >/dev/null 2>>\${login_err_file}; then
    login_ok=1
  fi
fi
if [[ \${login_ok} -ne 1 ]]; then
  login_reason=\$(tail -n 3 \${login_err_file} 2>/dev/null | tr -d '\\r' | tr '\\n' ' ')
  rm -f \${login_err_file} >/dev/null 2>&1 || true
  if [[ -n \${login_reason} ]]; then
    echo Podman login to registry.redhat.io failed for admin user: \${login_reason} >&2
  else
    echo 'Podman login to registry.redhat.io failed for admin user. Using RHSM credentials from installer environment.' >&2
  fi
  exit 125
fi
rm -f \${login_err_file} >/dev/null 2>&1 || true
cd '${install_dir}'
  \${run_as_admin} env HOME=\${admin_home} REGISTRY_AUTH_FILE=\${admin_auth_file} ANSIBLE_FORCE_COLOR=True PY_COLORS=1 ANSIBLE_NOCOLOR=False ANSIBLE_SSH_ARGS='' ANSIBLE_DEPRECATION_WARNINGS=False ansible-playbook ${ansible_verbosity} -i inventory-growth -c local -e 'ansible_connection=local' -e 'ansible_host=127.0.0.1' -e 'ansible_user=admin' -e \"ansible_user_uid=\${admin_uid}\" -e 'ansible_ssh_common_args=' -e 'redis_mode=standalone' -e 'bundle_dir=${install_dir}/bundle' -e \"registry_username=\${registry_user}\" -e \"registry_password=\${registry_password}\" -e \"registry_auth_file=\${admin_auth_file}\" 'ansible.containerized_installer.${playbook_name}'"
    if [[ -n "${AAP_REMOTE_FORCE_TTY+x}" ]]; then
      had_remote_force_tty=1
      previous_remote_force_tty="${AAP_REMOTE_FORCE_TTY}"
    fi
    AAP_REMOTE_FORCE_TTY=1
    playbook_output_file="$(mktemp "${TMPDIR:-/tmp}/aap27_playbook_remote.XXXXXX")"
    if run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "${remote_script}" | tee "${playbook_output_file}"; then
      playbook_rc=0
    else
      playbook_rc=$?
    fi
    if [[ ${playbook_rc} -ne 0 ]] && playbook_recap_is_clean "${playbook_output_file}"; then
      warn "Playbook command returned rc=${playbook_rc} but PLAY RECAP shows no failed/unreachable hosts; treating as success"
      playbook_rc=0
    fi
    rm -f "${playbook_output_file}"
    if [[ ${had_remote_force_tty} -eq 1 ]]; then
      AAP_REMOTE_FORCE_TTY="${previous_remote_force_tty}"
    else
      unset AAP_REMOTE_FORCE_TTY
    fi
    return "${playbook_rc}"
  fi

  if [[ ! -d "${install_dir}" ]] || [[ ! -f "${install_dir}/inventory-growth" ]]; then
    err "Bundle install directory missing: ${install_dir}"
    return 1
  fi

  log "Playbook verbosity: ${ansible_verbosity:-none}"

  ensure_registry_credentials || true
  modify_inventory_growth
  run_podman_user_bus_fix "${remote_user}" "${RHSM_USERNAME:-}" "${RHSM_PASSWORD:-}" >/dev/null 2>&1 || true
  if [[ "${playbook_name}" == "install_standalone_mcp" ]]; then
    ensure_mcp_container_images "${remote_user}" >/dev/null 2>&1 || true
  fi

  runtime_host_line="$(awk '/^[[:space:]]*#/ || /^\[/ || /^[[:space:]]*$/ { next } { print; exit }' "${install_dir}/inventory-growth")"
  runtime_user="$(get_inventory_var "${install_dir}/inventory-growth" ansible_user)"
  runtime_become="$(get_inventory_var "${install_dir}/inventory-growth" ansible_become)"
  runtime_conn="$(get_inventory_var "${install_dir}/inventory-growth" ansible_connection)"
  runtime_redis_mode="$(get_inventory_var "${install_dir}/inventory-growth" redis_mode)"

  echo
  echo "Collected runtime settings:"
  echo "  Host line: ${runtime_host_line:-<not-found>}"
  echo "  Connection: ${runtime_conn:-unset}"
  echo "  Remote user: ${runtime_user:-unset}"
  echo "  Become: ${runtime_become:-unset}"
  echo "  Redis mode: ${runtime_redis_mode:-unset}"
  echo

  if is_interactive_mode; then
    read -r -p "Proceed to run playbook ${playbook_name}? [Y/n]: " proceed_choice
    if [[ "${proceed_choice:-Y}" =~ ^[Nn]$ ]]; then
      warn "Playbook execution cancelled"
      return 0
    fi
  fi

  log "Starting playbook execution: ${playbook_name}"
  playbook_output_file="$(mktemp "${TMPDIR:-/tmp}/aap27_playbook_local.XXXXXX")"
  (
    cd "${install_dir}"
    ansible_cmd=(ansible-playbook)
    if [[ -n "${ansible_verbosity}" ]]; then
      ansible_cmd+=("${ansible_verbosity}")
    fi
    ansible_cmd+=(
      -i inventory-growth
      -u "${remote_user}"
      -c ssh
      -e "ansible_user=${remote_user}"
      -e "ansible_user_uid=${remote_uid}"
      -e "ansible_connection=ssh"
      -e "ansible_ssh_common_args=-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
      -e "redis_mode=standalone"
      -e "bundle_dir=${install_dir}/bundle"
      -e "registry_username=${RHSM_USERNAME:-}"
      -e "registry_password=${RHSM_PASSWORD:-}"
      "ansible.containerized_installer.${playbook_name}"
    )
    if [[ -f "${controller_key}" ]]; then
      ansible_cmd+=(--private-key "${controller_key}")
      ansible_cmd+=(-e "ansible_ssh_private_key_file=${controller_key}")
    fi
    env ANSIBLE_FORCE_COLOR=True PY_COLORS=1 ANSIBLE_NOCOLOR=False ANSIBLE_DEPRECATION_WARNINGS=False "${ansible_cmd[@]}"
  ) | tee "${playbook_output_file}"
  playbook_rc=$?
  if [[ ${playbook_rc} -ne 0 ]] && playbook_recap_is_clean "${playbook_output_file}"; then
    warn "Playbook command returned rc=${playbook_rc} but PLAY RECAP shows no failed/unreachable hosts; treating as success"
    playbook_rc=0
  fi
  rm -f "${playbook_output_file}"
  return "${playbook_rc}"
}

preflight_dependency_checks() {
  log "Checking prereqs"
  command -v ansible-playbook >/dev/null 2>&1 || warn "ansible-playbook not found"
  command -v podman >/dev/null 2>&1 || warn "podman not found"
  command -v ssh >/dev/null 2>&1 || warn "ssh not found"
  command -v tar >/dev/null 2>&1 || warn "tar not found"

  if is_remote_install_scope; then
    local remote_host=""
    local target_user=""
    local bootstrap_user=""
    local attempt_user=""
    local ssh_ok_user=""
    local -a attempt_users=()
    local remote_attempt_output=""
    local registration_script=""
    local registration_payload=""

    remote_host="$(get_remote_ssh_target)"
    target_user="$(get_remote_ssh_user)"
    bootstrap_user="$(get_remote_bootstrap_user)"

    if [[ -n "${target_user}" ]]; then
      attempt_users+=("${target_user}")
    fi
    if [[ -n "${bootstrap_user}" && "${bootstrap_user}" != "${target_user}" ]]; then
      attempt_users+=("${bootstrap_user}")
    fi
    if [[ " ${attempt_users[*]} " != *" admin "* ]]; then
      attempt_users+=("admin")
    fi

    for attempt_user in "${attempt_users[@]}"; do
      if run_remote_command "${remote_host}" "${attempt_user}" true >/dev/null 2>&1; then
        ssh_ok_user="${attempt_user}"
        break
      fi
      remote_attempt_output="$(run_remote_command "${remote_host}" "${attempt_user}" true 2>&1 || true)"
      if printf '%s' "${remote_attempt_output}" | grep -qiE 'connection refused|no route to host|operation timed out|connection timed out'; then
        err "Remote SSH is unreachable at ${remote_host}:22 (${remote_attempt_output})"
        err "Start the remote VM, ensure sshd is running, and verify port 22 is reachable before re-running the installer."
        return 1
      fi
    done

    if [[ -z "${ssh_ok_user}" ]]; then
      err "Unable to authenticate to remote host ${remote_host} using configured SSH users (${attempt_users[*]})."
      err "Verify credentials and SSH access, then re-run the installer."
      return 1
    fi

    if ! run_remote_command "${remote_host}" "${ssh_ok_user}" bash --noprofile --norc -c "command -v subscription-manager >/dev/null 2>&1 || command -v rhc >/dev/null 2>&1" >/dev/null 2>&1; then
      err "Neither subscription-manager nor rhc is available on remote host ${remote_host}."
      err "Install one of them and re-run the installer."
      return 1
    fi

    if ! run_remote_command "${remote_host}" "${ssh_ok_user}" bash --noprofile --norc -c "set -euo pipefail; priv=''; if [[ \$(id -u) -ne 0 ]] && command -v sudo >/dev/null 2>&1; then priv='sudo'; fi; if command -v subscription-manager >/dev/null 2>&1; then if \${priv} subscription-manager identity >/dev/null 2>&1; then exit 0; fi; fi; if command -v rhc >/dev/null 2>&1; then rhc_out=\"\$(\${priv} rhc status 2>&1 || true)\"; if printf '%s\n' \"\${rhc_out}\" | grep -qiE 'overall status:[[:space:]]*connected|this system is connected|connected to red hat'; then exit 0; fi; fi; exit 1" >/dev/null 2>&1; then
      warn "Remote host ${remote_host} is not registered with RHSM; attempting registration using configured credentials"
      registration_script="set -euo pipefail
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:'\"\${PATH:-}\"
priv=''
if [[ \$(id -u) -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    priv='sudo'
  else
    echo 'sudo is required for RHSM registration when not root' >&2
    exit 50
  fi
fi
have_subman=0
have_rhc=0
if command -v subscription-manager >/dev/null 2>&1; then
  have_subman=1
fi
if command -v rhc >/dev/null 2>&1; then
  have_rhc=1
fi
if [[ \${have_subman} -eq 0 && \${have_rhc} -eq 0 ]]; then
  echo 'neither subscription-manager nor rhc is installed on remote host' >&2
  exit 51
fi

if [[ -n \"\${RHSM_ORG_ID:-}\" && -n \"\${RHSM_ACTIVATION_KEY:-}\" && \${have_rhc} -eq 1 ]]; then
  if ! \${priv} dnf -y install rhc-worker-playbook >/dev/null 2>&1; then
    if ! \${priv} yum -y install rhc-worker-playbook >/dev/null 2>&1; then
      echo 'failed to install rhc-worker-playbook required for rhc connect' >&2
      exit 53
    fi
  fi
  \${priv} rhc connect --activation-key \"\${RHSM_ACTIVATION_KEY}\" --organization \"\${RHSM_ORG_ID}\"
elif [[ -n \"\${RHSM_ORG_ID:-}\" && -n \"\${RHSM_ACTIVATION_KEY:-}\" && \${have_subman} -eq 1 ]]; then
  \${priv} subscription-manager register --org=\"\${RHSM_ORG_ID}\" --activationkey=\"\${RHSM_ACTIVATION_KEY}\" --force
elif [[ -n \"\${RHSM_USERNAME:-}\" && -n \"\${RHSM_PASSWORD:-}\" && \${have_subman} -eq 1 ]]; then
  register_extra_opts='--force'
  if subscription-manager register --help 2>/dev/null | grep -q -- '--auto-attach'; then
    register_extra_opts='--auto-attach --force'
  fi
  \${priv} subscription-manager register --username \"\${RHSM_USERNAME}\" --password \"\${RHSM_PASSWORD}\" \${register_extra_opts}
else
  echo 'missing supported RHSM registration method (RHEL10: RHSM_ORG_ID + RHSM_ACTIVATION_KEY with rhc, legacy: RHSM_USERNAME + RHSM_PASSWORD with subscription-manager)' >&2
  exit 52
fi"
      registration_payload="RHSM_USERNAME=$(shell_single_quote "${RHSM_USERNAME:-}")
RHSM_ORG_ID=$(shell_single_quote "${RHSM_ORG_ID:-}")
RHSM_ACTIVATION_KEY=$(shell_single_quote "${RHSM_ACTIVATION_KEY:-}")
export RHSM_USERNAME RHSM_PASSWORD RHSM_ORG_ID RHSM_ACTIVATION_KEY
${registration_script}"
      local registration_output=""
      local registration_reason=""
      local registration_rc=0
      if registration_output="$(printf '%s\n' "${registration_payload}" | run_remote_command "${remote_host}" "${ssh_ok_user}" bash --noprofile --norc -s 2>&1)"; then
        registration_rc=0
      else
        registration_rc=$?
      fi
      if [[ -n "${registration_output}" ]]; then
        registration_reason="$(printf '%s\n' "${registration_output}" | tail -n 2 | tr -d '\r' | tr '\n' ' ' | sed -E 's#(https?://[^ ?]+)\?[^ ]+#\1?REDACTED#g; s#(Authorization:[[:space:]]*Bearer[[:space:]]+)[^ ]+#\1REDACTED#g; s#(RHSM_OFFLINE_TOKEN=)[^ ]+#\1REDACTED#g; s#(RHSM_PASSWORD=)[^ ]+#\1REDACTED#g; s#(RHSM_ACTIVATION_KEY=)[^ ]+#\1REDACTED#g; s#(--password[[:space:]]+)[^[:space:]]+#\1REDACTED#g; s#(--activation-key[[:space:]]+)[^[:space:]]+#\1REDACTED#g')"
      fi
      if [[ ${registration_rc} -ne 0 ]]; then
        err "Remote host ${remote_host} is not registered with RHSM."
        if [[ -n "${registration_reason}" ]]; then
          err "Registration attempt detail: ${registration_reason}"
        fi
        err "Set RHSM credentials in ${ENV_FILE} and re-run the installer."
        return 1
      fi
      if ! run_remote_command "${remote_host}" "${ssh_ok_user}" bash --noprofile --norc -c "set -euo pipefail; priv=''; if [[ \$(id -u) -ne 0 ]] && command -v sudo >/dev/null 2>&1; then priv='sudo'; fi; if command -v subscription-manager >/dev/null 2>&1; then if \${priv} subscription-manager identity >/dev/null 2>&1; then exit 0; fi; fi; if command -v rhc >/dev/null 2>&1; then rhc_out=\"\$(\${priv} rhc status 2>&1 || true)\"; if printf '%s\n' \"\${rhc_out}\" | grep -qiE 'overall status:[[:space:]]*connected|this system is connected|connected to red hat'; then exit 0; fi; fi; exit 1" >/dev/null 2>&1; then
        err "Remote host ${remote_host} registration check still failed after registration attempt."
        err "Verify RHSM entitlement/credentials and re-run the installer."
        return 1
      fi
      ok "Remote host ${remote_host} registered with RHSM during preflight"
    fi

    ok "Remote host ${remote_host} passed SSH and RHSM registration preflight checks"
    return 0
  fi
}

setup_admin_user() {
  if ensure_admin_user_exists; then
    ensure_user_home_ownership admin
    ensure_user_dbus_session admin >/dev/null 2>&1 || true
    ensure_admin_ansible_access
    ok "Admin user setup complete"
  else
    if is_remote_install_scope; then
      err "Admin user setup incomplete on remote host; aborting"
      return 1
    fi
    warn "Admin user setup incomplete; continuing"
  fi
}

ensure_admin_ansible_access() {
  if ! is_remote_install_scope; then
    return 0
  fi

  local remote_host="$(get_remote_ssh_target)"
  local remote_bootstrap_user="$(get_remote_bootstrap_user)"

  if ! run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "set -euo pipefail
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:'\"\${PATH:-}\"
as_admin() {
  if command -v sudo >/dev/null 2>&1; then
    sudo -u admin \"\$@\"
  elif [[ \$(id -u) -eq 0 ]] && command -v runuser >/dev/null 2>&1; then
    runuser -u admin -- \"\$@\"
  elif [[ \$(id -u) -eq 0 ]] && command -v su >/dev/null 2>&1; then
    su - admin -s /bin/bash -c \"\$*\"
  else
    return 1
  fi
}
if ! id admin >/dev/null 2>&1; then
  echo 'admin user is missing on remote host' >&2
  exit 1
fi
if [[ \$(id -u) -eq 0 ]]; then
  mkdir -p /home/admin/.ansible /home/admin/.ansible/tmp /home/admin/.ansible/cp
  chown -R admin:admin /home/admin/.ansible >/dev/null 2>&1 || true
else
  if command -v sudo >/dev/null 2>&1; then
    sudo mkdir -p /home/admin/.ansible /home/admin/.ansible/tmp /home/admin/.ansible/cp
    sudo chown -R admin:admin /home/admin/.ansible >/dev/null 2>&1 || true
  fi
fi
if ! as_admin command -v ansible-playbook >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    if [[ \$(id -u) -eq 0 ]]; then
      dnf install -y ansible-core >/dev/null 2>&1 || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo dnf install -y ansible-core >/dev/null 2>&1 || true
    fi
  elif command -v yum >/dev/null 2>&1; then
    if [[ \$(id -u) -eq 0 ]]; then
      yum install -y ansible-core >/dev/null 2>&1 || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo yum install -y ansible-core >/dev/null 2>&1 || true
    fi
  elif command -v microdnf >/dev/null 2>&1; then
    if [[ \$(id -u) -eq 0 ]]; then
      microdnf install -y ansible-core >/dev/null 2>&1 || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo microdnf install -y ansible-core >/dev/null 2>&1 || true
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    if [[ \$(id -u) -eq 0 ]]; then
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y ansible-core >/dev/null 2>&1 || apt-get install -y ansible >/dev/null 2>&1 || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -y >/dev/null 2>&1 || true
      sudo apt-get install -y ansible-core >/dev/null 2>&1 || sudo apt-get install -y ansible >/dev/null 2>&1 || true
    fi
  fi
fi
if ! as_admin command -v ansible-playbook >/dev/null 2>&1; then
  echo 'ansible-playbook is still unavailable for admin user' >&2
  exit 1
fi
if ! as_admin ansible-playbook --version >/dev/null 2>&1; then
  echo 'admin user cannot execute ansible-playbook' >&2
  exit 1
fi
if ! as_admin command -v podman >/dev/null 2>&1; then
  echo 'podman is unavailable for admin user' >&2
  exit 1
fi" >/dev/null 2>&1; then
    err "Unable to grant admin user Ansible/Podman execution capability on ${remote_host}"
    err "Ensure admin has sudo privileges and ansible-core/podman are installable on ${remote_host}, then rerun"
    return 1
  fi

  ok "Admin user can run ansible-playbook and podman on ${remote_host}"
}

capture_credentials() {
  ensure_registry_credentials || true
  if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
    if is_interactive_mode; then
      read_secret_prompt ADMIN_PASSWORD "Enter platform admin password" optional "${DEFAULT_ADMIN_PASSWORD}"
      save_env_kv "ADMIN_PASSWORD" "${ADMIN_PASSWORD}"
    else
      warn "ADMIN_PASSWORD not supplied; continuing without it"
    fi
  fi
}

download_bundle() {
  refresh_runtime_paths
  local bundle_path="${DOWNLOAD_DIR}/${BUNDLE_FILE}"
  local bundle_url="${BUNDLE_URL:-${BUNDLE_URL_DEFAULT}}"
  local content_type=""
  local download_target="${DOWNLOAD_DIR}/.${BUNDLE_FILE}.download"
  local final_target="${bundle_path}"
  local -a download_attempts=()
  local -a command_args=()
  local attempt_label=""
  local candidate_url=""
  local candidate_name=""
  local candidate_bundle_file=""
  local candidate_bundle_dir=""
  local remote_host=""
  local remote_candidate_urls=()
  local remote_auth_mode=""
  local -a remote_auth_modes=()
  local remote_auth_modes_text=""
  local remote_has_auth_mode=0
  local remote_bootstrap_user=""
  local remote_download_user=""
  local remote_download_dir=""
  local remote_download_target=""
  local remote_bundle_path=""
  local remote_script=""
  local remote_rc=1
  local had_xtrace=0
  local remote_attempt_output=""
  local remote_payload=""
  local progress_enabled=0
  local auth_mode_preference="${AAP_DOWNLOAD_AUTH_MODE:-auto}"
  local remote_last_error=""
  local remote_reason_line=""
  local remote_mime=""
  local remote_is_portal=""
  local remote_head_snippet=""
  local remote_preflight_script=""
  local remote_preflight_payload=""
  local remote_preflight_output=""
  local remote_preflight_http_code=""
  local remote_preflight_content_type=""
  local remote_preflight_effective_url=""
  local remote_preflight_fail=""
  local remote_detected_root=""
  local detected_root=""
  local controller_bundle_path=""
  local scp_password=""
  local -a scp_args=()
  local -a scp_cmd=(scp)
  local local_fallback_ready=0
  local controller_detected_root=""
  local remote_extract_dir_guess=""
  local had_sshpass=0
  local previous_sshpass=""
  local controller_bundle_checksum=""
  local remote_bundle_checksum=""
  if bundle_url_points_to_error_page "${bundle_url}"; then
    err "Bundle URL points to a Red Hat access error page instead of an archive: ${bundle_url}"
    err "Use the actual bundle download URL from the portal, not the /downloads/content/error?code=403 redirect target."
    err "If you copied the URL into a shell command, wrap it in single quotes so '&' does not split the command into background jobs."
    return 1
  fi
  if [[ "${AAP_DOWNLOAD_PROGRESS:-0}" == "1" && -t 1 ]]; then
    progress_enabled=1
  fi
  if ! is_remote_install_scope; then
    mkdir -p "${DOWNLOAD_DIR}"
    : > "${bundle_path}"
  fi
  if [[ -f "${bundle_path}" ]]; then
    if validate_bundle_archive "${bundle_path}"; then
      ok "Using existing bundle archive"
      return 0
    fi
    warn "Existing bundle archive is invalid or incomplete; re-downloading"
    rm -f "${bundle_path}"
  fi

  if is_remote_install_scope; then
    remote_host="$(get_remote_ssh_target)"
    remote_bootstrap_user="$(get_remote_bootstrap_user)"
    remote_download_user="$(get_remote_ssh_user)"
    if [[ -z "${remote_download_user}" ]]; then
      remote_download_user="admin"
    fi
    if ! run_remote_command "${remote_host}" "${remote_download_user}" true >/dev/null 2>&1; then
      remote_download_user="${remote_bootstrap_user}"
    fi
    remote_download_dir="${REMOTE_DOWNLOAD_DIR_DEFAULT}"
    remote_download_target="${remote_download_dir}/.${BUNDLE_FILE}.download"
    remote_bundle_path="${remote_download_dir}/${BUNDLE_FILE}"
    remote_candidate_urls=("${bundle_url}" "${BUNDLE_URL_CANDIDATES[@]}")
    case "${auth_mode_preference}" in
      basic-auth)
        if [[ -n "${RHSM_USERNAME:-}" && -n "${RHSM_PASSWORD:-}" ]]; then
          remote_auth_modes+=("basic-auth")
        else
          err "AAP_DOWNLOAD_AUTH_MODE=basic-auth requires RHSM_USERNAME and RHSM_PASSWORD"
          return 1
        fi
        ;;
      bearer)
        if [[ -n "${RHSM_OFFLINE_TOKEN:-}" ]]; then
          remote_auth_modes+=("bearer")
        else
          err "AAP_DOWNLOAD_AUTH_MODE=bearer requires RHSM_OFFLINE_TOKEN"
          return 1
        fi
        ;;
      basic-token)
        if [[ -n "${RHSM_USERNAME:-}" && -n "${RHSM_OFFLINE_TOKEN:-}" ]]; then
          remote_auth_modes+=("basic-token")
        else
          err "AAP_DOWNLOAD_AUTH_MODE=basic-token requires RHSM_USERNAME and RHSM_OFFLINE_TOKEN"
          return 1
        fi
        ;;
      anonymous)
        remote_auth_modes+=("anonymous")
        ;;
      auto|*)
        if [[ -n "${RHSM_USERNAME:-}" && -n "${RHSM_PASSWORD:-}" ]]; then
          remote_auth_modes+=("basic-auth")
          remote_has_auth_mode=1
        fi
        if [[ -n "${RHSM_OFFLINE_TOKEN:-}" ]]; then
          remote_auth_modes+=("bearer")
          remote_has_auth_mode=1
        fi
        if [[ ${remote_has_auth_mode} -eq 0 || "${AAP_ALLOW_ANON_DOWNLOAD:-0}" == "1" ]]; then
          remote_auth_modes+=("anonymous")
        fi
        ;;
    esac
    remote_auth_modes_text="$(IFS=, ; echo "${remote_auth_modes[*]}")"
    for candidate_url in "${remote_candidate_urls[@]}"; do
      for remote_auth_mode in "${remote_auth_modes[@]}"; do
        remote_preflight_script="set -euo pipefail
if ! command -v curl >/dev/null 2>&1; then
  echo 'AAP_PRECHECK_SKIP=no-curl'
  exit 0
fi
case \"\${REMOTE_AUTH_MODE:-anonymous}\" in
  basic-auth)
    preflight_out=\"\$(curl -sS -L -o /dev/null -D - --retry 2 --retry-delay 3 --connect-timeout 30 --max-time 120 -u \"\${RHSM_USERNAME}:\${RHSM_PASSWORD}\" \"\${BUNDLE_URL}\" -w $'\\nAAP_PRECHECK_HTTP_CODE=%{http_code}\\nAAP_PRECHECK_CONTENT_TYPE=%{content_type}\\nAAP_PRECHECK_EFFECTIVE_URL=%{url_effective}\\n')\"
    ;;
  bearer)
    preflight_out=\"\$(curl -sS -L -o /dev/null -D - --retry 2 --retry-delay 3 --connect-timeout 30 --max-time 120 -H \"Authorization: Bearer \${RHSM_OFFLINE_TOKEN}\" -H 'X-Requested-With: XMLHttpRequest' \"\${BUNDLE_URL}\" -w $'\\nAAP_PRECHECK_HTTP_CODE=%{http_code}\\nAAP_PRECHECK_CONTENT_TYPE=%{content_type}\\nAAP_PRECHECK_EFFECTIVE_URL=%{url_effective}\\n')\"
    ;;
  basic-token)
    preflight_out=\"\$(curl -sS -L -o /dev/null -D - --retry 2 --retry-delay 3 --connect-timeout 30 --max-time 120 -u \"\${RHSM_USERNAME}:\${RHSM_OFFLINE_TOKEN}\" \"\${BUNDLE_URL}\" -w $'\\nAAP_PRECHECK_HTTP_CODE=%{http_code}\\nAAP_PRECHECK_CONTENT_TYPE=%{content_type}\\nAAP_PRECHECK_EFFECTIVE_URL=%{url_effective}\\n')\"
    ;;
  anonymous|*)
    preflight_out=\"\$(curl -sS -L -o /dev/null -D - --retry 2 --retry-delay 3 --connect-timeout 30 --max-time 120 \"\${BUNDLE_URL}\" -w $'\\nAAP_PRECHECK_HTTP_CODE=%{http_code}\\nAAP_PRECHECK_CONTENT_TYPE=%{content_type}\\nAAP_PRECHECK_EFFECTIVE_URL=%{url_effective}\\n')\"
    ;;
esac
printf '%s\\n' \"\${preflight_out}\" | grep -E '^AAP_PRECHECK_(HTTP_CODE|CONTENT_TYPE|EFFECTIVE_URL)=' || true
http_code=\"\$(printf '%s\\n' \"\${preflight_out}\" | sed -n 's/^AAP_PRECHECK_HTTP_CODE=//p' | tail -n1)\"
content_type=\"\$(printf '%s\\n' \"\${preflight_out}\" | sed -n 's/^AAP_PRECHECK_CONTENT_TYPE=//p' | tail -n1)\"
effective_url=\"\$(printf '%s\\n' \"\${preflight_out}\" | sed -n 's/^AAP_PRECHECK_EFFECTIVE_URL=//p' | tail -n1)\"
if [[ \"\${effective_url}\" == *'/downloads/content/error?code=403'* ]] || [[ \"\${http_code}\" == '403' ]]; then
  echo 'AAP_PRECHECK_FAIL=403'
  exit 42
fi
if [[ \"\${content_type}\" == text/html* ]] && [[ \"\${effective_url}\" == *'access.redhat.com'* ]]; then
  echo 'AAP_PRECHECK_FAIL=portal-html'
  exit 43
fi"
        remote_preflight_payload="REMOTE_AUTH_MODE=$(shell_single_quote "${remote_auth_mode}")
BUNDLE_URL=$(shell_single_quote "${candidate_url}")
RHSM_USERNAME=$(shell_single_quote "${RHSM_USERNAME:-}")
RHSM_PASSWORD=$(shell_single_quote "${RHSM_PASSWORD:-}")
RHSM_OFFLINE_TOKEN=$(shell_single_quote "${RHSM_OFFLINE_TOKEN:-}")
export REMOTE_AUTH_MODE BUNDLE_URL RHSM_USERNAME RHSM_PASSWORD RHSM_OFFLINE_TOKEN
${remote_preflight_script}"
        remote_preflight_output="$(printf '%s\n' "${remote_preflight_payload}" | run_remote_command "${remote_host}" "${remote_download_user}" bash --noprofile --norc -s 2>&1)"
        remote_rc=$?
        remote_preflight_http_code="$(printf '%s\n' "${remote_preflight_output}" | sed -n 's/^AAP_PRECHECK_HTTP_CODE=//p' | tail -n1 | tr -d '\r')"
        remote_preflight_content_type="$(printf '%s\n' "${remote_preflight_output}" | sed -n 's/^AAP_PRECHECK_CONTENT_TYPE=//p' | tail -n1 | tr -d '\r')"
        remote_preflight_effective_url="$(printf '%s\n' "${remote_preflight_output}" | sed -n 's/^AAP_PRECHECK_EFFECTIVE_URL=//p' | tail -n1 | tr -d '\r')"
        remote_preflight_fail="$(printf '%s\n' "${remote_preflight_output}" | sed -n 's/^AAP_PRECHECK_FAIL=//p' | tail -n1 | tr -d '\r')"
        if [[ ${remote_rc} -ne 0 ]] && [[ -n "${remote_preflight_fail}" ]]; then
          if [[ "${remote_preflight_fail}" == "403" ]]; then
            if [[ "${remote_preflight_effective_url}" == *'/downloads/content/error?code=403'* ]]; then
              remote_last_error="remote preflight returned Red Hat access error page after redirect (mode=${remote_auth_mode}, http=${remote_preflight_http_code:-403}, type=${remote_preflight_content_type:-unknown}, url=${remote_preflight_effective_url:-${candidate_url}})"
            else
              remote_last_error="remote preflight blocked by entitlement/auth redirect (mode=${remote_auth_mode}, http=${remote_preflight_http_code:-403}, type=${remote_preflight_content_type:-unknown}, url=${remote_preflight_effective_url:-${candidate_url}})"
            fi
            if [[ "${remote_auth_mode}" == "basic-token" ]]; then
              remote_last_error+="; AAP_DOWNLOAD_AUTH_MODE=basic-token is not suitable for this download endpoint; use bearer or basic-auth"
            fi
          elif [[ "${remote_preflight_fail}" == "portal-html" ]]; then
            remote_last_error="remote preflight returned portal HTML instead of archive (mode=${remote_auth_mode}, type=${remote_preflight_content_type:-text/html}, url=${remote_preflight_effective_url:-${candidate_url}})"
          fi
          continue
        fi

        remote_script="set -euo pipefail
progress_opt=''
if [[ \"\${REMOTE_PROGRESS:-0}\" == \"1\" ]]; then
  progress_opt='--progress-bar'
fi
use_wget_progress=0
if [[ \"\${REMOTE_PROGRESS:-0}\" == \"1\" ]] && command -v wget >/dev/null 2>&1; then
  use_wget_progress=1
fi
mkdir -p '${remote_download_dir}'
        rm -f '${remote_download_target}' || true
case \"\${REMOTE_AUTH_MODE:-anonymous}\" in
  basic-auth)
    if [[ \${use_wget_progress} -eq 1 ]]; then
      wget --show-progress --progress=bar:force:noscroll --tries=5 --timeout=60 --user=\"\${RHSM_USERNAME}\" --password=\"\${RHSM_PASSWORD}\" -O '${remote_download_target}' '${candidate_url}'
    else
      curl \${progress_opt} -fL -C - --retry 5 --retry-delay 30 --connect-timeout 60 --max-time 7200 -u \"\${RHSM_USERNAME}:\${RHSM_PASSWORD}\" -o '${remote_download_target}' '${candidate_url}'
    fi
    ;;
  bearer)
    if [[ \${use_wget_progress} -eq 1 ]]; then
      wget --show-progress --progress=bar:force:noscroll --tries=5 --timeout=60 --header=\"Authorization: Bearer \${RHSM_OFFLINE_TOKEN}\" --header='X-Requested-With: XMLHttpRequest' -O '${remote_download_target}' '${candidate_url}'
    else
      curl \${progress_opt} -fL -C - --retry 5 --retry-delay 30 --connect-timeout 60 --max-time 7200 -H \"Authorization: Bearer \${RHSM_OFFLINE_TOKEN}\" -H 'X-Requested-With: XMLHttpRequest' -o '${remote_download_target}' '${candidate_url}'
    fi
    ;;
  basic-token)
    if [[ \${use_wget_progress} -eq 1 ]]; then
      wget --show-progress --progress=bar:force:noscroll --tries=5 --timeout=60 --user=\"\${RHSM_USERNAME}\" --password=\"\${RHSM_OFFLINE_TOKEN}\" -O '${remote_download_target}' '${candidate_url}'
    else
      curl \${progress_opt} -fL -C - --retry 5 --retry-delay 30 --connect-timeout 60 --max-time 7200 -u \"\${RHSM_USERNAME}:\${RHSM_OFFLINE_TOKEN}\" -o '${remote_download_target}' '${candidate_url}'
    fi
    ;;
  anonymous|*)
    if [[ \${use_wget_progress} -eq 1 ]]; then
      wget --show-progress --progress=bar:force:noscroll --tries=5 --timeout=60 -O '${remote_download_target}' '${candidate_url}'
    else
      curl \${progress_opt} -fL -C - --retry 5 --retry-delay 30 --connect-timeout 60 --max-time 7200 -o '${remote_download_target}' '${candidate_url}'
    fi
    ;;
esac
mv -f '${remote_download_target}' '${remote_bundle_path}'"
        case "$-" in
          *x*)
            had_xtrace=1
            set +x
            ;;
          *) had_xtrace=0 ;;
        esac
        remote_payload="REMOTE_AUTH_MODE=$(shell_single_quote "${remote_auth_mode}")
REMOTE_PROGRESS=$(shell_single_quote "${progress_enabled}")
BUNDLE_URL=$(shell_single_quote "${candidate_url}")
REMOTE_DOWNLOAD_DIR=$(shell_single_quote "${remote_download_dir}")
REMOTE_DOWNLOAD_TARGET=$(shell_single_quote "${remote_download_target}")
REMOTE_BUNDLE_PATH=$(shell_single_quote "${remote_bundle_path}")
RHSM_USERNAME=$(shell_single_quote "${RHSM_USERNAME:-}")
RHSM_PASSWORD=$(shell_single_quote "${RHSM_PASSWORD:-}")
RHSM_OFFLINE_TOKEN=$(shell_single_quote "${RHSM_OFFLINE_TOKEN:-}")
export REMOTE_AUTH_MODE REMOTE_PROGRESS BUNDLE_URL REMOTE_DOWNLOAD_DIR REMOTE_DOWNLOAD_TARGET REMOTE_BUNDLE_PATH RHSM_USERNAME RHSM_PASSWORD RHSM_OFFLINE_TOKEN
${remote_script}"
        if [[ ${progress_enabled} -eq 1 ]]; then
          printf '%s\n' "${remote_payload}" | run_remote_command "${remote_host}" "${remote_download_user}" bash --noprofile --norc -s
          remote_rc=$?
          remote_attempt_output=""
        else
          remote_attempt_output="$(printf '%s\n' "${remote_payload}" | run_remote_command "${remote_host}" "${remote_download_user}" bash --noprofile --norc -s 2>&1)"
          remote_rc=$?
        fi
        if [[ ${had_xtrace} -eq 1 ]]; then
          set -x
        fi
        if [[ ${remote_rc} -eq 0 ]]; then
          if run_remote_command "${remote_host}" "${remote_download_user}" bash --noprofile --norc -c "tar -tzf '${remote_bundle_path}' >/dev/null 2>&1" >/dev/null 2>&1; then
            remote_detected_root="$(run_remote_command "${remote_host}" "${remote_download_user}" bash --noprofile --norc -c "tar -tzf '${remote_bundle_path}' 2>/dev/null | sed -n '1p' | cut -d/ -f1" 2>/dev/null | tr -d '\r\n' || true)"
            if [[ -n "${remote_detected_root}" ]]; then
              BUNDLE_DIR_NAME="${remote_detected_root}"
            fi
            INVENTORY_FILE="${remote_download_dir}/${BUNDLE_DIR_NAME}/inventory-growth"
            ok "Downloaded bundle to ${remote_bundle_path}"
            return 0
          fi
          remote_mime="$(run_remote_command "${remote_host}" "${remote_download_user}" bash --noprofile --norc -c "file -b --mime-type '${remote_bundle_path}' 2>/dev/null || true" 2>/dev/null | tr -d '\r\n' || true)"
          remote_head_snippet="$(run_remote_command "${remote_host}" "${remote_download_user}" bash --noprofile --norc -c "head -n 2 '${remote_bundle_path}' 2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-220" 2>/dev/null | tr -d '\r\n' || true)"
          if [[ "${remote_mime}" == "text/html" ]]; then
            remote_is_portal="$(run_remote_command "${remote_host}" "${remote_download_user}" bash --noprofile --norc -c "grep -qiE 'window\.portal|services/primer/js/primer\.js|access\.redhat\.com' '${remote_bundle_path}' && echo yes || true" 2>/dev/null | tr -d '\r\n' || true)"
          else
            remote_is_portal=""
          fi
          if [[ "${remote_is_portal}" != "yes" ]] && printf '%s' "${remote_head_snippet}" | grep -qiE '<!doctype html|<html|window\.portal|access\.redhat\.com'; then
            remote_is_portal="yes"
          fi
          if [[ "${remote_is_portal}" == "yes" ]]; then
            remote_last_error="remote URL returned Red Hat portal HTML instead of bundle archive (mode=${remote_auth_mode}). Refresh BUNDLE_URL and RHSM token/credentials."
          elif [[ -n "${remote_mime}" ]]; then
            remote_last_error="downloaded archive failed validation on remote host (mode=${remote_auth_mode}, mime=${remote_mime})"
          else
            remote_last_error="downloaded archive failed validation on remote host (mode=${remote_auth_mode})"
          fi
        elif [[ -n "${remote_attempt_output}" ]]; then
          remote_reason_line="$(printf '%s\n' "${remote_attempt_output}" | tail -n 1 | tr -d '\r')"
          remote_reason_line="$(printf '%s' "${remote_reason_line}" | sed -E 's#(https?://[^ ?]+)\?[^ ]+#\1?REDACTED#g; s#(Authorization:[[:space:]]*Bearer[[:space:]]+)[^ ]+#\1REDACTED#g; s#(RHSM_OFFLINE_TOKEN=)[^ ]+#\1REDACTED#g; s#(RHSM_PASSWORD=)[^ ]+#\1REDACTED#g; s#(-u[[:space:]]+[^:[:space:]]+:)[^[:space:]]+#\1REDACTED#g')"
          if [[ -n "${remote_reason_line}" ]]; then
            remote_last_error="${remote_reason_line}"
          fi
        fi
      done
    done
    if run_remote_command "${remote_host}" "${remote_download_user}" bash --noprofile --norc -c "tar -tzf '${remote_bundle_path}' >/dev/null 2>&1" >/dev/null 2>&1; then
      remote_detected_root="$(run_remote_command "${remote_host}" "${remote_download_user}" bash --noprofile --norc -c "tar -tzf '${remote_bundle_path}' 2>/dev/null | sed -n '1p' | cut -d/ -f1" 2>/dev/null | tr -d '\r\n' || true)"
      if [[ -n "${remote_detected_root}" ]]; then
        BUNDLE_DIR_NAME="${remote_detected_root}"
      fi
      INVENTORY_FILE="${remote_download_dir}/${BUNDLE_DIR_NAME}/inventory-growth"
      warn "Remote download attempts failed; using existing bundle at ${remote_bundle_path}"
      return 0
    fi
    controller_bundle_path="${HOME}/Downloads/${BUNDLE_FILE}"
    if [[ -f "${controller_bundle_path}" ]] && validate_bundle_archive "${controller_bundle_path}"; then
      local_fallback_ready=1
    fi
    if [[ ${local_fallback_ready} -eq 1 ]]; then
      warn "Remote download attempts failed; trying controller bundle at ${controller_bundle_path}"
      controller_detected_root="$(detect_archive_root_dir "${controller_bundle_path}")"
      controller_bundle_checksum="$(compute_file_sha256 "${controller_bundle_path}" 2>/dev/null || true)"
      if [[ -n "${controller_detected_root}" ]]; then
        remote_extract_dir_guess="${remote_download_dir}/${controller_detected_root}"
      else
        remote_extract_dir_guess="${remote_download_dir}/${BUNDLE_DIR_NAME}"
      fi
      if run_remote_command "${remote_host}" "admin" bash --noprofile --norc -c "test -d '${remote_extract_dir_guess}' && test -f '${remote_extract_dir_guess}/inventory-growth'" >/dev/null 2>&1; then
        if [[ -n "${controller_detected_root}" ]]; then
          BUNDLE_DIR_NAME="${controller_detected_root}"
        fi
        INVENTORY_FILE="${remote_download_dir}/${BUNDLE_DIR_NAME}/inventory-growth"
        warn "Controller fallback bundle already extracted on remote host; reusing ${remote_extract_dir_guess}"
        return 0
      fi
      if [[ -n "${controller_bundle_checksum}" ]]; then
        remote_bundle_checksum="$(run_remote_command "${remote_host}" "admin" bash --noprofile --norc -c "if [[ -f '${remote_bundle_path}' ]]; then if command -v sha256sum >/dev/null 2>&1; then sha256sum '${remote_bundle_path}' 2>/dev/null | awk '{print \\\$1}'; elif command -v shasum >/dev/null 2>&1; then shasum -a 256 '${remote_bundle_path}' 2>/dev/null | awk '{print \\\$1}'; elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 '${remote_bundle_path}' 2>/dev/null | awk '{print \\\$NF}'; fi; fi" 2>/dev/null | tr -d '\r\n' || true)"
      fi
      if [[ -n "${controller_bundle_checksum}" ]] && [[ -n "${remote_bundle_checksum}" ]] && [[ "${controller_bundle_checksum}" == "${remote_bundle_checksum}" ]]; then
        warn "Remote bundle checksum matches controller bundle; skipping scp upload"
        if run_remote_command "${remote_host}" "admin" bash --noprofile --norc -c "tar -xzf '${remote_bundle_path}' -C '${remote_download_dir}'" >/dev/null 2>&1; then
          if [[ -n "${controller_detected_root}" ]]; then
            BUNDLE_DIR_NAME="${controller_detected_root}"
          fi
          INVENTORY_FILE="${remote_download_dir}/${BUNDLE_DIR_NAME}/inventory-growth"
          ok "Reused matching remote bundle and extracted at ${remote_download_dir}"
          return 0
        fi
      fi
      if ! command -v scp >/dev/null 2>&1; then
        err "scp is required to upload local bundle fallback to remote host"
      else
        ensure_remote_host_key "${remote_host}" "admin"
        scp_args=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o GlobalKnownHostsFile=/dev/null -o PreferredAuthentications=publickey,password -o PasswordAuthentication=yes -o PubkeyAuthentication=yes -o LogLevel=ERROR)
        scp_cmd=(scp)
        scp_password="$(get_remote_password_for_user "admin")"
        had_sshpass=0
        previous_sshpass=""
        if [[ -v SSHPASS ]]; then
          had_sshpass=1
          previous_sshpass="${SSHPASS}"
        fi
        if [[ -n "${scp_password}" ]] && command -v sshpass >/dev/null 2>&1; then
          scp_cmd=(sshpass -e scp)
          export SSHPASS="${scp_password}"
        fi
        if run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "mkdir -p '${remote_download_dir}' && chown -R admin:admin '${remote_download_dir}'" >/dev/null 2>&1 \
          && "${scp_cmd[@]}" "${scp_args[@]}" "${controller_bundle_path}" "admin@${remote_host}:${remote_bundle_path}" >/dev/null 2>&1 \
          && run_remote_command "${remote_host}" "admin" bash --noprofile --norc -c "tar -xzf '${remote_bundle_path}' -C '${remote_download_dir}'" >/dev/null 2>&1; then
          detected_root="${controller_detected_root}"
          if [[ -z "${detected_root}" ]]; then
            detected_root="$(detect_archive_root_dir "${controller_bundle_path}")"
          fi
          if [[ -n "${detected_root}" ]]; then
            BUNDLE_DIR_NAME="${detected_root}"
          fi
          INVENTORY_FILE="${remote_download_dir}/${BUNDLE_DIR_NAME}/inventory-growth"
          ok "Uploaded controller bundle to remote host and extracted at ${remote_download_dir}"
          if [[ ${had_sshpass} -eq 1 ]]; then
            export SSHPASS="${previous_sshpass}"
          else
            unset SSHPASS || true
          fi
          return 0
        fi
        if [[ ${had_sshpass} -eq 1 ]]; then
          export SSHPASS="${previous_sshpass}"
        else
          unset SSHPASS || true
        fi
      fi
    fi
    err "Remote bundle download failed on ${remote_host}."
    if [[ -n "${remote_last_error}" ]]; then
      err "Last remote error: ${remote_last_error}"
    fi
    if [[ -n "${remote_auth_modes_text}" ]]; then
      err "Auth modes attempted: ${remote_auth_modes_text}"
    fi
    err "Not falling back to local bundle path because install scope is remote."
    return 1
  fi

  if command -v curl >/dev/null 2>&1; then
    local local_has_auth_mode=0
    case "${auth_mode_preference}" in
      basic-auth)
        if [[ -n "${RHSM_USERNAME:-}" && -n "${RHSM_PASSWORD:-}" ]]; then
          download_attempts+=("basic-auth:${RHSM_USERNAME}:${RHSM_PASSWORD}")
        else
          err "AAP_DOWNLOAD_AUTH_MODE=basic-auth requires RHSM_USERNAME and RHSM_PASSWORD"
          return 1
        fi
        ;;
      bearer)
        if [[ -n "${RHSM_OFFLINE_TOKEN:-}" ]]; then
          download_attempts+=("bearer:${RHSM_OFFLINE_TOKEN}")
        else
          err "AAP_DOWNLOAD_AUTH_MODE=bearer requires RHSM_OFFLINE_TOKEN"
          return 1
        fi
        ;;
      basic-token)
        if [[ -n "${RHSM_USERNAME:-}" && -n "${RHSM_OFFLINE_TOKEN:-}" ]]; then
          download_attempts+=("basic-token:${RHSM_OFFLINE_TOKEN}")
        else
          err "AAP_DOWNLOAD_AUTH_MODE=basic-token requires RHSM_USERNAME and RHSM_OFFLINE_TOKEN"
          return 1
        fi
        ;;
      anonymous)
        download_attempts+=("anonymous")
        ;;
      auto|*)
        if [[ -n "${RHSM_USERNAME:-}" && -n "${RHSM_PASSWORD:-}" ]]; then
          download_attempts+=("basic-auth:${RHSM_USERNAME}:${RHSM_PASSWORD}")
          local_has_auth_mode=1
        fi
        if [[ -n "${RHSM_OFFLINE_TOKEN:-}" ]]; then
          download_attempts+=("bearer:${RHSM_OFFLINE_TOKEN}")
          local_has_auth_mode=1
        fi
        if [[ ${local_has_auth_mode} -eq 0 || "${AAP_ALLOW_ANON_DOWNLOAD:-0}" == "1" ]]; then
          download_attempts+=("anonymous")
        fi
        ;;
    esac
  else
    download_attempts+=("wget")
  fi

  for attempt_label in "${download_attempts[@]}"; do
    rm -f "${bundle_path}" "${download_target}"
    command_args=()
    case "${attempt_label}" in
      basic-auth:*)
        local auth_pair="${attempt_label#basic-auth:}"
        command_args=(curl -fL -C - --retry 5 --retry-delay 30 --connect-timeout 60 --max-time 7200 -u "${auth_pair}" -o "${download_target}" "${bundle_url}")
        ;;
      bearer:*)
        local auth_token="${attempt_label#bearer:}"
        command_args=(curl -fL -C - --retry 5 --retry-delay 30 --connect-timeout 60 --max-time 7200 -H "Authorization: Bearer ${auth_token}" -H "X-Requested-With: XMLHttpRequest" -o "${download_target}" "${bundle_url}")
        ;;
      basic-token:*)
        local token_value="${attempt_label#basic-token:}"
        command_args=(curl -fL -C - --retry 5 --retry-delay 30 --connect-timeout 60 --max-time 7200 -u "${RHSM_USERNAME:-}:${token_value}" -o "${download_target}" "${bundle_url}")
        ;;
      anonymous)
        command_args=(curl -fL -C - --retry 5 --retry-delay 30 --connect-timeout 60 --max-time 7200 -o "${download_target}" "${bundle_url}")
        ;;
      wget)
        command_args=(wget -O "${download_target}" "${bundle_url}")
        ;;
    esac

    if [[ ${progress_enabled} -eq 1 ]]; then
      if ! "${command_args[@]}"; then
        continue
      fi
    else
      if ! "${command_args[@]}" >/dev/null 2>&1; then
        continue
      fi
    fi
      if [[ -f "${download_target}" ]]; then
        local downloaded_name=""
        downloaded_name="$(basename "${bundle_url}")"
        downloaded_name="${downloaded_name%%\?*}"
        if [[ -n "${downloaded_name}" && "${downloaded_name}" != "${BUNDLE_FILE}" ]]; then
          mv -f "${download_target}" "${DOWNLOAD_DIR}/${downloaded_name}"
        fi
        mv -f "${DOWNLOAD_DIR}/${downloaded_name:-${BUNDLE_FILE}}" "${final_target}" 2>/dev/null || mv -f "${download_target}" "${final_target}"
      fi
      if [[ -f "${final_target}" ]] && validate_bundle_archive "${final_target}"; then
        detected_root="$(detect_archive_root_dir "${final_target}")"
        if [[ -n "${detected_root}" ]]; then
          BUNDLE_DIR_NAME="${detected_root}"
          INVENTORY_FILE="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}/inventory-growth"
        fi
        if [[ "${attempt_label}" != "anonymous" ]]; then
          warn "Downloaded bundle using ${attempt_label}"
        fi
        break
      fi
  done

  if ! validate_bundle_archive "${bundle_path}"; then
    for candidate_url in "${BUNDLE_URL_CANDIDATES[@]}"; do
      candidate_name="$(basename "${candidate_url}")"
      candidate_name="${candidate_name%%\?*}"
      candidate_bundle_file="${candidate_name}"
      candidate_bundle_dir="${candidate_name%.tar.gz}"
      rm -f "${DOWNLOAD_DIR}/${candidate_bundle_file}" "${download_target}"
      if [[ ${progress_enabled} -eq 1 ]]; then
        if ! curl --progress-bar -fL -C - --retry 5 --retry-delay 30 --connect-timeout 60 --max-time 7200 -o "${download_target}" "${candidate_url}"; then
          continue
        fi
      else
        if ! curl -fL -C - --retry 5 --retry-delay 30 --connect-timeout 60 --max-time 7200 -o "${download_target}" "${candidate_url}" >/dev/null 2>&1; then
          continue
        fi
      fi
        if validate_bundle_archive "${download_target}"; then
          mv -f "${download_target}" "${bundle_path}"
          BUNDLE_FILE="${candidate_bundle_file:-${BUNDLE_FILE}}"
          detected_root="$(detect_archive_root_dir "${bundle_path}")"
          if [[ -n "${detected_root}" ]]; then
            BUNDLE_DIR_NAME="${detected_root}"
          else
            BUNDLE_DIR_NAME="${candidate_bundle_dir}"
          fi
          INVENTORY_FILE="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}/inventory-growth"
          warn "Downloaded bundle using discovered URL ${candidate_url}"
          break
        fi
    done
  fi

  if [[ ! -f "${bundle_path}" ]]; then
    err "Bundle download failed; no file was written to ${bundle_path}"
    return 1
  fi
  if [[ -f "${bundle_path}" ]]; then
    content_type="$(file -b --mime-type "${bundle_path}" 2>/dev/null || true)"
    if [[ -n "${content_type}" ]]; then
      warn "Downloaded bundle content type: ${content_type}"
    fi
  fi
  if ! validate_bundle_archive "${bundle_path}"; then
    err "Downloaded file is not a valid bundle archive: ${bundle_path}"
    err "The Red Hat download endpoint returned an access error page instead of the bundle archive."
    err "This usually means the account lacks entitlement for the bundle, the offline token is invalid, or the CDN blocked the request."
    err "Please verify the Red Hat account access for the bundle URL and re-run the installer with a valid offline token or entitlement."
    rm -f "${bundle_path}"
    return 1
  fi
  ok "Downloaded bundle"
}

extract_bundle() {
  refresh_runtime_paths
  local patch_root="${SCRIPT_DIR}/collection_patches/ansible/containerized_installer/roles"
  local patch_mode="${AAP_PATCH_ARCHIVE_BEFORE_EXTRACT:-1}"
  local patch_count="0"
  local enforce_archive_patch_extract=0

  case "${patch_mode,,}" in
    0|false|no|off)
      enforce_archive_patch_extract=0
      ;;
    *)
      if [[ -d "${patch_root}" ]]; then
        patch_count="$(find "${patch_root}" -type f | wc -l | tr -d '[:space:]')"
        if [[ -n "${patch_count}" && "${patch_count}" -gt 0 ]]; then
          enforce_archive_patch_extract=1
        fi
      fi
      ;;
  esac

  if is_remote_install_scope; then
    local remote_host="$(get_remote_ssh_target)"
    local remote_bootstrap_user="$(get_remote_bootstrap_user)"
    local remote_download_dir="${REMOTE_DOWNLOAD_DIR_DEFAULT}"
    local remote_bundle_path="${remote_download_dir}/${BUNDLE_FILE}"
    local remote_extract_dir="${remote_download_dir}/${BUNDLE_DIR_NAME}"
    local remote_extract_exists=0
    if [[ -d "${remote_extract_dir}" ]] && [[ -f "${remote_extract_dir}/inventory-growth" ]]; then
      remote_extract_exists=1
      if [[ ${enforce_archive_patch_extract} -eq 0 ]]; then
        ok "Bundle already extracted"
        return 0
      fi
      warn "Bundle is already extracted on remote host; forcing re-extract from patched archive"
    fi
    if ! run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "test -f '${remote_bundle_path}'" >/dev/null 2>&1; then
      err "Bundle archive not found on remote host: ${remote_bundle_path}"
      return 1
    fi
    if ! run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "tar -tzf '${remote_bundle_path}' >/dev/null 2>&1" >/dev/null 2>&1; then
      err "Bundle extraction failed; the downloaded archive is invalid or incomplete"
      return 1
    fi
    if ! inject_collection_patches_into_bundle_archive; then
      err "Failed to inject collection patches into remote bundle archive"
      return 1
    fi
    if [[ ${remote_extract_exists} -eq 1 ]]; then
      if ! run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "rm -rf '${remote_extract_dir}'" >/dev/null 2>&1; then
        err "Failed to remove existing remote extracted bundle directory: ${remote_extract_dir}"
        return 1
      fi
    fi
    if ! run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "mkdir -p '${remote_download_dir}' && tar -xzf '${remote_bundle_path}' -C '${remote_download_dir}'" >/dev/null 2>&1; then
      err "Bundle extraction failed; the downloaded archive is invalid or incomplete"
      return 1
    fi
    local remote_detected_root=""
    remote_detected_root="$(run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "tar -tzf '${remote_bundle_path}' 2>/dev/null | sed -n '1p' | cut -d/ -f1" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -n "${remote_detected_root}" ]]; then
      BUNDLE_DIR_NAME="${remote_detected_root}"
      INVENTORY_FILE="${remote_download_dir}/${BUNDLE_DIR_NAME}/inventory-growth"
    fi
    ok "Bundle extracted"
    return 0
  fi

  if [[ -d "${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}" ]] && [[ -f "${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}/inventory-growth" ]]; then
    if [[ ${enforce_archive_patch_extract} -eq 0 ]]; then
      ok "Bundle already extracted"
      return 0
    fi
    warn "Bundle is already extracted locally; forcing re-extract from patched archive"
  fi
  if [[ ! -f "${DOWNLOAD_DIR}/${BUNDLE_FILE}" ]]; then
    err "Bundle archive not found"
    return 1
  fi
  if ! validate_bundle_archive "${DOWNLOAD_DIR}/${BUNDLE_FILE}"; then
    err "Bundle extraction failed; the downloaded archive is invalid or incomplete"
    return 1
  fi
  if ! inject_collection_patches_into_bundle_archive; then
    err "Failed to inject collection patches into local bundle archive"
    return 1
  fi
  if [[ -d "${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}" ]] && [[ -f "${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}/inventory-growth" ]]; then
    if ! rm -rf "${DOWNLOAD_DIR:?}/${BUNDLE_DIR_NAME}"; then
      err "Failed to remove existing local extracted bundle directory: ${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}"
      return 1
    fi
  fi
  if ! tar -xzf "${DOWNLOAD_DIR}/${BUNDLE_FILE}" -C "${DOWNLOAD_DIR}"; then
    err "Bundle extraction failed; the downloaded archive is invalid or incomplete"
    return 1
  fi
  local detected_root=""
  detected_root="$(detect_archive_root_dir "${DOWNLOAD_DIR}/${BUNDLE_FILE}")"
  if [[ -n "${detected_root}" ]]; then
    BUNDLE_DIR_NAME="${detected_root}"
    INVENTORY_FILE="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}/inventory-growth"
  fi
  ok "Bundle extracted"
}

inject_collection_patches_into_bundle_archive() {
  refresh_runtime_paths
  local patch_root="${SCRIPT_DIR}/collection_patches/ansible/containerized_installer/roles"
  local patch_count=0
  local patch_mode="${AAP_PATCH_ARCHIVE_BEFORE_EXTRACT:-1}"

  case "${patch_mode,,}" in
    0|false|no|off)
      return 0
      ;;
  esac

  if [[ ! -d "${patch_root}" ]]; then
    return 0
  fi

  patch_count="$(find "${patch_root}" -type f | wc -l | tr -d '[:space:]')"
  if [[ -z "${patch_count}" || "${patch_count}" -eq 0 ]]; then
    return 0
  fi

  if is_remote_install_scope; then
    local remote_host="$(get_remote_ssh_target)"
    local remote_bootstrap_user="$(get_remote_bootstrap_user)"
    local remote_bundle_path="${REMOTE_DOWNLOAD_DIR_DEFAULT}/${BUNDLE_FILE}"
    local remote_tmp_dir="/tmp/aap27_bundle_patch.$$"
    local remote_root_dir=""
    local remote_inject_script=""

    if ! run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "test -f '${remote_bundle_path}'" >/dev/null 2>&1; then
      err "Bundle archive not found on remote host for patch injection: ${remote_bundle_path}"
      return 1
    fi

    remote_root_dir="$(run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "tar -tzf '${remote_bundle_path}' 2>/dev/null | sed -n '1p' | cut -d/ -f1" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -z "${remote_root_dir}" ]]; then
      err "Unable to detect remote bundle archive root directory"
      return 1
    fi

    log "Injecting ${patch_count} collection patch file(s) into remote bundle archive before extraction"
    if ! run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "set -euo pipefail; rm -rf '${remote_tmp_dir}'; mkdir -p '${remote_tmp_dir}/patches'; tar -xzf '${remote_bundle_path}' -C '${remote_tmp_dir}'" >/dev/null 2>&1; then
      err "Failed to unpack remote bundle archive for patch injection"
      run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "rm -rf '${remote_tmp_dir}'" >/dev/null 2>&1 || true
      return 1
    fi

    if ! tar -C "${patch_root}" -cf - . | run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "tar -xf - -C '${remote_tmp_dir}/patches'" >/dev/null 2>&1; then
      err "Failed to transfer patch files to remote staging area"
      run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "rm -rf '${remote_tmp_dir}'" >/dev/null 2>&1 || true
      return 1
    fi

    remote_inject_script="set -euo pipefail
root='${remote_tmp_dir}/${remote_root_dir}'
patches='${remote_tmp_dir}/patches'
target=''
for candidate in \
  \"\${root}/collections/ansible_collections/ansible/containerized_installer/roles\" \
  \"\${root}/ansible_collections/ansible/containerized_installer/roles\" \
  \"\${root}/containerized_installer/roles\"; do
  if [[ -d \"\${candidate}\" ]]; then
    target=\"\${candidate}\"
    break
  fi
done
if [[ -z \"\${target}\" ]]; then
  found_rel=\"\$(cd \"\${root}\" && find . -type d -path '*/ansible/containerized_installer/roles' | head -n1 || true)\"
  if [[ -n \"\${found_rel}\" ]]; then
    target=\"\${root}/\${found_rel#./}\"
  fi
fi
if [[ -z \"\${target}\" ]]; then
  exit 1
fi
cp -a \"\${patches}/.\" \"\${target}/\"
tar -czf '${remote_bundle_path}.patched' -C '${remote_tmp_dir}' '${remote_root_dir}'
mv -f '${remote_bundle_path}.patched' '${remote_bundle_path}'
rm -rf '${remote_tmp_dir}'"

    if ! run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "${remote_inject_script}" >/dev/null 2>&1; then
      err "Failed to apply patches into remote bundle archive"
      run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "rm -rf '${remote_tmp_dir}'" >/dev/null 2>&1 || true
      return 1
    fi

    ok "Injected collection patches into remote bundle archive"
    return 0
  fi

  local local_bundle_path="${DOWNLOAD_DIR}/${BUNDLE_FILE}"
  local local_tmp_dir=""
  local local_root_dir=""
  local target_roles_dir=""

  if [[ ! -f "${local_bundle_path}" ]]; then
    err "Bundle archive not found for local patch injection: ${local_bundle_path}"
    return 1
  fi
  if ! validate_bundle_archive "${local_bundle_path}"; then
    err "Local bundle archive is invalid before patch injection"
    return 1
  fi

  local_root_dir="$(detect_archive_root_dir "${local_bundle_path}")"
  if [[ -z "${local_root_dir}" ]]; then
    err "Unable to detect local bundle archive root directory"
    return 1
  fi

  local_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/aap27_bundle_patch.XXXXXX")"
  log "Injecting ${patch_count} collection patch file(s) into local bundle archive before extraction"

  if ! tar -xzf "${local_bundle_path}" -C "${local_tmp_dir}"; then
    rm -rf "${local_tmp_dir}"
    err "Failed to unpack local bundle archive for patch injection"
    return 1
  fi

  for target_roles_dir in \
    "${local_tmp_dir}/${local_root_dir}/collections/ansible_collections/ansible/containerized_installer/roles" \
    "${local_tmp_dir}/${local_root_dir}/ansible_collections/ansible/containerized_installer/roles" \
    "${local_tmp_dir}/${local_root_dir}/containerized_installer/roles"; do
    if [[ -d "${target_roles_dir}" ]]; then
      break
    fi
  done

  if [[ -z "${target_roles_dir}" || ! -d "${target_roles_dir}" ]]; then
    target_roles_dir="$(find "${local_tmp_dir}/${local_root_dir}" -type d -path '*/ansible/containerized_installer/roles' 2>/dev/null | head -n1 || true)"
  fi

  if [[ -z "${target_roles_dir}" || ! -d "${target_roles_dir}" ]]; then
    rm -rf "${local_tmp_dir}"
    err "Unable to locate roles directory inside local bundle archive"
    return 1
  fi

  if ! cp -a "${patch_root}/." "${target_roles_dir}/"; then
    rm -rf "${local_tmp_dir}"
    err "Failed to overlay patch files into local bundle staging directory"
    return 1
  fi

  if ! tar -czf "${local_bundle_path}.patched" -C "${local_tmp_dir}" "${local_root_dir}"; then
    rm -rf "${local_tmp_dir}"
    err "Failed to rebuild local bundle archive after patch injection"
    return 1
  fi

  mv -f "${local_bundle_path}.patched" "${local_bundle_path}"
  rm -rf "${local_tmp_dir}"
  ok "Injected collection patches into local bundle archive"
  return 0
}

ensure_bundle_images_dir() {
  refresh_runtime_paths
  local bundle_root="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}"
  local bundle_overlay_dir="${bundle_root}/bundle"
  local images_dir_primary="${bundle_root}/images"
  local images_dir_secondary="${bundle_overlay_dir}/images"
  local collections_dir_primary="${bundle_root}/collections"
  local collections_dir_secondary="${bundle_overlay_dir}/collections"

  if is_remote_install_scope; then
    local remote_host="$(get_remote_ssh_target)"
    local remote_bootstrap_user="$(get_remote_bootstrap_user)"
    if run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "test -d '${images_dir_secondary}' && test -d '${collections_dir_secondary}'" >/dev/null 2>&1; then
      return 0
    fi
    warn "Bundle overlay directories missing on remote host; creating compatibility layout under ${bundle_overlay_dir}"
    if ! run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "set -euo pipefail; mkdir -p '${images_dir_primary}' '${collections_dir_primary}' '${bundle_overlay_dir}'; if [[ ! -e '${images_dir_secondary}' ]]; then ln -s '../images' '${images_dir_secondary}' 2>/dev/null || mkdir -p '${images_dir_secondary}'; fi; if [[ ! -e '${collections_dir_secondary}' ]]; then ln -s '../collections' '${collections_dir_secondary}' 2>/dev/null || mkdir -p '${collections_dir_secondary}'; fi" >/dev/null 2>&1; then
      err "Unable to create bundle compatibility directories on remote host under ${bundle_root}"
      return 1
    fi
    ok "Created remote bundle compatibility layout under ${bundle_overlay_dir}"
    return 0
  fi

  if [[ -d "${images_dir_secondary}" && -d "${collections_dir_secondary}" ]]; then
    return 0
  fi
  warn "Bundle overlay directories missing; creating compatibility layout under ${bundle_overlay_dir}"
  if ! mkdir -p "${images_dir_primary}" "${collections_dir_primary}" "${bundle_overlay_dir}"; then
    err "Unable to create bundle compatibility directories under ${bundle_root}"
    return 1
  fi
  if [[ ! -e "${images_dir_secondary}" ]]; then
    ln -s ../images "${images_dir_secondary}" 2>/dev/null || mkdir -p "${images_dir_secondary}"
  fi
  if [[ ! -e "${collections_dir_secondary}" ]]; then
    ln -s ../collections "${collections_dir_secondary}" 2>/dev/null || mkdir -p "${collections_dir_secondary}"
  fi
  if [[ ! -d "${images_dir_secondary}" || ! -d "${collections_dir_secondary}" ]]; then
    err "Unable to prepare bundle compatibility directories under ${bundle_overlay_dir}"
    return 1
  fi
  ok "Created bundle compatibility layout under ${bundle_overlay_dir}"
}

apply_collection_patches() {
  refresh_runtime_paths
  local install_dir="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}"
  local patch_root="${SCRIPT_DIR}/collection_patches/ansible/containerized_installer/roles"
  local patch_count=0
  local target_roles_dir=""

  if [[ ! -d "${patch_root}" ]]; then
    return 0
  fi

  patch_count="$(find "${patch_root}" -type f | wc -l | tr -d '[:space:]')"
  if [[ -z "${patch_count}" || "${patch_count}" -eq 0 ]]; then
    return 0
  fi

  if is_remote_install_scope; then
    local remote_host="$(get_remote_ssh_target)"
    local remote_bootstrap_user="$(get_remote_bootstrap_user)"
    local remote_locator="set -euo pipefail
install_dir='${install_dir}'
for candidate in \
  \"\${install_dir}/collections/ansible_collections/ansible/containerized_installer/roles\" \
  \"\${install_dir}/ansible_collections/ansible/containerized_installer/roles\" \
  \"\${install_dir}/containerized_installer/roles\"; do
  if [[ -d \"\${candidate}\" ]]; then
    printf '%s\n' \"\${candidate}\"
    exit 0
  fi
done
found_rel=\"\$(cd \"\${install_dir}\" 2>/dev/null && find . -type d -path '*/ansible/containerized_installer/roles' | head -n1 || true)\"
if [[ -n \"\${found_rel}\" ]]; then
  printf '%s\n' \"\${install_dir}/\${found_rel#./}\"
  exit 0
fi
exit 1"

    target_roles_dir="$(run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "${remote_locator}" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -z "${target_roles_dir}" ]]; then
      warn "Skipping collection patches: unable to locate containerized installer roles directory on remote host"
      return 0
    fi

    log "Applying ${patch_count} collection patch file(s) on remote host"
    if ! tar -C "${patch_root}" -cf - . | run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "mkdir -p '${target_roles_dir}' && tar -xf - -C '${target_roles_dir}'" >/dev/null 2>&1; then
      err "Failed to apply collection patches on remote host"
      return 1
    fi
    if ! run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "set -euo pipefail; test -f '${target_roles_dir}/automationgateway/tasks/containers.yml'; test -f '${target_roles_dir}/automationgateway/tasks/init.yml'; grep -q 'automationgateway_use_keep_id: false' '${target_roles_dir}/automationgateway/tasks/containers.yml'; grep -q 'Ensure gateway supervisor runtime directory is writable by container service user' '${target_roles_dir}/automationgateway/tasks/containers.yml'; grep -q 'Re-check automation gateway running state before TLS readability validation' '${target_roles_dir}/automationgateway/tasks/init.yml'" >/dev/null 2>&1; then
      err "Collection patch verification failed on remote host (gateway role signatures missing)"
      return 1
    fi
    ok "Applied collection patches on remote host"
    return 0
  fi

  for target_roles_dir in \
    "${install_dir}/collections/ansible_collections/ansible/containerized_installer/roles" \
    "${install_dir}/ansible_collections/ansible/containerized_installer/roles" \
    "${install_dir}/containerized_installer/roles"; do
    if [[ -d "${target_roles_dir}" ]]; then
      break
    fi
  done

  if [[ -z "${target_roles_dir}" || ! -d "${target_roles_dir}" ]]; then
    target_roles_dir="$(find "${install_dir}" -type d -path '*/ansible/containerized_installer/roles' 2>/dev/null | head -n1 || true)"
  fi

  if [[ -z "${target_roles_dir}" || ! -d "${target_roles_dir}" ]]; then
    warn "Skipping collection patches: unable to locate containerized installer roles directory"
    return 0
  fi

  log "Applying ${patch_count} collection patch file(s)"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "${patch_root}/" "${target_roles_dir}/" >/dev/null 2>&1 || {
      err "Failed to apply collection patches"
      return 1
    }
  else
    cp -a "${patch_root}/." "${target_roles_dir}/" >/dev/null 2>&1 || {
      err "Failed to apply collection patches"
      return 1
    }
  fi
  if [[ ! -f "${target_roles_dir}/automationgateway/tasks/containers.yml" ]] || [[ ! -f "${target_roles_dir}/automationgateway/tasks/init.yml" ]]; then
    err "Collection patch verification failed locally (gateway role files missing)"
    return 1
  fi
  if ! grep -q 'automationgateway_use_keep_id: false' "${target_roles_dir}/automationgateway/tasks/containers.yml"; then
    err "Collection patch verification failed locally (keep-id signature missing)"
    return 1
  fi
  if ! grep -q 'Ensure gateway supervisor runtime directory is writable by container service user' "${target_roles_dir}/automationgateway/tasks/containers.yml"; then
    err "Collection patch verification failed locally (supervisor permission signature missing)"
    return 1
  fi
  if ! grep -q 'Re-check automation gateway running state before TLS readability validation' "${target_roles_dir}/automationgateway/tasks/init.yml"; then
    err "Collection patch verification failed locally (TLS running-state guard signature missing)"
    return 1
  fi
  ok "Applied collection patches"
}

show_status() {
  load_env
  echo "AAP 2.7 installer status"
  echo "========================"
  echo "env file: ${ENV_FILE}"
  echo "bundle archive: $([[ -f "${DOWNLOAD_DIR}/${BUNDLE_FILE}" ]] && echo present || echo missing)"
  echo "bundle dir: $([[ -d "${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}" ]] && echo present || echo missing)"
  echo "inventory-growth: $([[ -f "${INVENTORY_FILE}" ]] && echo present || echo missing)"
  echo "admin user: $(id admin >/dev/null 2>&1 && echo present || echo missing)"
}

ensure_remote_registration_and_upgrade() {
  if ! is_remote_install_scope; then
    return 0
  fi

  local remote_host="$(get_remote_ssh_target)"
  local remote_bootstrap_user="$(get_remote_bootstrap_user)"
  local remote_script=""
  local remote_payload=""

  remote_script="set -euo pipefail
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:'\"\${PATH:-}\"
priv=''
if [[ \$(id -u) -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    priv='sudo'
  else
    echo 'sudo is required for remote registration and upgrade when not root' >&2
    exit 40
  fi
fi

have_subman=0
have_rhc=0
if command -v subscription-manager >/dev/null 2>&1; then
  have_subman=1
fi
if command -v rhc >/dev/null 2>&1; then
  have_rhc=1
fi
if [[ \${have_subman} -eq 0 && \${have_rhc} -eq 0 ]]; then
  echo 'subscription-manager or rhc is required on remote host before installing requirements' >&2
  exit 41
fi

is_registered=0
if [[ \${have_subman} -eq 1 ]] && \${priv} subscription-manager identity >/dev/null 2>&1; then
  is_registered=1
elif [[ \${have_rhc} -eq 1 ]]; then
  rhc_status_out=\"\$(\${priv} rhc status 2>&1 || true)\"
  if printf '%s\n' \"\${rhc_status_out}\" | grep -qiE 'overall status:[[:space:]]*connected|this system is connected|connected to red hat'; then
    is_registered=1
  fi
fi

if [[ \${is_registered} -eq 0 ]]; then
  if [[ -n \"\${RHSM_ORG_ID:-}\" && -n \"\${RHSM_ACTIVATION_KEY:-}\" && \${have_rhc} -eq 1 ]]; then
    if ! \${priv} dnf -y install rhc-worker-playbook >/dev/null 2>&1; then
      if ! \${priv} yum -y install rhc-worker-playbook >/dev/null 2>&1; then
        echo 'failed to install rhc-worker-playbook required for rhc connect' >&2
        exit 44
      fi
    fi
    \${priv} rhc connect --activation-key \"\${RHSM_ACTIVATION_KEY}\" --organization \"\${RHSM_ORG_ID}\"
  elif [[ -n \"\${RHSM_ORG_ID:-}\" && -n \"\${RHSM_ACTIVATION_KEY:-}\" && \${have_subman} -eq 1 ]]; then
    \${priv} subscription-manager register --org=\"\${RHSM_ORG_ID}\" --activationkey=\"\${RHSM_ACTIVATION_KEY}\" --force
  elif [[ -n \"\${RHSM_USERNAME:-}\" && -n \"\${RHSM_PASSWORD:-}\" && \${have_subman} -eq 1 ]]; then
    register_extra_opts='--force'
    if subscription-manager register --help 2>/dev/null | grep -q -- '--auto-attach'; then
      register_extra_opts='--auto-attach --force'
    fi
    \${priv} subscription-manager register --username \"\${RHSM_USERNAME}\" --password \"\${RHSM_PASSWORD}\" \${register_extra_opts}
  else
    echo 'RHSM credentials are required: use RHSM_ORG_ID + RHSM_ACTIVATION_KEY (preferred for rhc) or RHSM_USERNAME/RHSM_PASSWORD (subscription-manager)' >&2
    exit 42
  fi
fi

if ! { [[ \${have_subman} -eq 1 ]] && \${priv} subscription-manager identity >/dev/null 2>&1; } && ! { [[ \${have_rhc} -eq 1 ]] && \${priv} rhc status 2>/dev/null | grep -qiE 'overall status:[[:space:]]*connected|this system is connected|connected to red hat'; }; then
  echo 'remote host registration failed' >&2
  exit 43
fi

if command -v dnf >/dev/null 2>&1; then
  \${priv} dnf -y upgrade >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
  \${priv} yum -y update >/dev/null 2>&1
fi"

  remote_payload="RHSM_USERNAME=$(shell_single_quote "${RHSM_USERNAME:-}")
RHSM_PASSWORD=$(shell_single_quote "${RHSM_PASSWORD:-}")
RHSM_ORG_ID=$(shell_single_quote "${RHSM_ORG_ID:-}")
RHSM_ACTIVATION_KEY=$(shell_single_quote "${RHSM_ACTIVATION_KEY:-}")
export RHSM_USERNAME RHSM_PASSWORD RHSM_ORG_ID RHSM_ACTIVATION_KEY
${remote_script}"

  local registration_output=""
  local registration_reason=""
  if registration_output="$(printf '%s\n' "${remote_payload}" | run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -s 2>&1)"; then
    :
  else
    registration_reason="$(printf '%s\n' "${registration_output}" | tail -n 3 | tr -d '\r' | tr '\n' ' ' | sed -E 's#(https?://[^ ?]+)\?[^ ]+#\1?REDACTED#g; s#(Authorization:[[:space:]]*Bearer[[:space:]]+)[^ ]+#\1REDACTED#g; s#(RHSM_OFFLINE_TOKEN=)[^ ]+#\1REDACTED#g; s#(RHSM_PASSWORD=)[^ ]+#\1REDACTED#g; s#(RHSM_ACTIVATION_KEY=)[^ ]+#\1REDACTED#g; s#(--password[[:space:]]+)[^[:space:]]+#\1REDACTED#g; s#(--activation-key[[:space:]]+)[^[:space:]]+#\1REDACTED#g')"
    err "Failed to register and upgrade remote host ${remote_host}"
    if [[ -n "${registration_reason}" ]]; then
      err "Registration/upgrade detail: ${registration_reason}"
    fi
    err "Set RHSM credentials in ${ENV_FILE} and ensure subscription-manager works on the remote host"
    return 1
  fi

  ok "Remote host ${remote_host} is registered and upgraded"
}

prework_packages() {
  log "Preparing host packages"
  if is_remote_install_scope; then
    local remote_host="$(get_remote_ssh_target)"
    local remote_bootstrap_user="$(get_remote_bootstrap_user)"
    ensure_registry_credentials || true
    if ! ensure_remote_registration_and_upgrade; then
      return 1
    fi
    if ! run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "set -euo pipefail
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:'\"\${PATH:-}\"
if command -v dnf >/dev/null 2>&1; then
  if [[ \$(id -u) -eq 0 ]]; then
    dnf install -y podman ansible-core sshpass tar wget >/dev/null 2>&1 || true
  elif command -v sudo >/dev/null 2>&1; then
    sudo dnf install -y podman ansible-core sshpass tar wget >/dev/null 2>&1 || true
  fi
elif command -v yum >/dev/null 2>&1; then
  if [[ \$(id -u) -eq 0 ]]; then
    yum install -y podman ansible-core sshpass tar wget >/dev/null 2>&1 || true
  elif command -v sudo >/dev/null 2>&1; then
    sudo yum install -y podman ansible-core sshpass tar wget >/dev/null 2>&1 || true
  fi
elif command -v microdnf >/dev/null 2>&1; then
  if [[ \$(id -u) -eq 0 ]]; then
    microdnf install -y podman ansible-core sshpass tar wget >/dev/null 2>&1 || true
  elif command -v sudo >/dev/null 2>&1; then
    sudo microdnf install -y podman ansible-core sshpass tar wget >/dev/null 2>&1 || true
  fi
elif command -v apt-get >/dev/null 2>&1; then
  if [[ \$(id -u) -eq 0 ]]; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y podman ansible-core sshpass tar wget >/dev/null 2>&1 || apt-get install -y podman ansible sshpass tar wget >/dev/null 2>&1 || true
  elif command -v sudo >/dev/null 2>&1; then
    sudo apt-get update -y >/dev/null 2>&1 || true
    sudo apt-get install -y podman ansible-core sshpass tar wget >/dev/null 2>&1 || sudo apt-get install -y podman ansible sshpass tar wget >/dev/null 2>&1 || true
  fi
fi
command -v ansible-playbook >/dev/null 2>&1
command -v podman >/dev/null 2>&1" >/dev/null 2>&1; then
  err "ansible-playbook or podman is not available on remote host ${remote_host} after package preparation"
  err "Install ansible-core and podman on ${remote_host} and rerun the installer"
      return 1
    fi
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    run_privileged dnf install -y podman ansible-core sshpass tar wget >/dev/null 2>&1 || true
  fi
}

disable_firewall_selinux() {
  log "Relaxing firewall and SELinux constraints"
  if is_remote_install_scope; then
    local remote_host="$(get_remote_ssh_target)"
    local remote_bootstrap_user="$(get_remote_bootstrap_user)"
    run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "if [[ \$(id -u) -eq 0 ]]; then setsebool -P container_manage_cgroup true >/dev/null 2>&1 || true; systemctl stop firewalld >/dev/null 2>&1 || true; systemctl disable firewalld >/dev/null 2>&1 || true; elif command -v sudo >/dev/null 2>&1; then sudo setsebool -P container_manage_cgroup true >/dev/null 2>&1 || true; sudo systemctl stop firewalld >/dev/null 2>&1 || true; sudo systemctl disable firewalld >/dev/null 2>&1 || true; fi" >/dev/null 2>&1 || true
    return 0
  fi
  run_privileged setsebool -P container_manage_cgroup true >/dev/null 2>&1 || true
  run_privileged systemctl stop firewalld >/dev/null 2>&1 || true
  run_privileged systemctl disable firewalld >/dev/null 2>&1 || true
}

set_fqdn_and_hosts() {
  if is_remote_install_scope; then
    local remote_host="$(get_remote_ssh_target)"
    local remote_bootstrap_user="$(get_remote_bootstrap_user)"
    run_remote_command "${remote_host}" "${remote_bootstrap_user}" bash --noprofile --norc -c "fqdn=\$(hostname -f 2>/dev/null || hostname); if [[ -n \"\${fqdn}\" ]]; then if [[ \$(id -u) -eq 0 ]]; then hostnamectl set-hostname \"\${fqdn}\" >/dev/null 2>&1 || true; elif command -v sudo >/dev/null 2>&1; then sudo hostnamectl set-hostname \"\${fqdn}\" >/dev/null 2>&1 || true; fi; fi" >/dev/null 2>&1 || true
    return 0
  fi
  local fqdn=""
  fqdn="$(hostname -f 2>/dev/null || hostname)"
  if [[ -n "${fqdn}" ]]; then
    run_privileged hostnamectl set-hostname "${fqdn}" >/dev/null 2>&1 || true
  fi
}

run_quick_standard_install_flow() {
  run_with_spinner "checking prerequisites" preflight_dependency_checks
  run_with_spinner "preparing host packages" prework_packages
  run_with_spinner "relaxing host constraints" disable_firewall_selinux
  run_with_spinner "setting hostname" set_fqdn_and_hosts
  run_with_spinner "setting up admin user" setup_admin_user
  log "Collecting credentials"
  if ! capture_credentials; then
    err "collecting credentials"
    return 1
  fi
  ok "collecting credentials"
  log "Downloading bundle"
  if AAP_DOWNLOAD_PROGRESS=1 download_bundle; then
    ok "downloading bundle"
  else
    err "downloading bundle"
    return 1
  fi
  run_with_spinner "extracting bundle" extract_bundle
  run_with_spinner "updating inventory" modify_inventory_growth
  log "Running playbook: ${AAP_PLAYBOOK:-install}"
  if ! run_execution_playbook "${AAP_PLAYBOOK:-install}"; then
    err "running playbook"
    return 1
  fi
  ok "running playbook"
}

show_startup_banner() {
  local displayed_scope="local"
  local displayed_remote_host="n/a"
  if is_remote_install_scope; then
    displayed_scope="remote"
    displayed_remote_host="$(get_remote_target_host || true)"
  fi
  echo
  echo "AAP 2.7 installer startup"
  echo "========================"
  echo "Install scope : ${displayed_scope}"
  echo "Remote host   : ${displayed_remote_host}"
  echo "Local user    : $(get_local_user)"
  echo "Admin user    : admin"
  echo "Playbook      : ${AAP_PLAYBOOK:-install}"
  echo "Env file      : ${ENV_FILE}"
  echo "Inventory     : ${INVENTORY_FILE}"
  echo "Interactive   : $(is_interactive_mode && echo yes || echo no)"
  echo
}

initial_install_scope_prompt() {
  local selected_scope="${AAP_INSTALL_SCOPE:-${INSTALL_SCOPE:-local}}"
  local inv_dir="${SCRIPT_DIR}/aap_workflow_project/inventory"
  local inv_file="${inv_dir}/controller.ini"
  local remote_host=""
  local local_fqdn=""
  mkdir -p "${inv_dir}"

  remote_host="${AAP_REMOTE_FQDN:-${AAP_REMOTE_IP:-${DEFAULT_REMOTE_HOST}}}"
  local_fqdn="$(hostname -f 2>/dev/null || hostname)"

  if [[ -n "${AAP_REMOTE_IP:-${REMOTE_IP:-}}" || -n "${AAP_REMOTE_FQDN:-${REMOTE_FQDN:-}}" || -n "$(get_remote_target_host)" ]]; then
    selected_scope="remote"
  fi

  case "${selected_scope}" in
    remote)
      mkdir -p "${inv_dir}"
    cat > "${inv_file}" <<REMOTE_INV
[controller]
  ${remote_host} ansible_connection=ssh ansible_user=admin

[installhost]
  ${local_fqdn} ansible_connection=local

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
REMOTE_INV
      save_env_kv "INSTALL_SCOPE" "remote"
    save_env_kv "AAP_REMOTE_IP" "${AAP_REMOTE_IP:-${remote_host}}"
      ;;
    *)
    cat > "${inv_file}" <<LOCAL_INV
[controller]
localhost ansible_connection=local

[installhost]
  ${local_fqdn} ansible_connection=local

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
LOCAL_INV
      save_env_kv "INSTALL_SCOPE" "local"
      ;;
  esac
}

parse_cli_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --manual)
        AAP_INTERACTIVE_MODE="manual"
        AAP_NO_PROMPTS="0"
        shift
        ;;
      --non-interactive|--no-prompt)
        AAP_INTERACTIVE_MODE="0"
        AAP_NO_PROMPTS="1"
        shift
        ;;
      --reset-env)
        AAP_RESET_ENV="1"
        AAP_INTERACTIVE_MODE="manual"
        AAP_NO_PROMPTS="0"
        shift
        ;;
      --playbook)
        AAP_PLAYBOOK="${2:-}"
        shift 2
        ;;
      --install-scope)
        AAP_INSTALL_SCOPE="${2:-}"
        shift 2
        ;;
      --controller-ip)
        AAP_CONTROLLER_IP="${2:-}"
        shift 2
        ;;
      --controller-fqdn)
        AAP_CONTROLLER_FQDN="${2:-}"
        shift 2
        ;;
      --remote-host)
        AAP_REMOTE_IP="${2:-}"
        shift 2
        ;;
      --remote-fqdn)
        AAP_REMOTE_FQDN="${2:-}"
        shift 2
        ;;
      --remote-ip)
        AAP_REMOTE_IP="${2:-}"
        shift 2
        ;;
      --remote-user)
        AAP_REMOTE_USER="${2:-}"
        shift 2
        ;;
      --remote-bootstrap-user)
        AAP_REMOTE_BOOTSTRAP_USER="${2:-}"
        shift 2
        ;;
      --remote-password)
        AAP_REMOTE_PASSWORD="${2:-}"
        shift 2
        ;;
      --remote-bootstrap-password)
        AAP_REMOTE_BOOTSTRAP_PASSWORD="${2:-}"
        shift 2
        ;;
      --remote-admin-password)
        AAP_REMOTE_ADMIN_PASSWORD="${2:-}"
        shift 2
        ;;
      --local-user)
        AAP_LOCAL_USER="${2:-}"
        shift 2
        ;;
      --admin-password)
        AAP_ADMIN_PASSWORD="${2:-}"
        ADMIN_PASSWORD="${2:-}"
        shift 2
        ;;
      --rhsm-user)
        RHSM_USERNAME="${2:-}"
        shift 2
        ;;
      --rhsm-password)
        RHSM_PASSWORD="${2:-}"
        shift 2
        ;;
      --rhsm-offline-token)
        RHSM_OFFLINE_TOKEN="${2:-}"
        shift 2
        ;;
      --rhsm-org-id)
        RHSM_ORG_ID="${2:-}"
        shift 2
        ;;
      --rhsm-activation-key)
        RHSM_ACTIVATION_KEY="${2:-}"
        shift 2
        ;;
      --bundle-url)
        BUNDLE_URL="${2:-}"
        shift 2
        ;;
      --download-auth-mode)
        AAP_DOWNLOAD_AUTH_MODE="${2:-}"
        shift 2
        ;;
      --allow-anon-download)
        AAP_ALLOW_ANON_DOWNLOAD="${2:-}"
        shift 2
        ;;
      --patch-archive-before-extract)
        AAP_PATCH_ARCHIVE_BEFORE_EXTRACT="${2:-}"
        shift 2
        ;;
      --apply-patches-only)
        AAP_APPLY_PATCHES_ONLY="1"
        shift
        ;;
      --remote-force-tty)
        AAP_REMOTE_FORCE_TTY="${2:-}"
        shift 2
        ;;
      --enable-spinner)
        AAP_ENABLE_SPINNER="${2:-}"
        shift 2
        ;;
      --download-progress)
        AAP_DOWNLOAD_PROGRESS="${2:-}"
        shift 2
        ;;
      --debug-trace)
        AAP_DEBUG_TRACE="${2:-}"
        shift 2
        ;;
      --ansible-verbosity)
        CLI_ANSIBLE_VERBOSITY="${2:-}"
        ANSIBLE_VERBOSITY="${2:-}"
        shift 2
        ;;
      *)
        err "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

menu() {
  local choice=""
  while true; do
    clear
    cat <<'MENU'
AAP 2.7 Installer
=================
1) Quick standard install flow
2) Run preflight checks
3) Prepare host (packages, identity, admin user, credentials)
4) Prepare bundle (download, extract, update inventory)
5) Execute playbook
6) Inspect status
7) Reset env and reprompt
0) Exit
MENU
    read -r -p "Select option: " choice
    case "${choice}" in
      1) run_quick_standard_install_flow; pause_enter ;;
      2) preflight_dependency_checks; pause_enter ;;
      3) prework_packages; set_fqdn_and_hosts; setup_admin_user; capture_credentials; pause_enter ;;
      4) download_bundle; extract_bundle; modify_inventory_growth; pause_enter ;;
      5) run_execution_playbook "${AAP_PLAYBOOK:-install}"; pause_enter ;;
      6) show_status; pause_enter ;;
      7) reset_env_and_reprompt; load_env; initial_install_scope_prompt; refresh_runtime_paths; show_status; pause_enter ;;
      0) exit 0 ;;
      *) warn "Invalid option"; pause_enter ;;
    esac
  done
}

main() {
  trap handle_interrupt INT TERM
  disable_inherited_xtrace
  require_root
  initialize_env_file
  load_env
  if [[ "${AAP_RESET_ENV:-0}" == "1" ]]; then
    reset_env_and_reprompt
    load_env
  fi
  prompt_for_missing_runtime_settings
  validate_non_interactive_requirements || exit 1
  initial_install_scope_prompt
  refresh_runtime_paths
  if [[ "${AAP_APPLY_PATCHES_ONLY:-0}" == "1" ]]; then
    apply_collection_patches || exit 1
    ok "Applied collection patches (apply-patches-only)"
    exit 0
  fi
  if ! is_remote_install_scope; then
    run_privileged mkdir -p "${DOWNLOAD_DIR}"
  fi
  show_startup_banner
  if is_interactive_mode; then
    menu
  else
    run_quick_standard_install_flow
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  parse_cli_args "$@"
  main "$@"
fi
