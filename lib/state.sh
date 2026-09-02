# shellcheck shell=bash

AAP27_STATE_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
AAP27_STATE_KEYS=(
    INSTALL_SCOPE NONINTERACTIVE ADMIN_USER ADMIN_HOME ADMIN_PASSWORD
    AAP_REMOTE_USER AAP_REMOTE_ROOT_PASSWORD ROOT_PASSWORD AAP_REMOTE_IP
    AAP_CONTROLLER_IP AAP_SHORTNAME AAP_DOMAIN_NAME AAP_REMOTE_FQDN
    AAP_CONTROLLER_FQDN AAP_CONTROLLER_USER AAP_CONTROLLER_SSH_KEY
    AAP_INSTALLER_USER AAP_INSTALLER_SSH_KEY ANSIBLE_VERBOSITY
    BUNDLE_URL BUNDLE_FILE BUNDLE_DIR_NAME AAP_EXECUTION_PLAYBOOK
    AAP_ANSIBLE_PLAYBOOK AAP_AUTO_CREATE_ANSIBLE_VENV
    AAP_APPLY_COLLECTION_PATCHES AAP_CLEANUP_BUNDLE_ARCHIVE
    AAP_CLEANUP_PURGE_DOWNLOADS AAP_AUTO_CLEANUP_ON_UNINSTALL
    LOCAL_BUNDLE_PATH AAP_MIN_CPU AAP_MIN_RAM_GB AAP_MIN_DISK_GB
    SUBUID_START SUBUID_COUNT ENABLE_PODMAN_SOCKET ENABLE_ROOTFUL_PODMAN_SOCKET
    RHSM_USERNAME RHSM_PASSWORD
    RH_OFFLINE_TOKEN RH_AH_TOKEN CDN_USERNAME CDN_PASSWORD REDHAT_USERNAME
    REDHAT_PASSWORD REDHAT_REGISTRY_USERNAME REDHAT_REGISTRY_PASSWORD
    CONSOLE_USERNAME CONSOLE_PASSWORD POSTGRESQL_ADMIN_PASSWORD
    CONTROLLER_ADMIN_PASSWORD CONTROLLER_PG_PASSWORD GATEWAY_ADMIN_PASSWORD
    GATEWAY_PG_PASSWORD HUB_ADMIN_PASSWORD HUB_PG_PASSWORD EDA_ADMIN_PASSWORD
    EDA_PG_PASSWORD AUTOMATIONMETRICS_ADMIN_PASSWORD
    AUTOMATIONMETRICS_PG_PASSWORD
    AUTOMATIONMETRICS_CONTROLLER_READ_PG_PASSWORD
    INVENTORY_GROWTH_USERNAME INVENTORY_GROWTH_PASSWORD
    CONTROLLER_PG_HOST CONTROLLER_PG_USER GATEWAY_PG_HOST GATEWAY_PG_USER
    HUB_PG_HOST HUB_PG_USER EDA_PG_HOST EDA_PG_USER
    AUTOMATIONMETRICS_PG_HOST AUTOMATIONMETRICS_PG_USER
    AUTOMATIONMETRICS_CONTROLLER_READ_PG_HOST
    AUTOMATIONMETRICS_CONTROLLER_READ_PG_USER
    AAP_CONTROLLER_HOST AAP_VALIDATE_CERTS AAP_CONTROLLER_OAUTH_TOKEN
    AAP_CONTROLLER_USERNAME AAP_CONTROLLER_PASSWORD AAP_ORG_NAME
    AAP_INVENTORY_NAME AAP_INVENTORY_DESCRIPTION WORKFLOW_PROJECT_NAME
    WORKFLOW_PROJECT_URL WORKFLOW_PROJECT_BRANCH MACHINE_CREDENTIAL_NAME
    MACHINE_CREDENTIAL_USERNAME MACHINE_CREDENTIAL_PASSWORD
    REGISTRY_CREDENTIAL_NAME JOB_TEMPLATE_PREWORK_NAME
    JOB_TEMPLATE_HOST_IDENTITY_NAME JOB_TEMPLATE_DOWNLOAD_NAME
    JOB_TEMPLATE_INSTALL_NAME AAP_WORKFLOW_TEMPLATE_NAME
)

legacy_state_available() {
    local legacy_file="${1:-$HOME/.aap27_install.env}"
    [[ -f "$legacy_file" ]] && grep -qE '^[A-Za-z0-9_]+_B64=[A-Za-z0-9+/=]+$' "$legacy_file"
}

