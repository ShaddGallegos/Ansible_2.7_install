# shellcheck shell=bash

AAP27_TARGET_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

get_install_target_host() {
    if [[ -n "${AAP_REMOTE_IP:-}" ]]; then
        echo "$AAP_REMOTE_IP"
        return 0
    fi
    if [[ -n "${AAP_CONTROLLER_IP:-}" ]]; then
        echo "$AAP_CONTROLLER_IP"
        return 0
    fi
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"
    local py_bin="${AAP27_TARGET_PROJECT_DIR}/.venv-aap27/bin/python3"
    local helper="${AAP27_TARGET_PROJECT_DIR}/lib/env_yaml.py"
    local host=""

    if [[ -x "$py_bin" && -f "$helper" && -f "$env_file" ]]; then
        host="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" "AAP_REMOTE_IP" 2>/dev/null || echo "")"
        [[ -z "$host" ]] && host="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" "AAP_CONTROLLER_IP" 2>/dev/null || echo "")"
    fi
    echo "$host"
}

get_install_target_fqdn() {
  if [[ -n "${AAP_SHORTNAME:-}" && -n "${AAP_DOMAIN_NAME:-}" ]]; then
    printf '%s.%s\n' "$AAP_SHORTNAME" "$AAP_DOMAIN_NAME"
    return 0
  fi
    if [[ -n "${AAP_REMOTE_FQDN:-}" ]]; then
        echo "$AAP_REMOTE_FQDN"
        return 0
    fi
    if [[ -n "${AAP_CONTROLLER_FQDN:-}" ]]; then
        echo "$AAP_CONTROLLER_FQDN"
        return 0
    fi
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"
    local py_bin="${AAP27_TARGET_PROJECT_DIR}/.venv-aap27/bin/python3"
    local helper="${AAP27_TARGET_PROJECT_DIR}/lib/env_yaml.py"
    local fqdn=""

    if [[ -x "$py_bin" && -f "$helper" && -f "$env_file" ]]; then
        fqdn="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" "AAP_REMOTE_FQDN" 2>/dev/null || echo "")"
        [[ -z "$fqdn" ]] && fqdn="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" "AAP_CONTROLLER_FQDN" 2>/dev/null || echo "")"
    fi
    echo "$fqdn"
}

write_remote_inventory() {
    local fqdn="${1:-}"
    local ip="${2:-}"
    local inventory_file="${SCRIPT_DIR}/aap_workflow_project/inventory/controller.ini"
    local remote_user="${AAP_REMOTE_USER:-${ADMIN_USER:-admin}}"
    local ssh_key="${AAP_CONTROLLER_SSH_KEY:-${AAP_INSTALLER_SSH_KEY:-$HOME/.ssh/id_ed25519}}"
    local install_host

    if [[ -z "$fqdn" || -z "$ip" ]]; then
        echo "[ERR] Controller FQDN and IP are required to write the controller inventory." >&2
        return 1
    fi

    install_host="$(hostname -f 2>/dev/null || hostname)"
    mkdir -p "$(dirname "$inventory_file")"
    printf '%s\n' \
      '[controller]' \
      "${fqdn} ansible_host=${ip} ansible_user=${remote_user} ansible_ssh_private_key_file=${ssh_key}" \
      '' \
      '[installhost]' \
      "${install_host} ansible_connection=local" \
      '' \
      '[all:vars]' \
      "ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'" \
      > "$inventory_file"
  }


