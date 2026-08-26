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
        rhsm_user|rhsm_password|rh_offline_token|rh_ah_token|RHSM_USERNAME|RHSM_PASSWORD|INSTALL_SCOPE|AAP_CONTROLLER_IP|AAP_CONTROLLER_FQDN|AAP_CONTROLLER_SSH_KEY|AAP_REMOTE_USER|GLOBAL|AAP)
            return 0 ;;
        *)
            return 0 ;;
    esac
}

load_env() {
    local key val line
    local py_bin="${SCRIPT_DIR:-.}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR:-.}/lib/env_yaml.py"
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"

    if [[ -f "$env_file" ]]; then
        # 1. Read Base64/Plaintext lines directly from env.yml
        while IFS= read -r line; do
            if [[ "$line" =~ ^([A-Za-z0-9_]+)_B64=([A-Za-z0-9+/=]+)$ ]]; then
                key="${BASH_REMATCH[1]}"
                val="$(printf %s "${BASH_REMATCH[2]}" | base64 --decode 2>/dev/null || echo "")"
                if [[ -n "$val" ]]; then printf -v "$key" %s "$val"; fi
            elif [[ "$line" =~ ^([A-Za-z0-9_]+)='?(.*)'?$ ]]; then
                key="${BASH_REMATCH[1]}"
                val="${BASH_REMATCH[2]}"
                if [[ -n "$val" && "$key" != "\$ANSIBLE_VAULT" ]]; then printf -v "$key" %s "$val"; fi
            fi
        done < "$env_file"

        # 2. Query Vault for encrypted items if python helper is available
        if [[ -x "$py_bin" && -f "$helper" ]]; then
            for key in rhsm_user rhsm_password RHSM_USERNAME RHSM_PASSWORD root_password ROOT_PASSWORD INSTALL_SCOPE AAP_CONTROLLER_IP AAP_CONTROLLER_FQDN AAP_REMOTE_USER; do
                val="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" "$key" 2>/dev/null || echo "")"
                if [[ -n "$val" ]]; then printf -v "$key" %s "$val"; fi
            done
        fi

        # 3. Alias variables
        if [[ -n "${rhsm_user:-}" ]]; then RHSM_USERNAME="$rhsm_user"; fi
        if [[ -n "${rhsm_password:-}" ]]; then RHSM_PASSWORD="$rhsm_password"; fi
        if [[ -n "${RHSM_USERNAME:-}" ]]; then rhsm_user="$RHSM_USERNAME"; fi
        if [[ -n "${RHSM_PASSWORD:-}" ]]; then rhsm_password="$RHSM_PASSWORD"; fi
        if [[ -n "${root_password:-}" ]]; then ROOT_PASSWORD="$root_password"; fi
        if [[ -n "${ROOT_PASSWORD:-}" ]]; then root_password="$ROOT_PASSWORD"; fi
    fi
}

save_env_kv() {
    local key="$1"
    local val="$2"
    local py_bin="${SCRIPT_DIR:-.}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR:-.}/lib/env_yaml.py"
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"

    if [[ -f "$env_file" && -x "$py_bin" && -f "$helper" ]]; then
        "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "$key" "$val" 2>/dev/null || true
    fi
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

ensure_rhsm_credentials_exist() {
    local env_file="$1"
    local vault_pass="$2"
    local proj_key="$3"
    local py_bin="${SCRIPT_DIR:-.}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR:-.}/lib/env_yaml.py"

    # Test if vault is readable; if corrupted, rebuild it
    if ! "$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_user &>/dev/null; then
        echo -e "[!] Vault corruption detected in $env_file. Resetting vault structure..."
        rm -f "$env_file"
        "$py_bin" "$helper" ensure-structure "$env_file" "$vault_pass" "$proj_key"
        chmod 600 "$env_file"
    fi

    local u p t
    u="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_user 2>/dev/null || echo "")"
    [[ -z "$u" ]] && u="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" RHSM_USERNAME 2>/dev/null || echo "")"
    p="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_password 2>/dev/null || echo "")"
    [[ -z "$p" ]] && p="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" RHSM_PASSWORD 2>/dev/null || echo "")"

    if [[ -z "$u" ]]; then
        echo -e "[!] RHSM_USERNAME is missing."
        read -r -p "Enter RHSM_USERNAME: " u
        if [[ -n "$u" ]]; then
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "rhsm_user" "$u"
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "RHSM_USERNAME" "$u"
        else
            echo "[ERR] Username required." >&2; exit 1
        fi
    fi

    if [[ -z "$p" ]]; then
        echo -e "[!] RHSM_PASSWORD is missing."
        read -r -s -p "Enter RHSM_PASSWORD: " p
        echo ""
        if [[ -n "$p" ]]; then
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "rhsm_password" "$p"
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "RHSM_PASSWORD" "$p"
        else
            echo "[ERR] Password required." >&2; exit 1
        fi
    fi
    local rp
    rp="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" root_password 2>/dev/null || echo "")"
    [[ -z "$rp" ]] && rp="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" ROOT_PASSWORD 2>/dev/null || echo "")"

    if [[ -z "$rp" && "$(get_install_scope 2>/dev/null || echo "")" == "remote" ]]; then
        echo -e "[!] Target host root_password (ROOT_PASSWORD) is missing from Vault."
        read -r -s -p "Enter root password for remote target host: " rp
        echo ""
        if [[ -n "$rp" ]]; then
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "root_password" "$rp"
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "ROOT_PASSWORD" "$rp"
            echo "[+] Saved root_password to Vault."
        fi
    fi
}