load_env() {
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local legacy_env_file="$HOME/.aap27_install.env"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"
    local py_bin="${AAP27_STATE_PROJECT_DIR}/.venv-aap27/bin/python3"
    local helper="${AAP27_STATE_PROJECT_DIR}/lib/env_yaml.py"

    # Import old Base64 state only when the canonical YAML state does not exist.
    if [[ ! -s "$env_file" ]] && legacy_state_available "$legacy_env_file"; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^([A-Za-z0-9_]+)_B64=([A-Za-z0-9+/=]+)$ ]]; then
                local base_key="${BASH_REMATCH[1]}"
                local encoded="${BASH_REMATCH[2]}"
                local decoded=""
                decoded="$(printf '%s' "$encoded" | base64 --decode 2>/dev/null || echo "")"
                if [[ -n "$decoded" ]]; then
                    case "$base_key" in
                        RHSM_USERNAME|RHSM_PASSWORD|ROOT_PASSWORD|INSTALL_SCOPE|AAP_REMOTE_IP|AAP_CONTROLLER_IP|AAP_SHORTNAME|AAP_DOMAIN_NAME|AAP_REMOTE_FQDN|AAP_CONTROLLER_FQDN|AAP_REMOTE_USER|INVENTORY_GROWTH_USERNAME|INVENTORY_GROWTH_PASSWORD|REDHAT_REGISTRY_USERNAME|REDHAT_REGISTRY_PASSWORD|RH_OFFLINE_TOKEN|RH_AH_TOKEN|AAP_INSTALLER_SSH_KEY|AAP_INSTALLER_USER)
                            export "${base_key}"="${decoded}"
                            save_env_kv "${base_key}" "${decoded}" || return 1
                            ;;
                    esac
                fi
            fi
        done < "$legacy_env_file"
        ensure_env_schema || return 1
    fi

    if [[ -x "$py_bin" && -f "$helper" && -f "$env_file" ]]; then
        local key val alt_key
        for key in "${AAP27_STATE_KEYS[@]}"; do
            val="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" "$key" 2>/dev/null || echo "")"
            if [[ -z "$val" ]]; then
                alt_key="$(printf '%s' "$proj_key" | tr '[:lower:]' '[:upper:]')"
                val="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$alt_key" "$key" 2>/dev/null || echo "")"
            fi
            if [[ -n "$val" ]]; then
                export "${key}"="${val}"
            fi
        done
    fi

    local configured_fqdn="${AAP_REMOTE_FQDN:-${AAP_CONTROLLER_FQDN:-}}"
    if [[ -n "$configured_fqdn" ]]; then
        export AAP_SHORTNAME="${AAP_SHORTNAME:-${configured_fqdn%%.*}}"
        if [[ "$configured_fqdn" == *.* ]]; then
            export AAP_DOMAIN_NAME="${AAP_DOMAIN_NAME:-${configured_fqdn#*.}}"
        fi
    fi
    export AAP_SHORTNAME="${AAP_SHORTNAME:-aap}"
    export AAP_DOMAIN_NAME="${AAP_DOMAIN_NAME:-prod.spg}"
    export AAP_REMOTE_FQDN="${AAP_SHORTNAME}.${AAP_DOMAIN_NAME}"
    export AAP_CONTROLLER_FQDN="$AAP_REMOTE_FQDN"
}