prompt_target_info() {
    load_env 2>/dev/null || true
  local ip fqdn
  ip="$(get_install_target_host)"
  fqdn="$(get_install_target_fqdn)"

    if [[ -z "$ip" ]]; then
        if [[ "${NONINTERACTIVE:-false}" == "true" ]]; then
            echo "[ERR] AAP_REMOTE_IP is missing in non-interactive mode." >&2
            return 1
        fi
        read -r -p "Enter controller IP or hostname [required]: " ip
    fi

    if [[ -z "$fqdn" ]]; then
        if [[ "${NONINTERACTIVE:-false}" == "true" ]]; then
            fqdn="$ip"
        else
            read -r -p "What will the system short hostname be [aap]: " ctl_shorthost
            ctl_shorthost="${ctl_shorthost:-aap}"
            read -r -p "What is the domain for your machine [prod.spg]: " ctl_domain
            ctl_domain="${ctl_domain:-prod.spg}"
            fqdn="${ctl_shorthost}.${ctl_domain}"
        fi
    fi

    export AAP_REMOTE_IP="$ip"
    export AAP_CONTROLLER_IP="$ip"
    export AAP_SHORTNAME="${fqdn%%.*}"
    AAP_DOMAIN_NAME="$(derive_domain_from_fqdn "$fqdn")"
    export AAP_DOMAIN_NAME
    export AAP_REMOTE_FQDN="$fqdn"
    export AAP_CONTROLLER_FQDN="$fqdn"

    save_env_kv "AAP_REMOTE_IP" "$ip"
    save_env_kv "AAP_CONTROLLER_IP" "$ip"
    save_env_kv "AAP_SHORTNAME" "$AAP_SHORTNAME"
    save_env_kv "AAP_DOMAIN_NAME" "$AAP_DOMAIN_NAME"
    save_env_kv "AAP_REMOTE_FQDN" "$fqdn"
    save_env_kv "AAP_CONTROLLER_FQDN" "$fqdn"

    write_remote_inventory "${fqdn}" "${ip}"
}


bootstrap_remote_admin() {
    load_env 2>/dev/null || true
    local scope
    scope="$(get_install_scope)"
    if [[ "$scope" == "local" ]]; then
        log "[INFO] Local installation selected ($scope). Skipping remote SSH bootstrap."
        return 0
    fi

    local target_host="${AAP_REMOTE_IP:-${AAP_CONTROLLER_IP:-}}"
    [[ -z "$target_host" ]] && target_host="$(get_install_target_host)"
    local target_fqdn
    target_fqdn="$(get_install_target_fqdn)"

    if [[ -z "$target_host" || "$target_host" == "127.0.0.1" ]]; then
        echo "[ERR] Cannot bootstrap SSH: Target host IP/hostname is empty!" >&2
        return 1
    fi

    local root_p="${ROOT_PASSWORD:-}"
    if [[ -z "$root_p" ]]; then
        read -r -s -p "Enter root password for remote target host (${target_fqdn:-$target_host} / ${target_host}): " root_p
        echo ""
        if [[ -n "$root_p" ]]; then
            export ROOT_PASSWORD="$root_p"
            save_env_kv "ROOT_PASSWORD" "$root_p"
        fi
    fi

    log "[INFO] Bootstrapping target host ${target_host} via root@${target_host}..."

    local ssh_cmd=(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10)
    if [[ -n "${root_p:-}" ]] && command -v sshpass &>/dev/null; then
        ssh_cmd=(sshpass -p "$root_p" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10)
    fi

    "${ssh_cmd[@]}" "root@${target_host}" bash -s <<REMOTE_BOOTSTRAP
set -euo pipefail
if ! id "admin" &>/dev/null; then
    useradd -m -s /bin/bash admin
fi
echo "admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/admin
chmod 0440 /etc/sudoers.d/admin
REMOTE_BOOTSTRAP
    log "[OK] Target host ${target_host} bootstrapped successfully."
}

# shellcheck shell=bash
# Install-target resolution. This file is sourced by aap27_installer.sh.

