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

get_install_target_fqdn() {
  load_env
  if [[ "${INSTALL_SCOPE:-}" == "remote" ]]; then
    printf '%s' "${AAP_CONTROLLER_FQDN:-${AAP_CONTROLLER_IP:-aap.localdomain}}"
  else
    hostname -f 2>/dev/null || echo aap.localdomain
  fi
}

get_install_target_host() {
  load_env
  if [[ "${INSTALL_SCOPE:-}" == "remote" ]]; then
    printf '%s' "${AAP_CONTROLLER_IP:-${AAP_CONTROLLER_FQDN:-aap.localdomain}}"
  else
    hostname -f 2>/dev/null || echo aap.localdomain
  fi
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
bootstrap_remote_admin() {
    local target_host="$1"
    local local_pub_key="$HOME/.ssh/id_ed25519.pub"
    local py_bin="${SCRIPT_DIR:-.}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR:-.}/lib/env_yaml.py"
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"

    # Fetch RHSM and Root credentials from Vault
    local rhsm_u rhsm_p rhsm_token root_p
    rhsm_u="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_user 2>/dev/null || echo "")"
    [[ -z "$rhsm_u" ]] && rhsm_u="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" RHSM_USERNAME 2>/dev/null || echo "")"
    rhsm_p="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_password 2>/dev/null || echo "")"
    [[ -z "$rhsm_p" ]] && rhsm_p="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" RHSM_PASSWORD 2>/dev/null || echo "")"
    rhsm_token="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rh_offline_token 2>/dev/null || echo "")"
    
    root_p="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" root_password 2>/dev/null || echo "")"
    [[ -z "$root_p" ]] && root_p="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" ROOT_PASSWORD 2>/dev/null || echo "")"

    # Prompt if root password is still missing
    if [[ -z "$root_p" ]]; then
        read -r -s -p "Enter root password for remote target host ($target_host): " root_p
        echo ""
        if [[ -n "$root_p" ]]; then
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "root_password" "$root_p"
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "ROOT_PASSWORD" "$root_p"
        fi
    fi

    # Ensure local SSH key exists on installer host
    if [[ ! -f "$local_pub_key" ]]; then
        echo "[INFO] Generating local SSH key pair on installer host..."
        ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" <<< y >/dev/null 2>&1 || true
    fi

    local pub_key_str
    pub_key_str="$(cat "$local_pub_key")"

    echo "[INFO] Bootstrapping target host $target_host via root@${target_host}..."

    # Build SSH command with sshpass if root_password is available
    local ssh_cmd=(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10)
    if [[ -n "$root_p" ]] && command -v sshpass &>/dev/null; then
        ssh_cmd=(sshpass -p "$root_p" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10)
    fi

    "${ssh_cmd[@]}" "root@${target_host}" bash -s <<REMOTE_BOOTSTRAP
set -euo pipefail

# 1. RHSM Registration check
if command -v subscription-manager &>/dev/null; then
    if ! subscription-manager status &>/dev/null; then
        echo "[INFO] Target host is not registered with RHSM. Registering..."
        if [[ -n "$rhsm_token" ]]; then
            subscription-manager register --offline_token="$rhsm_token" --auto-attach || true
        elif [[ -n "$rhsm_u" && -n "$rhsm_p" ]]; then
            subscription-manager register --username="$rhsm_u" --password="$rhsm_p" --auto-attach || true
        else
            echo "[WARN] No RHSM credentials provided; skipping subscription-manager registration."
        fi
    else
        echo "[OK] Target host is already registered with RHSM."
    fi
fi

# 2. System update
echo "[INFO] Updating system packages via dnf -y upgrade..."
dnf -y upgrade || yum -y upgrade

# 3. Create admin user and assign administrative/service groups
if ! id "admin" &>/dev/null; then
    useradd -m -s /bin/bash admin
    echo "[+] Created 'admin' user on target."
fi

for grp in wheel sudo podman docker systemd-journal input video; do
    getent group "\$grp" &>/dev/null || groupadd -r "\$grp" 2>/dev/null || true
    usermod -aG "\$grp" admin 2>/dev/null || true
done

# 4. Configure passwordless sudo for admin
echo "admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/admin
chmod 0440 /etc/sudoers.d/admin

# 5. Inject local user's public SSH key into admin's authorized_keys
mkdir -p /home/admin/.ssh
chmod 700 /home/admin/.ssh
if ! grep -qF "$pub_key_str" /home/admin/.ssh/authorized_keys 2>/dev/null; then
    echo "$pub_key_str" >> /home/admin/.ssh/authorized_keys
fi
chown -R admin:admin /home/admin/.ssh
chmod 600 /home/admin/.ssh/authorized_keys

# 6. Enable lingering for rootless Podman
loginctl enable-linger admin 2>/dev/null || true
REMOTE_BOOTSTRAP

    echo "[OK] Root bootstrap, RHSM registration, DNF upgrade, and admin user provisioning complete!"
}

get_install_scope() {
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local py_bin="${SCRIPT_DIR:-.}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR:-.}/lib/env_yaml.py"
    local scope=""

    if [[ -f "$env_file" && -x "$py_bin" && -f "$helper" ]]; then
        scope="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" Ansible_2.7_install INSTALL_SCOPE 2>/dev/null || echo "")"
    fi
    echo "${scope:-remote}"
}