ensure_rhsm_credentials_exist() {
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"
    local py_bin="${AAP27_STATE_PROJECT_DIR}/.venv-aap27/bin/python3"
    local helper="${AAP27_STATE_PROJECT_DIR}/lib/env_yaml.py"

    ensure_python_venv || return 1

    get_v_key() {
        local k="$1"
        "$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" "$k" 2>/dev/null || echo ""
    }

    set_v_key() {
        local k="$1"
        local v="$2"
        if [[ -n "$v" ]]; then
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "$k" "$v" 2>/dev/null || true
        fi
    }

    # 1. Retrieve stored values
    local saved_user saved_pass saved_offline saved_ah saved_ip saved_fqdn saved_shortname saved_domain saved_root saved_ig_u saved_ig_p saved_scope
    saved_user="${RHSM_USERNAME:-$(get_v_key "RHSM_USERNAME")}"
    saved_pass="${RHSM_PASSWORD:-$(get_v_key "RHSM_PASSWORD")}"
    saved_offline="${RH_OFFLINE_TOKEN:-$(get_v_key "RH_OFFLINE_TOKEN")}"
    saved_ah="${RH_AH_TOKEN:-$(get_v_key "RH_AH_TOKEN")}"
    saved_ip="${AAP_REMOTE_IP:-$(get_v_key "AAP_REMOTE_IP")}"
    [[ -z "$saved_ip" ]] && saved_ip="$(get_v_key "AAP_CONTROLLER_IP")"
    saved_fqdn="${AAP_REMOTE_FQDN:-$(get_v_key "AAP_REMOTE_FQDN")}"
    [[ -z "$saved_fqdn" ]] && saved_fqdn="$(get_v_key "AAP_CONTROLLER_FQDN")"
    saved_shortname="${AAP_SHORTNAME:-$(get_v_key "AAP_SHORTNAME")}"
    saved_domain="${AAP_DOMAIN_NAME:-$(get_v_key "AAP_DOMAIN_NAME")}"
    [[ -z "$saved_shortname" && -n "$saved_fqdn" ]] && saved_shortname="${saved_fqdn%%.*}"
    [[ -z "$saved_domain" && "$saved_fqdn" == *.* ]] && saved_domain="${saved_fqdn#*.}"
    saved_root="${ROOT_PASSWORD:-$(get_v_key "ROOT_PASSWORD")}"
    saved_ig_u="${INVENTORY_GROWTH_USERNAME:-$(get_v_key "INVENTORY_GROWTH_USERNAME")}"
    saved_ig_p="${INVENTORY_GROWTH_PASSWORD:-$(get_v_key "INVENTORY_GROWTH_PASSWORD")}"
    saved_scope="${INSTALL_SCOPE:-$(get_v_key "INSTALL_SCOPE")}"
    [[ -z "$saved_scope" ]] && saved_scope="remote"

    # Reuse canonical state in unattended mode; prompt only when missing.
    local entered_user="${saved_user}"
    if [[ -z "$entered_user" ]]; then
        read -r -p "Enter RHSM_USERNAME: " entered_user
        if [[ -z "$entered_user" ]]; then
            echo "[ERR] RHSM_USERNAME is required in ${env_file}." >&2
            return 1
        fi
    fi

    local user_changed=false
    if [[ -n "$saved_user" && "$entered_user" == "$saved_user" ]]; then
        user_changed=false
    else
        user_changed=true
    fi

    export RHSM_USERNAME="$entered_user"
    set_v_key "RHSM_USERNAME" "$entered_user"

    # 3. Always prompt for missing required secrets (RHSM_PASSWORD & ROOT_PASSWORD) even in --non-interactive mode
    local current_pass="$saved_pass"
    local current_offline="$saved_offline"
    local current_ah="$saved_ah"
    local current_ip="${saved_ip:-192.168.122.84}"
    local current_shortname="${saved_shortname:-aap}"
    local current_domain="${saved_domain:-prod.spg}"
    local current_fqdn="${current_shortname}.${current_domain}"
    local current_root="$saved_root"

    if [[ "$user_changed" == "true" || -z "$current_pass" ]]; then
        read -r -s -p "Enter RHSM_PASSWORD: " current_pass; echo ""
    fi

    if [[ "$user_changed" == "true" || -z "$current_offline" ]]; then
        if [[ "${NONINTERACTIVE:-false}" != "true" || "$user_changed" == "true" ]]; then
            read -r -s -p "Enter RH_OFFLINE_TOKEN (Red Hat Offline API Token) [optional/press Enter]: " current_offline; echo ""
        fi
    fi

    if [[ "$user_changed" == "true" || -z "$current_ah" ]]; then
        if [[ "${NONINTERACTIVE:-false}" != "true" || "$user_changed" == "true" ]]; then
            read -r -s -p "Enter RH_AH_TOKEN (Remote Automation Hub Token) [optional/press Enter]: " current_ah; echo ""
        fi
    fi

    if [[ "$user_changed" == "true" || -z "$saved_ip" ]]; then
        if [[ "${NONINTERACTIVE:-false}" != "true" || "$user_changed" == "true" ]]; then
            read -r -p "Enter AAP_REMOTE_IP [192.168.122.84]: " input_ip
            current_ip="${input_ip:-192.168.122.84}"
        fi
    fi

    if [[ "$user_changed" == "true" || -z "$saved_shortname" || -z "$saved_domain" ]]; then
        if [[ "${NONINTERACTIVE:-false}" != "true" || "$user_changed" == "true" ]]; then
            read -r -p "Enter AAP short hostname [${current_shortname}]: " input_shortname
            current_shortname="${input_shortname:-${current_shortname}}"
            read -r -p "Enter AAP domain name [${current_domain}]: " input_domain
            current_domain="${input_domain:-${current_domain}}"
            current_fqdn="${current_shortname}.${current_domain}"
        fi
    fi

    # Mandatory ROOT_PASSWORD prompt on remote node if missing
    if [[ ("$saved_scope" == "remote" || "${INSTALL_SCOPE:-remote}" == "remote") && ("$user_changed" == "true" || -z "$current_root") ]]; then
        read -r -s -p "Enter Remote Node ROOT_PASSWORD (${current_fqdn} / ${current_ip}): " current_root; echo ""
    fi

    # Inventory-Growth Username & Password
    local current_ig_u="${saved_ig_u:-admin}"
    local current_ig_p="${saved_ig_p:-redhat}"
    if [[ "$user_changed" == "true" || -z "$saved_ig_u" ]]; then
        if [[ "${NONINTERACTIVE:-false}" != "true" || "$user_changed" == "true" ]]; then
            read -r -p "Enter Inventory-Growth USERNAME [${current_ig_u}]: " input_ig_u
            current_ig_u="${input_ig_u:-${current_ig_u}}"
        fi
    fi
    if [[ "$user_changed" == "true" || -z "$saved_ig_p" ]]; then
        if [[ "${NONINTERACTIVE:-false}" != "true" || "$user_changed" == "true" ]]; then
            read -r -s -p "Enter Inventory-Growth PASSWORD [default: redhat]: " input_ig_p; echo ""
            current_ig_p="${input_ig_p:-${current_ig_p}}"
        fi
    fi

    # 4. Export & Persist Variables
    export RHSM_PASSWORD="$current_pass"
    export RH_OFFLINE_TOKEN="$current_offline"
    export RH_AH_TOKEN="$current_ah"
    export AAP_REMOTE_IP="$current_ip"
    export AAP_CONTROLLER_IP="$current_ip"
    export AAP_SHORTNAME="$current_shortname"
    export AAP_DOMAIN_NAME="$current_domain"
    export AAP_REMOTE_FQDN="$current_fqdn"
    export AAP_CONTROLLER_FQDN="$current_fqdn"
    export AAP_REMOTE_USER="admin"
    export INSTALL_SCOPE="${saved_scope:-remote}"
    export ROOT_PASSWORD="$current_root"
    export INVENTORY_GROWTH_USERNAME="$current_ig_u"
    export INVENTORY_GROWTH_PASSWORD="$current_ig_p"
    export REDHAT_REGISTRY_USERNAME="$RHSM_USERNAME"
    export REDHAT_REGISTRY_PASSWORD="$current_pass"
    export AAP_INSTALLER_SSH_KEY="${AAP_INSTALLER_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    export AAP_INSTALLER_USER="${AAP_INSTALLER_USER:-$USER}"

    set_v_key "RHSM_PASSWORD" "$RHSM_PASSWORD"
    set_v_key "RH_OFFLINE_TOKEN" "$RH_OFFLINE_TOKEN"
    set_v_key "RH_AH_TOKEN" "$RH_AH_TOKEN"
    set_v_key "AAP_REMOTE_IP" "$AAP_REMOTE_IP"
    set_v_key "AAP_CONTROLLER_IP" "$AAP_REMOTE_IP"
    set_v_key "AAP_SHORTNAME" "$AAP_SHORTNAME"
    set_v_key "AAP_DOMAIN_NAME" "$AAP_DOMAIN_NAME"
    set_v_key "AAP_REMOTE_FQDN" "$AAP_REMOTE_FQDN"
    set_v_key "AAP_CONTROLLER_FQDN" "$AAP_REMOTE_FQDN"
    set_v_key "AAP_REMOTE_USER" "$AAP_REMOTE_USER"
    set_v_key "INSTALL_SCOPE" "$INSTALL_SCOPE"
    set_v_key "ROOT_PASSWORD" "$ROOT_PASSWORD"
    set_v_key "INVENTORY_GROWTH_USERNAME" "$INVENTORY_GROWTH_USERNAME"
    set_v_key "INVENTORY_GROWTH_PASSWORD" "$INVENTORY_GROWTH_PASSWORD"
    set_v_key "REDHAT_REGISTRY_USERNAME" "$REDHAT_REGISTRY_USERNAME"
    set_v_key "REDHAT_REGISTRY_PASSWORD" "$REDHAT_REGISTRY_PASSWORD"
    set_v_key "AAP_INSTALLER_SSH_KEY" "$AAP_INSTALLER_SSH_KEY"
    set_v_key "AAP_INSTALLER_USER" "$AAP_INSTALLER_USER"

    echo -e "\n=================================================="
    echo "       Verifying Stored AAP Parameters           "
    echo "=================================================="
    echo "  RHSM_USERNAME: ${RHSM_USERNAME}"
    echo "  AAP_REMOTE_FQDN: ${AAP_REMOTE_FQDN}"
    echo "  AAP_REMOTE_IP: ${AAP_REMOTE_IP}"
    echo "  AAP_INSTALLER_SSH_KEY: ${AAP_INSTALLER_SSH_KEY}"
    echo "  AAP_INSTALLER_USER: ${AAP_INSTALLER_USER}"
    echo "  AAP_REMOTE_USER: ${AAP_REMOTE_USER}"
    echo "  INSTALL_SCOPE: ${INSTALL_SCOPE}"
    echo "  INVENTORY_GROWTH_USERNAME: ${INVENTORY_GROWTH_USERNAME}"
    echo "  INVENTORY_GROWTH_PASSWORD: ${INVENTORY_GROWTH_PASSWORD}"
    echo "  RHSM_PASSWORD: [$( [[ -n "$RHSM_PASSWORD" ]] && echo "PRESENT" || echo "NOT SET" )]"
    echo "  RH_OFFLINE_TOKEN: [$( [[ -n "$RH_OFFLINE_TOKEN" ]] && echo "PRESENT" || echo "NOT SET" )]"
    echo "  RH_AH_TOKEN: [$( [[ -n "$RH_AH_TOKEN" ]] && echo "PRESENT" || echo "NOT SET" )]"
    echo "  ROOT_PASSWORD: [$( [[ -n "$ROOT_PASSWORD" ]] && echo "PRESENT" || echo "NOT SET" )]"
    echo "==================================================\n"
}