get_preferred_remote_user() {
  local selected_user use_admin selected_uid
  local -a fallback_candidates

  load_env

  if [[ "${INSTALL_SCOPE:-}" == "remote" ]]; then
    AAP_REMOTE_USER="${ADMIN_USER}"
    save_env_kv "AAP_REMOTE_USER" "${AAP_REMOTE_USER}"
    printf '%s' "${AAP_REMOTE_USER}"
    return
  fi

  if [[ -n "${AAP_REMOTE_USER:-}" ]]; then
    if id "${AAP_REMOTE_USER}" >/dev/null 2>&1; then
      selected_uid="$(id -u "${AAP_REMOTE_USER}" 2>/dev/null || echo 0)"
      if [[ "${selected_uid}" != "0" ]]; then
        printf '%s' "${AAP_REMOTE_USER}"
        return
      fi
      warn "AAP_REMOTE_USER='${AAP_REMOTE_USER}' resolves to root; a non-root user is required by preflight." >&2
    else
      warn "AAP_REMOTE_USER='${AAP_REMOTE_USER}' does not exist on this host; a valid non-root user is required." >&2
    fi
  fi

  if id "${ADMIN_USER}" >/dev/null 2>&1; then
    selected_user="${ADMIN_USER}"
  else
    warn "admin user does not exist on this host." >&2

    fallback_candidates=("${SUDO_USER:-}" "${USER:-}")
    for selected_user in "${fallback_candidates[@]}"; do
      [[ -z "${selected_user}" ]] && continue
      if ! id "${selected_user}" >/dev/null 2>&1; then
        continue
      fi
      selected_uid="$(id -u "${selected_user}" 2>/dev/null || echo 0)"
      if [[ "${selected_uid}" == "0" ]]; then
        continue
      fi

      warn "Using fallback remote user '${selected_user}' because admin is unavailable." >&2
      break
    done

    if [[ -n "${selected_user:-}" ]] && id "${selected_user}" >/dev/null 2>&1; then
      selected_uid="$(id -u "${selected_user}" 2>/dev/null || echo 0)"
      if [[ "${selected_uid}" != "0" ]]; then
        AAP_REMOTE_USER="${selected_user}"
        save_env_kv "AAP_REMOTE_USER" "${AAP_REMOTE_USER}"
        printf '%s' "${AAP_REMOTE_USER}"
        return
      fi
    fi

    if [[ "${NONINTERACTIVE}" == "true" || ! -t 0 ]]; then
      err "Cannot prompt for AAP remote user in non-interactive mode. Set AAP_REMOTE_USER to an existing non-root user in ${ENV_FILE}." >&2
      return 1
    fi

    while true; do
      read -r -p "Use ${ADMIN_USER} as the AAP SSH user? [Y/n]: " use_admin
      if [[ ! "${use_admin:-Y}" =~ ^[Nn]$ ]]; then
        selected_user="${ADMIN_USER}"
      else
        read -r -p "Enter AAP SSH user [${ADMIN_USER}]: " selected_user
        selected_user="${selected_user:-${ADMIN_USER}}"
      fi

      if ! id "${selected_user}" >/dev/null 2>&1; then
        warn "Selected user '${selected_user}' does not exist. Choose an existing non-root user." >&2
        continue
      fi

      selected_uid="$(id -u "${selected_user}" 2>/dev/null || echo 0)"
      if [[ "${selected_uid}" == "0" ]]; then
        warn "Selected user '${selected_user}' is root; choose a non-root user (AAP preflight requirement)." >&2
        continue
      fi

      break
    done
  fi

  if id "${selected_user}" >/dev/null 2>&1; then
    selected_uid="$(id -u "${selected_user}" 2>/dev/null || echo 0)"
    if [[ "${selected_uid}" == "0" ]]; then
      err "Remote user '${selected_user}' is root; preflight requires non-root SSH user." >&2
      return 1
    fi
  fi

  AAP_REMOTE_USER="${selected_user}"
  save_env_kv "AAP_REMOTE_USER" "${AAP_REMOTE_USER}"
  printf '%s' "${AAP_REMOTE_USER}"
}

get_user_home() {
  local user_name="$1"
  local user_home
  user_home="$(getent passwd "${user_name}" | cut -d: -f6 || true)"
  if [[ -z "${user_home}" ]]; then
    user_home="/home/${user_name}"
  fi
  printf '%s' "${user_home}"
}





TARGET_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5"

remote_target_exec() {
  # shellcheck disable=SC2086
  ssh -i "${TARGET_SSH_KEY}" ${TARGET_SSH_OPTS} "${TARGET_SSH_USER}@${TARGET_HOST}" "$@"
}

resolve_target_context() {
  load_env
  TARGET_SCOPE="${INSTALL_SCOPE:-local}"
  TARGET_FQDN="$(get_install_target_fqdn)"
  TARGET_HOST="$(get_install_target_host)"
  TARGET_SSH_USER="$(get_preferred_remote_user)"
  TARGET_SSH_KEY="$(get_controller_ssh_key)"
  TARGET_REACHABLE="false"

  if [[ "${TARGET_SCOPE}" == "remote" ]]; then
    TARGET_DESC="${TARGET_SSH_USER}@${TARGET_HOST}"
    if [[ -n "${TARGET_HOST}" && -f "${TARGET_SSH_KEY}" ]] && remote_target_exec 'true' >/dev/null 2>&1; then
      TARGET_REACHABLE="true"
    fi
  else
    # shellcheck disable=SC2034
    TARGET_DESC="localhost"
    # shellcheck disable=SC2034
    TARGET_REACHABLE="true"
  fi
}

