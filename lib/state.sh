# shellcheck shell=bash
# Installer state persistence. This file is sourced by aap27_menu_installer.sh.

initialize_env_file() {
  local env_dir candidate
  local -a candidates

  env_dir="$(dirname "${ENV_FILE}")"

  if [[ ( -f "${ENV_FILE}" && -w "${ENV_FILE}" ) || ( -d "${env_dir}" && -w "${env_dir}" ) ]]; then
    mkdir -p "${env_dir}"
    touch "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
    return 0
  fi

  candidates=(
    "${HOME:-}/.aap27_install.env"
    "/tmp/.aap27_install_${USER:-$(id -u)}.env"
    "${PWD}/.aap27_install.env"
  )

  for candidate in "${candidates[@]}"; do
    [[ -n "${candidate}" ]] || continue
    [[ "${candidate}" == "${ENV_FILE}" ]] && continue

    env_dir="$(dirname "${candidate}")"
    if [[ ! -d "${env_dir}" ]] && ! mkdir -p "${env_dir}" 2>/dev/null; then
      continue
    fi
    if [[ ! -w "${env_dir}" ]]; then
      continue
    fi
    if touch "${candidate}" 2>/dev/null; then
      warn "Cannot write to ${ENV_FILE}; using ${candidate} for installer state."
      ENV_FILE="${candidate}"
      chmod 600 "${ENV_FILE}" || true
      return 0
    fi
  done

  err "Unable to initialize installer env file. Tried: ${ENV_FILE}, ${HOME:-<unset>}/.aap27_install.env, /tmp/.aap27_install_${USER:-uid}.env, ${PWD}/.aap27_install.env"
  err "Fix directory permissions or export ENV_FILE to a writable path and re-run."
  exit 1
}

state_key_allowed() {
  case "$1" in
    AAP_CONTROLLER_FQDN|AAP_CONTROLLER_IP|AAP_CONTROLLER_SSH_KEY|AAP_CONTROLLER_USER|\
    AAP_REMOTE_ROOT_PASSWORD|AAP_REMOTE_USER|ADMIN_PASSWORD|ANSIBLE_VERBOSITY|\
    BUNDLE_DIR_NAME|BUNDLE_URL|CDN_PASSWORD|CDN_USERNAME|CONSOLE_PASSWORD|\
    CONSOLE_USERNAME|INSTALL_SCOPE|REDHAT_PASSWORD|REDHAT_USERNAME|RH_AH_TOKEN|\
    RH_OFFLINE_TOKEN|RHSM_PASSWORD|RHSM_USERNAME)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

load_env() {
  local line key encoded decoded legacy_quote

  if [[ -f "${ENV_FILE}" ]]; then
    legacy_quote="'\"'\"'"
    while IFS= read -r line || [[ -n "${line}" ]]; do
      if [[ "${line}" =~ ^([A-Z][A-Z0-9_]*)_B64=([A-Za-z0-9+/=]*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        encoded="${BASH_REMATCH[2]}"
        state_key_allowed "${key}" || continue
        if ! decoded="$(printf '%s' "${encoded}" | base64 --decode 2>/dev/null)"; then
          warn "Ignoring invalid base64 state value for ${key} in ${ENV_FILE}."
          continue
        fi
        printf -v "${key}" '%s' "${decoded}"
      elif [[ "${line}" =~ ^([A-Z][A-Z0-9_]*)=\'(.*)\'$ ]]; then
        key="${BASH_REMATCH[1]}"
        decoded="${BASH_REMATCH[2]}"
        state_key_allowed "${key}" || continue
        decoded="${decoded//${legacy_quote}/\'}"
        printf -v "${key}" '%s' "${decoded}"
      fi
    done < "${ENV_FILE}"
  fi

  # shellcheck disable=SC2034
  INVENTORY_FILE="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}/inventory-growth"
}

save_env_kv() {
  local key="$1"
  local val="$2"
  local encoded tmp_file

  if ! state_key_allowed "${key}"; then
    err "Refusing to persist unknown installer state key: ${key}"
    return 1
  fi

  mkdir -p "$(dirname "${ENV_FILE}")"
  touch "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"

  encoded="$(printf '%s' "${val}" | base64 -w0)"
  tmp_file="${ENV_FILE}.tmp.$$"
  grep -vE "^${key}(_B64)?=" "${ENV_FILE}" > "${tmp_file}" || true
  printf '%s_B64=%s\n' "${key}" "${encoded}" >> "${tmp_file}"
  chmod 600 "${tmp_file}"
  mv -f "${tmp_file}" "${ENV_FILE}"
}

delete_env_key() {
  local key="$1"
  local tmp_file

  [[ -f "${ENV_FILE}" ]] || return 0
  state_key_allowed "${key}" || return 1

  tmp_file="${ENV_FILE}.tmp.$$"
  grep -vE "^${key}(_B64)?=" "${ENV_FILE}" > "${tmp_file}" || true
  chmod 600 "${tmp_file}"
  mv -f "${tmp_file}" "${ENV_FILE}"
}