ensure_registry_credentials() {
    load_env

    if [[ -z "${RHSM_USERNAME:-}" ]]; then
        ask_value RHSM_USERNAME \
            "Enter RHSM_USERNAME (Red Hat Login/CDN/registry/console username)" \
            "${DEFAULT_RHSM_USERNAME:-}" || return 1
        save_env_kv "RHSM_USERNAME" "${RHSM_USERNAME}"
    fi

    if [[ -z "${RHSM_PASSWORD:-}" ]]; then
        read_secret_prompt RHSM_PASSWORD \
            "Enter RHSM_PASSWORD (Red Hat Login/CDN/registry/console password)" || return 1
        save_env_kv "RHSM_PASSWORD" "${RHSM_PASSWORD}"
    fi

    export REDHAT_REGISTRY_USERNAME="${RHSM_USERNAME}"
    export REDHAT_REGISTRY_PASSWORD="${RHSM_PASSWORD}"
}

capture_credentials() {
    ensure_registry_credentials || return 1
    log "[OK] Step 6: Credentials and tokens verified."
}

ensure_required_secret() {
    local variable_name="${1:-}"
    local prompt="${2:-Enter required secret}"
    local -n secret_ref="$variable_name"

    if [[ -n "${secret_ref:-}" ]]; then
        return 0
    fi
    read_secret_prompt "$variable_name" "$prompt" true || return 1
    save_env_kv "$variable_name" "$secret_ref"
}