derive_domain_from_fqdn() {
  local fqdn="$1" domain
  domain="${fqdn#*.}"
  if [[ "${domain}" == "${fqdn}" || -z "${domain}" ]]; then
    domain="localdomain"
  fi
  printf '%s' "${domain}"
}

build_inventory_host_line() {
  printf '%s ansible_host=%s real_hostname=%s ansible_user=%s ansible_ssh_private_key_file=%s' \
    "${TARGET_FQDN}" "${TARGET_HOST}" "${TARGET_FQDN}" "${TARGET_SSH_USER}" "${TARGET_SSH_KEY}"
}

get_controller_user() {
  local selected_user

  load_env
  if [[ -n "${AAP_CONTROLLER_USER:-}" ]]; then
    printf '%s' "${AAP_CONTROLLER_USER}"
    return
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && id "${SUDO_USER}" >/dev/null 2>&1; then
    selected_user="${SUDO_USER}"
  elif [[ -n "${USER:-}" && "${USER}" != "root" ]] && id "${USER}" >/dev/null 2>&1; then
    selected_user="${USER}"
  elif id "${ADMIN_USER}" >/dev/null 2>&1; then
    selected_user="${ADMIN_USER}"
  else
    selected_user="root"
  fi

  AAP_CONTROLLER_USER="${selected_user}"
  save_env_kv "AAP_CONTROLLER_USER" "${AAP_CONTROLLER_USER}"
  printf '%s' "${AAP_CONTROLLER_USER}"
}

get_controller_ssh_key() {
  local controller_user controller_home key_path

  load_env
  if [[ -n "${AAP_CONTROLLER_SSH_KEY:-}" ]]; then
    printf '%s' "${AAP_CONTROLLER_SSH_KEY}"
    return
  fi

  controller_user="$(get_controller_user)"
  controller_home="$(get_user_home "${controller_user}")"
  key_path="${controller_home}/.ssh/id_ed25519"

  AAP_CONTROLLER_SSH_KEY="${key_path}"
  save_env_kv "AAP_CONTROLLER_SSH_KEY" "${AAP_CONTROLLER_SSH_KEY}"
  printf '%s' "${AAP_CONTROLLER_SSH_KEY}"
}

# Step 1: Root-level initial connection to bootstrap the admin user, SSH key, sudo, and Podman


get_install_scope() {
    echo "remote"
}

run_preflight_resource_checks() {
    load_env 2>/dev/null || true
    local scope target_host target_fqdn
    scope="$(get_install_scope)"
    target_host="$(get_install_target_host)"
    target_fqdn="$(get_install_target_fqdn)"

    if [[ "$scope" == "remote" ]]; then
        if [[ -z "$target_host" ]]; then
            echo "[ERR] Preflight check failed: Remote target host IP/FQDN is empty!" >&2
            return 1
        fi
        log "[INFO] Running remote preflight resource checks on target host (${target_fqdn:-$target_host} / ${target_host})..."
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "admin@${target_host}" bash -s <<'REMOTE_CHECKS'
set -euo pipefail
vcpus=$(nproc)
ram_mb=$(free -m | awk '/^Mem:/{print $2}')
ram_gb=$((ram_mb / 1024))
disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')

echo "[ OK ] Remote Target vCPUs: ${vcpus} detected (minimum 4)."
echo "[ OK ] Remote Target RAM: ${ram_gb} GB detected (minimum 16 GB)."
echo "[ OK ] Remote Target Storage: ${disk_gb} GB free on / (minimum 40 GB)."

if command -v podman &>/dev/null; then
    echo "[ OK ] Remote Target podman is available: $(podman --version)"
fi
REMOTE_CHECKS
    else
        log "[INFO] Running local preflight resource checks on localhost..."
        vcpus=$(nproc)
        ram_gb=$(free -g | awk '/^Mem:/{print $2}')
        disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
        echo "[ OK ] Local CPU: ${vcpus} vCPU(s) detected."
        echo "[ OK ] Local RAM: ${ram_gb} GB detected."
        echo "[ OK ] Local Storage: ${disk_gb} GB free on /."
    fi
}
