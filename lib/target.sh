# shellcheck shell=bash
# Install-target resolution. This file is sourced by aap27_menu_installer.sh.

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