ensure_installer_secrets() {
    local specification variable_name prompt
    local -a required_secrets=(
        "ADMIN_PASSWORD|Enter admin_password (platform admin and inventory password)"
        "CONTROLLER_ADMIN_PASSWORD|Enter controller_admin_password (AAP Controller admin password)"
        "CONTROLLER_PG_PASSWORD|Enter controller_pg_password (Controller database password)"
        "HUB_ADMIN_PASSWORD|Enter hub_admin_password (Automation Hub admin password)"
        "HUB_PG_PASSWORD|Enter hub_pg_password (Hub database password)"
        "EDA_ADMIN_PASSWORD|Enter eda_admin_password (EDA admin password)"
        "EDA_PG_PASSWORD|Enter eda_pg_password (EDA database password)"
        "POSTGRESQL_ADMIN_PASSWORD|Enter postgresql_admin_password (shared PostgreSQL admin password)"
        "GATEWAY_ADMIN_PASSWORD|Enter gateway_admin_password (Automation Gateway admin password)"
        "GATEWAY_PG_PASSWORD|Enter gateway_pg_password (Automation Gateway database password)"
        "AUTOMATIONMETRICS_ADMIN_PASSWORD|Enter automationmetrics_admin_password"
        "AUTOMATIONMETRICS_PG_PASSWORD|Enter automationmetrics_pg_password"
        "AUTOMATIONMETRICS_CONTROLLER_READ_PG_PASSWORD|Enter automationmetrics_controller_read_pg_password"
    )

    load_env
    for specification in "${required_secrets[@]}"; do
        variable_name="${specification%%|*}"
        prompt="${specification#*|}"
        ensure_required_secret "$variable_name" "$prompt" || return 1
    done
}






















ensure_python_venv() {
    local venv_dir="${SCRIPT_DIR:-.}/.venv-aap27"
    local py_bin="${venv_dir}/bin/python3"

    if [[ ! -x "${py_bin}" ]]; then
        echo -e "[*] Python virtual environment not found at ${venv_dir}. Creating..."
        python3 -m venv "${venv_dir}" || {
            echo -e "[!] Failed to create Python virtual environment." >&2
            return 1
        }
        "${venv_dir}/bin/pip" install --quiet --upgrade pip
        "${venv_dir}/bin/pip" install --quiet pyyaml ansible-core
    fi
}

# shellcheck shell=bash
# Installer state persistence. This file is sourced by aap27_menu_installer.sh.

initialize_env_file() {
    local env_dir

  env_dir="$(dirname "${ENV_FILE}")"
    if ! mkdir -p "${env_dir}" || ! touch "${ENV_FILE}"; then
        err "Unable to initialize canonical installer state file: ${ENV_FILE}"
        err "Fix its directory permissions and re-run."
        return 1
    fi
    chmod 600 "${ENV_FILE}"
    if [[ ! -s "${ENV_FILE}" ]] && legacy_state_available "${HOME}/.aap27_install.env"; then
        return 0
    fi
    ensure_env_schema
}

ensure_env_schema() {
    local py_bin="${AAP27_STATE_PROJECT_DIR}/.venv-aap27/bin/python3"
    local helper="${AAP27_STATE_PROJECT_DIR}/lib/env_yaml.py"
    local template="${AAP27_STATE_PROJECT_DIR}/templates/env.yml.example"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"

    [[ -x "$py_bin" && -f "$helper" && -f "$template" ]] || {
        err "Canonical env schema helper or template is missing."
        return 1
    }

    if [[ ! -f "$vault_pass" ]]; then
        umask 077
        mkdir -p "$(dirname "$vault_pass")"
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$vault_pass"
        printf '\n' >> "$vault_pass"
        chmod 600 "$vault_pass"
    fi

    "$py_bin" "$helper" ensure-schema "$env_file" "$vault_pass" "$proj_key" "$template"
}

state_key_allowed() {
    local key="${1:-}"
    local allowed_key
    for allowed_key in "${AAP27_STATE_KEYS[@]}"; do
        if [[ "$key" == "$allowed_key" ]]; then
            return 0
        fi
    done
    echo "[!] Refusing to persist unsafe or unknown state key: ${key}" >&2
    return 1
}



save_env_kv() {
    local key="$1"
    local val="$2"

    state_key_allowed "${key}" || return 1

    export "${key}"="${val}"

    local py_bin="${AAP27_STATE_PROJECT_DIR}/.venv-aap27/bin/python3"
    local helper="${AAP27_STATE_PROJECT_DIR}/lib/env_yaml.py"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"

    mkdir -p "$(dirname "$env_file")" 2>/dev/null || true
    mkdir -p "$(dirname "$vault_pass")" 2>/dev/null || true
    if [[ ! -f "$vault_pass" ]]; then
        umask 077
        if [[ -n "${VAULT_PASS_VALUE:-}" ]]; then
            printf '%s\n' "$VAULT_PASS_VALUE" > "$vault_pass"
        else
            od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$vault_pass"
            printf '\n' >> "$vault_pass"
        fi
        chmod 600 "$vault_pass"
    fi

    [[ -x "$py_bin" && -f "$helper" ]] || return 1
    "$py_bin" "$helper" ensure-structure "$env_file" "$vault_pass" "$proj_key" || return 1
    "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "$key" "$val"

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



