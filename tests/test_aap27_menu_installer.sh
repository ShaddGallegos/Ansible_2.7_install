#!/usr/bin/env bash
# Lightweight regression tests for aap27_installer.sh.
# Sources the script's functions and exercises them directly, without touching
# the real system.
# shellcheck disable=SC2030,SC2031,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck disable=SC1090
source "${SCRIPT_DIR}/aap27_installer.sh"

pass_count=0
fail_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "[ OK ] ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] ${desc}: expected '${expected}', got '${actual}'"
    fail_count=$((fail_count + 1))
  fi
}

assert_status() {
  local desc="$1" expected_status="$2"
  shift 2
  local actual_status=0
  "$@" >/dev/null 2>&1 || actual_status=$?
  assert_eq "${desc}" "${expected_status}" "${actual_status}"
}

assert_contains() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == *"${expected}"* ]]; then
    echo "[ OK ] ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] ${desc}: expected output to contain '${expected}'"
    fail_count=$((fail_count + 1))
  fi
}

test_ask_value_and_ask_yn_noninteractive() {
  NONINTERACTIVE=true
  ENV_FILE="/tmp/aap27_test_env_$$"

  local val=""
  ask_value val "Enter something" "mydefault"
  assert_eq "ask_value uses default in non-interactive mode" "mydefault" "${val}"

  assert_status "ask_yn defaults to yes" 0 ask_yn "Proceed? [Y/n]:" "y"
  assert_status "ask_yn defaults to no" 1 ask_yn "Apply? [y/N]:" "n"

  local req=""
  assert_status "ask_value fails with no default and no existing value" 1 ask_value req "Enter required value"
  assert_eq "failed ask_value leaves target empty" "" "${req}"
}

test_required_prompts_reject_empty_values() {
  local required_value="" required_secret=""

  NONINTERACTIVE=false
  ask_value required_value "Enter required value" <<< $'\nconfigured-value' >/dev/null
  assert_eq "required value prompt retries after blank input" "configured-value" "${required_value}"

  read_secret_prompt required_secret "Enter required secret" <<< $'\nconfigured-secret' >/dev/null
  assert_eq "required secret prompt retries after blank input" "configured-secret" "${required_secret}"

  NONINTERACTIVE=true
  assert_status "required secret fails when prompting is unavailable" 1 \
    read_secret_prompt required_secret "Enter required secret"
  required_secret=""
  read_secret_prompt required_secret "Enter forced secret" true <<< 'forced-secret' >/dev/null
  assert_eq "forced secret prompt works during automated mode" "forced-secret" "${required_secret}"
  required_secret=""
  read_secret_prompt required_secret "Enter defaulted secret" true "redhat" <<< '' >/dev/null
  assert_eq "secret prompt accepts configured default" "redhat" "${required_secret}"
}

test_startup_requires_all_primary_secrets() {
  local collector_body
  collector_body="$(declare -f ensure_rhsm_credentials_exist)"

  assert_eq "startup does not require an offline token" "false" \
    "$([[ "${collector_body}" == *'read_secret_prompt current_offline'* ]] && echo true || echo false)"
  assert_contains "startup requires RHSM organization ID" \
    'Enter RHSM_ORG_ID' "${collector_body}"
  assert_contains "startup offers optional RHSM activation key" \
    'Enter optional RHSM_ACTIVATION_KEY' "${collector_body}"
  assert_contains "startup persists RHSM activation key" \
    'set_v_key "RHSM_ACTIVATION_KEY"' "${collector_body}"
  assert_contains "startup reconfirms username after password rejection" \
    'if [[ -z "$saved_pass" ]]' "${collector_body}"
  assert_contains "startup requires Automation Hub token" \
    'read_secret_prompt current_ah "Enter RH_AH_TOKEN' "${collector_body}"
  assert_contains "startup requires admin SSH password" \
    'read_secret_prompt current_admin "Enter Remote Node ADMIN_PASSWORD' "${collector_body}"
  assert_contains "startup requires root SSH password" \
    'read_secret_prompt current_root "Enter Remote Node ROOT_PASSWORD' "${collector_body}"
  assert_contains "startup persists admin SSH password" \
    'set_v_key "ADMIN_PASSWORD" "$ADMIN_PASSWORD"' "${collector_body}"
  assert_contains "startup persists root SSH password" \
    'set_v_key "ROOT_PASSWORD" "$ROOT_PASSWORD"' "${collector_body}"
  assert_contains "startup defaults SSH passwords to redhat" \
    'true "redhat"' "${collector_body}"
  assert_contains "startup reports admin SSH password presence" \
    'ADMIN_PASSWORD: [' "${collector_body}"
  assert_eq "remote bootstrap retains canonical root SSH password" "false" \
    "$([[ "$(declare -f provision_remote_admin_via_ssh)" == *'delete_env_key "ROOT_PASSWORD"'* ]] && echo true || echo false)"
}

test_installer_passwords_default_from_admin_password() {
  local output

  output="$(
    load_env() { :; }
    save_env_kv() { printf 'saved:%s=%s\n' "$1" "$2"; }
    read_secret_prompt() { printf 'unexpected-prompt:%s\n' "$1"; return 1; }

    ADMIN_PASSWORD="redhat"
    CONTROLLER_ADMIN_PASSWORD="explicit-controller-password"
    unset CONTROLLER_PG_PASSWORD HUB_ADMIN_PASSWORD HUB_PG_PASSWORD
    unset EDA_ADMIN_PASSWORD EDA_PG_PASSWORD POSTGRESQL_ADMIN_PASSWORD
    unset GATEWAY_ADMIN_PASSWORD GATEWAY_PG_PASSWORD
    unset AUTOMATIONMETRICS_ADMIN_PASSWORD AUTOMATIONMETRICS_PG_PASSWORD
    unset AUTOMATIONMETRICS_CONTROLLER_READ_PG_PASSWORD
    unset AUTOMATIONMETRICS_HUB_READ_PG_PASSWORD

    ensure_installer_secrets
    printf 'controller-admin=%s\n' "${CONTROLLER_ADMIN_PASSWORD}"
    for key in \
      CONTROLLER_PG_PASSWORD HUB_ADMIN_PASSWORD HUB_PG_PASSWORD \
      EDA_ADMIN_PASSWORD EDA_PG_PASSWORD POSTGRESQL_ADMIN_PASSWORD \
      GATEWAY_ADMIN_PASSWORD GATEWAY_PG_PASSWORD \
      AUTOMATIONMETRICS_ADMIN_PASSWORD AUTOMATIONMETRICS_PG_PASSWORD \
      AUTOMATIONMETRICS_CONTROLLER_READ_PG_PASSWORD \
      AUTOMATIONMETRICS_HUB_READ_PG_PASSWORD; do
      printf '%s=%s\n' "${key}" "${!key}"
    done
  )"

  assert_eq "installer password defaults do not prompt" "false" \
    "$([[ "${output}" == *"unexpected-prompt:"* ]] && echo true || echo false)"
  assert_contains "explicit component password remains unchanged" \
    "controller-admin=explicit-controller-password" "${output}"
  assert_eq "all missing component passwords inherit admin password" "12" \
    "$(grep -c '^[A-Z_]*=redhat$' <<< "${output}")"
  assert_eq "all inherited component passwords are persisted" "12" \
    "$(grep -c '^saved:.*=redhat$' <<< "${output}")"
}

test_derive_domain_from_fqdn() {
  assert_eq "domain from multi-label fqdn" "example.test" "$(derive_domain_from_fqdn "aap.example.test")"
  assert_eq "domain falls back to localdomain for bare hostname" "localdomain" "$(derive_domain_from_fqdn "localhost")"
}

test_build_inventory_host_line() {
  TARGET_FQDN="aap.example.test"
  TARGET_HOST="192.0.2.15"
  TARGET_SSH_USER="admin"
  TARGET_SSH_KEY="/home/example/.ssh/id_ed25519"

  local expected="aap.example.test ansible_host=192.0.2.15 real_hostname=aap.example.test ansible_user=admin ansible_ssh_private_key_file=/home/example/.ssh/id_ed25519"
  assert_eq "build_inventory_host_line formats correctly" "${expected}" "$(build_inventory_host_line)"
}

test_extract_bundle_detects_version_mismatch() {
  local tmp_dir bundle_dir_name
  tmp_dir="$(mktemp -d)"
  bundle_dir_name="ansible-automation-platform-containerized-setup-bundle-2.7-4-x86_64"

  mkdir -p "${tmp_dir}/downloads/${bundle_dir_name}"
  echo "fake inventory" > "${tmp_dir}/downloads/${bundle_dir_name}/inventory-growth"
  (cd "${tmp_dir}/downloads" && tar -czf "ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64.tar.gz" "${bundle_dir_name}")
  rm -rf "${tmp_dir}/downloads/${bundle_dir_name}"

  DOWNLOAD_DIR="${tmp_dir}/downloads"
  ENV_FILE="${tmp_dir}/env"
  INSTALL_SCOPE="local"
  BUNDLE_FILE="ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64.tar.gz"
  BUNDLE_DIR_NAME="ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64"
  get_controller_user() { echo "testuser"; }

  extract_bundle >/dev/null 2>&1

  assert_eq "extract_bundle detects real bundle dir name" "${bundle_dir_name}" "${BUNDLE_DIR_NAME}"
  assert_eq "extract_bundle updates INVENTORY_FILE" "${tmp_dir}/downloads/${bundle_dir_name}/inventory-growth" "${INVENTORY_FILE}"
  if [[ -f "${INVENTORY_FILE}" ]]; then
    echo "[ OK ] inventory-growth found after extraction"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] inventory-growth not found after extraction"
    fail_count=$((fail_count + 1))
  fi

  rm -rf "${tmp_dir}"
}

test_get_preferred_remote_user_remote_scope() {
  local tmp_env
  tmp_env="$(mktemp)"
  ENV_FILE="${tmp_env}"
  INSTALL_SCOPE="remote"
  AAP_REMOTE_USER=""

  assert_eq "remote scope always uses admin as ansible_user" "admin" "$(get_preferred_remote_user)"

  rm -f "${tmp_env}"
}

test_state_file_is_data_not_code() {
  local tmp_dir marker original_vault_pass_file original_project_key
  tmp_dir="$(mktemp -d)"
  marker="${tmp_dir}/executed"
  original_vault_pass_file="${VAULT_PASS_FILE}"
  original_project_key="${PROJECT_KEY}"
  ENV_FILE="${tmp_dir}/env.yml"
  VAULT_PASS_FILE="${tmp_dir}/.vaultpass.txt"
  PROJECT_KEY="test_project"

  cat > "${ENV_FILE}" <<EOF
${PROJECT_KEY}:
  RHSM_USERNAME: 'legacy-user'
  EVIL: '\$(touch "${marker}")'
EOF

  unset RHSM_USERNAME RHSM_PASSWORD
  load_env
  assert_eq "legacy state remains readable" "legacy-user" "${RHSM_USERNAME}"
  [[ ! -e "${marker}" ]] || { echo "[FAIL] state file executed shell content"; fail_count=$((fail_count + 1)); }

  save_env_kv RHSM_PASSWORD "p@ss word"
  unset RHSM_PASSWORD
  load_env
  assert_eq "state value round-trips" "p@ss word" "${RHSM_PASSWORD}"
  assert_status "state file is vault-encrypted at rest" 0 bash -c "head -c 14 '${ENV_FILE}' | grep -q '^\\\$ANSIBLE_VAULT'"
  assert_status "unknown state key is rejected" 1 save_env_kv PATH bad

  VAULT_PASS_FILE="${original_vault_pass_file}"
  PROJECT_KEY="${original_project_key}"
  rm -rf "${tmp_dir}"
}

test_all_credentials_round_trip_encrypted_state() {
  local test_status=0

  (
    set -euo pipefail
    local tmp_dir plaintext_file key value
    local -a credential_keys
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"' EXIT
    ENV_FILE="${tmp_dir}/env.yml"
    plaintext_file="${tmp_dir}/env.plain.yml"
    VAULT_PASS_FILE="${tmp_dir}/.vaultpass.txt"
    PROJECT_KEY="credential_test"
    CONTROLLER_STATE_HOME="${tmp_dir}"
    credential_keys=()

    for key in "${AAP27_STATE_KEYS[@]}"; do
      if [[ "${key}" =~ (USERNAME|PASSWORD|TOKEN|ACTIVATION_KEY)$ ]]; then
        credential_keys+=("${key}")
      fi
    done

    for key in "${credential_keys[@]}"; do
      value="value for ${key} with spaces !@#%+='quote"
      printf '%s\t%s\n' "${key}" "${value}"
    done | jq -Rn --arg project "${PROJECT_KEY^^}" '
      [inputs | split("\t") | {key: .[0], value: .[1]}]
      | reduce .[] as $item ({}; .[$item.key] = $item.value)
      | {($project): .}
    ' > "${plaintext_file}"

    printf '%s\n' 'credential-test-vault-password' > "${VAULT_PASS_FILE}"
    chmod 600 "${VAULT_PASS_FILE}"
    ansible-vault encrypt --vault-password-file "${VAULT_PASS_FILE}" \
      --output "${ENV_FILE}" "${plaintext_file}" >/dev/null

    for key in "${credential_keys[@]}"; do
      unset "${key}"
    done
    load_env
    for key in "${credential_keys[@]}"; do
      expected="value for ${key} with spaces !@#%+='quote"
      [[ "${!key:-}" == "${expected}" ]]
    done
    head -c 14 "${ENV_FILE}" | grep -q '^\$ANSIBLE_VAULT'
  ) || test_status=$?

  assert_eq "all usernames, passwords, and tokens round-trip through encrypted state" \
    "0" "${test_status}"
}

test_rhsm_registration_forwards_credentials_exactly() {
  local tmp_dir captured_vars
  tmp_dir="$(mktemp -d)"
  captured_vars="${tmp_dir}/registration-vars.json"

  (
    load_env() { :; }
    run_project_playbook() {
      cp "$2" "${captured_vars}"
    }
    RHSM_USERNAME="user+rhsm@example.test"
    RHSM_PASSWORD="password with spaces !@#%+='quote"
    RHSM_ORG_ID="1234567"
    RHSM_ACTIVATION_KEY="activation key !@#%+='quote"
    register_remote_rhsm_via_ansible "192.0.2.20" "root password !@#%+='quote"
  ) >/dev/null

  assert_eq "registration forwards root SSH password exactly" \
    "root password !@#%+='quote" "$(jq -r '.ansible_password' "${captured_vars}")"
  assert_eq "registration forwards RHSM username exactly" \
    "user+rhsm@example.test" "$(jq -r '.RHSM_USERNAME' "${captured_vars}")"
  assert_eq "registration forwards RHSM password exactly" \
    "password with spaces !@#%+='quote" "$(jq -r '.RHSM_PASSWORD' "${captured_vars}")"
  assert_eq "registration forwards RHSM organization exactly" \
    "1234567" "$(jq -r '.RHSM_ORG_ID' "${captured_vars}")"
  assert_eq "registration forwards RHSM activation key exactly" \
    "activation key !@#%+='quote" "$(jq -r '.RHSM_ACTIVATION_KEY' "${captured_vars}")"

  rm -rf "${tmp_dir}"
}

test_offline_token_exchange_and_fallback() {
  local tmp_dir output exchange_body download_body remote_download_playbook
  tmp_dir="$(mktemp -d)"
  TOKEN_TEST_REQUEST="${tmp_dir}/request"
  TOKEN_TEST_ARGS="${tmp_dir}/args"
  export TOKEN_TEST_REQUEST TOKEN_TEST_ARGS

  (
    curl() {
      printf '%s\n' "$*" > "${TOKEN_TEST_ARGS}"
      cat > "${TOKEN_TEST_REQUEST}"
      printf '%s\n' '{"access_token":"temporary-access-token","expires_in":900}'
    }
    exchange_red_hat_offline_token "offline token with spaces !@#%+='quote"
    assert_eq "offline token exchange returns access token" \
      "temporary-access-token" "${RED_HAT_ACCESS_TOKEN}"
  )
  assert_eq "offline token is sent in request body exactly" \
    "offline token with spaces !@#%+='quote" "$(cat "${TOKEN_TEST_REQUEST}")"
  assert_eq "offline token is absent from curl process arguments" "false" \
    "$([[ "$(cat "${TOKEN_TEST_ARGS}")" == *"offline token with spaces"* ]] && echo true || echo false)"

  (
    curl() {
      cat >/dev/null
      printf '%s\n' '{"error":"invalid_grant"}'
    }
    assert_status "invalid offline token is rejected" 1 \
      exchange_red_hat_offline_token "invalid-token"
  )

  output="$({
    NONINTERACTIVE=true
    unset RH_OFFLINE_TOKEN RED_HAT_ACCESS_TOKEN
    ensure_red_hat_access_token
    printf 'access-token=%s\n' "${RED_HAT_ACCESS_TOKEN:-}"
  } 2>&1)"
  assert_contains "unattended mode falls back to RHSM credentials" \
    "continuing with RHSM username/password authentication" "${output}"
  assert_contains "unattended fallback leaves access token empty" \
    "access-token=" "${output}"

  exchange_body="$(declare -f exchange_red_hat_offline_token)"
  download_body="$(declare -f download_bundle)"
  remote_download_playbook="${SCRIPT_DIR}/aap_workflow_project/playbooks/download_bundle.yml"
  assert_contains "offline token flow uses Red Hat SSO endpoint" \
    'RED_HAT_SSO_TOKEN_URL' "${exchange_body}"
  assert_contains "offline token flow uses rhsm-api client" \
    'client_id=rhsm-api' "${exchange_body}"
  assert_contains "interactive recovery opens Red Hat API token page" \
    'xdg-open "${RED_HAT_API_TOKEN_URL}"' "$(declare -f ensure_red_hat_access_token)"
  assert_contains "local download uses temporary access token" \
    'Authorization: Bearer ${RED_HAT_ACCESS_TOKEN}' "${download_body}"
  assert_eq "local download never uses offline token directly as bearer" "false" \
    "$([[ "${download_body}" == *'Authorization: Bearer ${RH_OFFLINE_TOKEN}'* ]] && echo true || echo false)"
  assert_status "remote download supports bearer access token" 0 \
    grep -q "Authorization.*Bearer.*effective_red_hat_access_token" "${remote_download_playbook}"
  assert_status "remote extraction tempfile uses supported parent path" 0 \
    bash -c "grep -A5 'name: Create temporary extraction directory' '$remote_download_playbook' | grep -q 'path:.*admin_download_dir'"
  assert_status "remote extraction tempfile does not use unsupported dir parameter" 1 \
    bash -c "grep -A5 'name: Create temporary extraction directory' '$remote_download_playbook' | grep -q '^[[:space:]]*dir:'"

  unset TOKEN_TEST_REQUEST TOKEN_TEST_ARGS
  rm -rf "${tmp_dir}"
}

test_legacy_env_file_migrates_to_yaml() {
  local tmp_dir legacy_home original_vault_pass_file original_project_key
  tmp_dir="$(mktemp -d)"
  legacy_home="${tmp_dir}/home"
  mkdir -p "${legacy_home}"
  original_vault_pass_file="${VAULT_PASS_FILE}"
  original_project_key="${PROJECT_KEY}"
  ENV_FILE="${tmp_dir}/.ansible/conf/env.yml"
  VAULT_PASS_FILE="${tmp_dir}/.ansible/conf/.vaultpass.txt"
  PROJECT_KEY="test_project"

  cat > "${legacy_home}/.aap27_install.env" <<'EOF'
RHSM_USERNAME_B64=bGVnYWN5LXVzZXI=
EOF

  (
    HOME="${legacy_home}"
    unset RHSM_USERNAME
    initialize_env_file
    load_env
    assert_eq "legacy flat env file migrates into YAML state" "legacy-user" "${RHSM_USERNAME}"
  )

  VAULT_PASS_FILE="${original_vault_pass_file}"
  PROJECT_KEY="${original_project_key}"
  rm -rf "${tmp_dir}"
}

test_collection_patch_version_gate() {
  local tmp_dir original_bundle_dir original_patch_setting
  tmp_dir="$(mktemp -d)"
  mkdir -p "${tmp_dir}/collections/ansible_collections/ansible/containerized_installer"
  original_bundle_dir="${BUNDLE_DIR_NAME}"
  original_patch_setting="${AAP_APPLY_COLLECTION_PATCHES}"

  AAP_APPLY_COLLECTION_PATCHES=true
  BUNDLE_DIR_NAME="ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64"
  assert_status "validated 2.7-2 patch set is accepted" 0 patch_containerized_installer_user_bus_task "${tmp_dir}"

  BUNDLE_DIR_NAME="ansible-automation-platform-containerized-setup-bundle-2.7-4-x86_64"
  assert_status "unvalidated 2.7-4 patch set is rejected" 1 patch_containerized_installer_user_bus_task "${tmp_dir}"

  AAP_APPLY_COLLECTION_PATCHES=false
  assert_status "disabled patches allow unmodified newer bundle" 0 patch_containerized_installer_user_bus_task "${tmp_dir}"

  BUNDLE_DIR_NAME="${original_bundle_dir}"
  AAP_APPLY_COLLECTION_PATCHES="${original_patch_setting}"
  rm -rf "${tmp_dir}"
}

test_sourcing_preserves_caller_options() {
  # shellcheck disable=SC2016
  assert_status "sourcing does not enable nounset in caller" 0 \
    bash -c 'set +u; source "$1"; [[ $- != *u* ]]' _ "${SCRIPT_DIR}/aap27_installer.sh"
}

test_state_home_ignores_inherited_home() {
  local resolved_env

  resolved_env="$(HOME=/tmp/aap27-wrong-home bash -c 'source "$1"; printf "%s" "$ENV_FILE"' _ "${SCRIPT_DIR}/aap27_installer.sh")"
  assert_eq "installer state ignores inherited temporary HOME" \
    "$(getent passwd "$(id -un)" | cut -d: -f6)/.ansible/conf/env.yml" "${resolved_env}"
}

test_startup_repairs_stale_installer_key() {
  local collector_body
  collector_body="$(declare -f ensure_rhsm_credentials_exist)"

  assert_contains "startup detects a missing configured installer key" \
    '! -f "${AAP_INSTALLER_SSH_KEY}"' "${collector_body}"
  assert_contains "startup repairs installer key below canonical home" \
    '${CONTROLLER_STATE_HOME}/.ssh/id_ed25519' "${collector_body}"
}

test_ansible_runtime_creation_returns_clean_path() {
  local tmp_dir original_script_dir output
  tmp_dir="$(mktemp -d)"
  original_script_dir="${SCRIPT_DIR}"
  mkdir -p "${tmp_dir}/bin"
  touch "${tmp_dir}/requirements-runtime.txt"

  cat > "${tmp_dir}/bin/python3.11" <<'EOF'
#!/usr/bin/env bash
venv_dir="$3"
mkdir -p "${venv_dir}/bin"
cat > "${venv_dir}/bin/python" <<'PYTHON'
#!/usr/bin/env bash
echo "simulated pip output"
PYTHON
cat > "${venv_dir}/bin/ansible-playbook" <<'ANSIBLE'
#!/usr/bin/env bash
echo "ansible-playbook [core 2.16.0]"
ANSIBLE
chmod +x "${venv_dir}/bin/python" "${venv_dir}/bin/ansible-playbook"
echo "simulated venv output"
EOF
  chmod +x "${tmp_dir}/bin/python3.11"

  SCRIPT_DIR="${tmp_dir}"
  output="$(PATH="${tmp_dir}/bin" AAP_AUTO_CREATE_ANSIBLE_VENV=true get_supported_ansible_playbook 2>/dev/null)"
  assert_eq "runtime creation returns only ansible-playbook path" \
    "${tmp_dir}/.venv-aap27-runtime/bin/ansible-playbook" "${output}"

  SCRIPT_DIR="${original_script_dir}"
  rm -rf "${tmp_dir}"
}

test_remote_inventory_uses_saved_fqdn_alias() {
  local tmp_dir original_script_dir original_env_file
  tmp_dir="$(mktemp -d)"
  original_script_dir="${SCRIPT_DIR}"
  original_env_file="${ENV_FILE}"

  SCRIPT_DIR="${tmp_dir}"
  ENV_FILE="${tmp_dir}/state"
  mkdir -p "${tmp_dir}/aap_workflow_project/inventory"
  NONINTERACTIVE=true
  INSTALL_SCOPE=remote
  AAP_CONTROLLER_IP="192.0.2.15"
  AAP_SHORTNAME="aap"
  AAP_DOMAIN_NAME="example.test"
  AAP_CONTROLLER_FQDN="${AAP_SHORTNAME}.${AAP_DOMAIN_NAME}"

  initial_install_scope_prompt >/dev/null

  assert_status "generated controller inventory uses saved FQDN alias" 0 \
    grep -q '^aap\.example\.test ansible_host=192\.0\.2\.15 ' \
    "${tmp_dir}/aap_workflow_project/inventory/controller.ini"

  SCRIPT_DIR="${original_script_dir}"
  ENV_FILE="${original_env_file}"
  rm -rf "${tmp_dir}"
}

test_explicit_target_reconfiguration_prompts() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  mkdir -p "${tmp_dir}/aap_workflow_project/inventory"

  (
    SCRIPT_DIR="${tmp_dir}"
    ENV_FILE="${tmp_dir}/state"
    NONINTERACTIVE=true
    INSTALL_SCOPE=remote
    AAP_CONTROLLER_IP="192.0.2.15"
    AAP_CONTROLLER_FQDN="old.example.test"
    initial_install_scope_prompt true <<< $'2\n192.0.2.25\nnew-aap\nprod.example\n' >/dev/null
  )

  assert_status "explicit target reconfiguration updates target IP" 0 \
    grep -q 'ansible_host=192\.0\.2\.25 ' "${tmp_dir}/aap_workflow_project/inventory/controller.ini"
  assert_status "explicit target reconfiguration updates hostname and domain" 0 \
    grep -q '^new-aap\.prod\.example ansible_host=' "${tmp_dir}/aap_workflow_project/inventory/controller.ini"

  rm -rf "${tmp_dir}"
}

test_configurable_admin_identity() {
  local tmp_env original_admin_user original_admin_home original_env_file
  tmp_env="$(mktemp)"
  original_admin_user="${ADMIN_USER}"
  original_admin_home="${ADMIN_HOME}"
  original_env_file="${ENV_FILE}"

  ENV_FILE="${tmp_env}"
  INSTALL_SCOPE=remote
  ADMIN_USER=platformops
  ADMIN_HOME=/srv/platformops
  AAP_REMOTE_USER=""

  assert_eq "remote scope honors configured admin user" "platformops" "$(get_preferred_remote_user)"
  assert_status "valid configured admin identity is accepted" 0 validate_admin_identity

  ADMIN_USER='invalid/user'
  assert_status "invalid configured admin identity is rejected" 1 validate_admin_identity

  ADMIN_USER="${original_admin_user}"
  ADMIN_HOME="${original_admin_home}"
  ENV_FILE="${original_env_file}"
  rm -f "${tmp_env}"
}

test_rootless_playbook_wrapper_hides_secrets() {
  local tmp_dir original_script_dir original_path original_ansible_playbook
  tmp_dir="$(mktemp -d)"
  original_script_dir="${SCRIPT_DIR}"
  original_path="${PATH}"
  original_ansible_playbook="${AAP_ANSIBLE_PLAYBOOK:-}"

  mkdir -p "${tmp_dir}/bin" "${tmp_dir}/aap_workflow_project/inventory" "${tmp_dir}/aap_workflow_project/playbooks"
  touch "${tmp_dir}/aap_workflow_project/inventory/controller.ini"
  touch "${tmp_dir}/aap_workflow_project/playbooks/fix_podman_user_bus.yml"
  touch "${tmp_dir}/aap_workflow_project/ansible.cfg"

  cat > "${tmp_dir}/bin/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${CAPTURE_ARGS}"
for argument in "$@"; do
  if [[ "${argument}" == @* ]]; then
    stat -c '%a' "${argument#@}" > "${CAPTURE_MODE}"
    cp "${argument#@}" "${CAPTURE_VARS}"
  fi
done
EOF
  chmod +x "${tmp_dir}/bin/ansible-playbook"

  export CAPTURE_ARGS="${tmp_dir}/args" CAPTURE_MODE="${tmp_dir}/mode" CAPTURE_VARS="${tmp_dir}/vars"
  SCRIPT_DIR="${tmp_dir}"
  PATH="${tmp_dir}/bin:${PATH}"
  AAP_ANSIBLE_PLAYBOOK="${tmp_dir}/bin/ansible-playbook"

  run_rootless_podman_playbook platformops true registry-user 'test password' >/dev/null

  assert_status "rootless wrapper keeps password out of argv" 1 grep -q 'test password' "${CAPTURE_ARGS}"
  assert_eq "rootless wrapper uses mode-0600 vars" "600" "$(cat "${CAPTURE_MODE}")"
  assert_eq "rootless wrapper forwards deployment user" "platformops" "$(jq -r .AAP_REMOTE_USER "${CAPTURE_VARS}")"
  assert_eq "rootless wrapper forwards registry login flag" "true" "$(jq -r .REGISTRY_LOGIN "${CAPTURE_VARS}")"

  SCRIPT_DIR="${original_script_dir}"
  PATH="${original_path}"
  AAP_ANSIBLE_PLAYBOOK="${original_ansible_playbook}"
  unset CAPTURE_ARGS CAPTURE_MODE CAPTURE_VARS
  rm -rf "${tmp_dir}"
}

test_2_7_4_tls_hotfix_is_idempotent() {
  local tmp_dir original_bundle_dir tls_file modern_checksum
  tmp_dir="$(mktemp -d)"
  original_bundle_dir="${BUNDLE_DIR_NAME}"
  tls_file="${tmp_dir}/collections/ansible_collections/ansible/containerized_installer/roles/common/tasks/tls.yml"
  mkdir -p "$(dirname "${tls_file}")"
  cat > "${tls_file}" <<'EOF'
    - name: Copy TLS CA files to other nodes
      block:
        - name: Create local temporary directory
          ansible.builtin.tempfile:
            state: directory
          register: _ca_temp
          delegate_to: localhost
      always:
        - name: Remove local temporary directory
          ansible.builtin.file:
            path: '{{ _ca_temp.path }}'
            state: absent
          delegate_to: localhost
EOF

  BUNDLE_DIR_NAME="ansible-automation-platform-containerized-setup-bundle-2.7-4-x86_64"
  apply_bundle_specific_hotfixes "${tmp_dir}" >/dev/null
  apply_bundle_specific_hotfixes "${tmp_dir}" >/dev/null

  assert_eq "2.7-4 TLS hotfix adds create become once" "1" \
    "$(grep -A1 -F -- '- name: Create local temporary directory' "${tls_file}" | grep -c 'become: false')"
  assert_eq "2.7-4 TLS hotfix adds cleanup become once" "1" \
    "$(grep -A1 -F -- '- name: Remove local temporary directory' "${tls_file}" | grep -c 'become: false')"
  assert_eq "2.7-4 TLS hotfix adds secure local ownership once" "1" \
    "$(grep -cF -- '- name: Ensure local temporary directory ownership' "${tls_file}")"
  assert_eq "2.7-4 TLS hotfix keeps local temp mode private" "1" \
    "$(grep -A8 -F -- '- name: Ensure local temporary directory ownership' "${tls_file}" | grep -c "mode: '0700'")"

  cat > "${tls_file}" <<'EOF'
    - name: Copy TLS CA files to other nodes
      block:
        - name: Create local temporary directory
          become: false
          ansible.builtin.tempfile:
            state: directory
          register: common_ca_temp
          delegate_to: localhost

        - name: Ensure local temporary directory is writable
          ansible.builtin.file:
            path: "{{ common_ca_temp.path }}"
            state: directory
            mode: "0777"
          delegate_to: localhost
      always:
        - name: Remove local temporary directory
          become: false
          ansible.builtin.file:
            path: "{{ common_ca_temp.path }}"
            state: absent
          delegate_to: localhost
EOF
  modern_checksum="$(sha256sum "${tls_file}" | awk '{print $1}')"
  assert_status "2.7-4 TLS hotfix accepts modern common_ca_temp structure" 0 \
    apply_bundle_specific_hotfixes "${tmp_dir}"
  assert_eq "2.7-4 TLS hotfix leaves modern structure unchanged" "${modern_checksum}" \
    "$(sha256sum "${tls_file}" | awk '{print $1}')"

  BUNDLE_DIR_NAME="${original_bundle_dir}"
  rm -rf "${tmp_dir}"
}

test_2_7_4_rootless_env_hotfix_preserves_yaml() {
  local hotfix_main hotfix_tasks hotfix_block
  hotfix_main="${SCRIPT_DIR}/roles/aap27_bundle_hotfixes/tasks/main.yml"
  hotfix_tasks="${SCRIPT_DIR}/roles/aap27_bundle_hotfixes/tasks/rootless_podman_env.yml"
  hotfix_block="$(cat "${hotfix_tasks}")"

  assert_status "rootless env hotfix uses focused task owner" 0 \
    grep -qF 'ansible.builtin.include_tasks: rootless_podman_env.yml' "${hotfix_main}"

  assert_contains "rootless env hotfix preserves replacement trailing newline" \
    "replace: |" "${hotfix_block}"
  assert_eq "rootless env hotfix does not strip replacement trailing newline" "false" \
    "$([[ "${hotfix_block}" == *"replace: |-"* ]] && echo true || echo false)"
  assert_contains "rootless env hotfix normalizes the complete export sequence" \
    "Normalize rootless Podman environment exports" "${hotfix_block}"
  assert_contains "rootless env hotfix captures existing YAML indentation" \
    "^([ \\t]*)export TMPDIR" "${hotfix_block}"
  assert_contains "rootless env hotfix restores TMPDIR indentation" \
    '\1export TMPDIR=' "${hotfix_block}"
  assert_contains "rootless env hotfix restores XDG_RUNTIME_DIR indentation" \
    '\1export XDG_RUNTIME_DIR=' "${hotfix_block}"
  assert_contains "rootless env hotfix restores HOME indentation" \
    '\1export HOME=' "${hotfix_block}"
  assert_contains "rootless env hotfix restores storage export indentation" \
    '\1\2' "${hotfix_block}"
}

test_2_7_4_controller_tls_key_hotfix_is_scoped() {
  local hotfix_main hotfix_block
  hotfix_main="${SCRIPT_DIR}/roles/aap27_bundle_hotfixes/tasks/main.yml"
  hotfix_block="$(sed -n \
    '/name: Apply AAP 2.7-4 automationcontroller TLS key permission hotfix/,/name: Apply AAP 2.7-4 internal CA trust-bundle hotfix/p' \
    "${hotfix_main}")"

  assert_contains "controller TLS hotfix targets the controller TLS tasks" \
    "/roles/automationcontroller/tasks/tls.yml" "${hotfix_block}"
  assert_contains "controller TLS hotfix matches only tower.key" \
    "controller_conf_dir" "${hotfix_block}"
  assert_contains "controller TLS hotfix changes private key mode for container access" \
    "replace: \"\\\\g<1>'0444'\"" "${hotfix_block}"
}

test_2_7_4_gateway_api_hotfix_retries_transient_timeouts() {
  local hotfix_tasks hotfix_block
  hotfix_tasks="${SCRIPT_DIR}/roles/aap27_bundle_hotfixes/tasks/main.yml"
  hotfix_block="$(sed -n \
    '/name: Apply AAP 2.7-4 gateway API convergence hotfix/,/name: Apply AAP 2.7-4 automationeda systemd service-list hotfix/p' \
    "${hotfix_tasks}")"

  assert_contains "gateway API hotfix increases request timeout" \
    "gateway_request_timeout: 60" "${hotfix_block}"
  assert_contains "gateway API hotfix retries service-cluster registration" \
    "retries: 5" "${hotfix_block}"
  assert_contains "gateway API hotfix bounds retry delay" \
    "delay: 10" "${hotfix_block}"
  assert_contains "gateway API hotfix still fails persistent errors" \
    "until: gateway_service_cluster_result is succeeded" "${hotfix_block}"
}

test_nested_installer_validates_patched_yaml_first() {
  local install_playbook validation_block validation_line execution_line
  install_playbook="${SCRIPT_DIR}/aap_workflow_project/playbooks/install_aap.yml"
  validation_block="$(sed -n \
    '/name: Validate patched AAP containerized playbook syntax/,/name: Run selected AAP containerized playbook/p' \
    "${install_playbook}")"
  validation_line="$(grep -nF 'name: Validate patched AAP containerized playbook syntax' "${install_playbook}" | cut -d: -f1)"
  execution_line="$(grep -nF 'name: Run selected AAP containerized playbook' "${install_playbook}" | cut -d: -f1)"

  assert_status "nested installer includes patched YAML syntax validation" 0 \
    grep -qF "'--syntax-check'" "${install_playbook}"
  assert_status "explicit bundle path does not require bundle directory name" 0 \
    grep -qF "BUNDLE_DIR_NAME | default('ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64')" \
      "${install_playbook}"
  assert_contains "nested syntax validation disables bundle-local logging" \
    "ANSIBLE_LOG_PATH: /dev/null" "${validation_block}"
  assert_status "nested execution suppresses buffered duplicate output" 0 \
    grep -A30 -F 'name: Run selected AAP containerized playbook' "${install_playbook}" | grep -q 'no_log: true'
  assert_status "nested execution does not retain its complete stdout" 1 \
    grep -A30 -F 'name: Run selected AAP containerized playbook' "${install_playbook}" | grep -q 'register: install_result'
  assert_eq "nested installer validates before execution" "true" \
    "$([[ -n "${validation_line}" && -n "${execution_line}" && ${validation_line} -lt ${execution_line} ]] && echo true || echo false)"
}

test_remote_installer_streams_nested_playbook_log() {
  local execution_body follower_line playbook_line cleanup_line
  execution_body="$(declare -f run_execution_playbook)"
  follower_line="$(grep -nF "exec tail -n +1 -F /tmp/aap_install.log" <<< "${execution_body}" | cut -d: -f1)"
  playbook_line="$(grep -nF 'aap_workflow_project/playbooks/install_aap.yml' <<< "${execution_body}" | cut -d: -f1)"
  cleanup_line="$(grep -nF 'kill "${remote_log_pid}"' <<< "${execution_body}" | cut -d: -f1)"

  assert_contains "remote installer follows the nested AAP log" \
    "tail -n +1 -F /tmp/aap_install.log" "${execution_body}"
  assert_contains "remote installer preserves the outer playbook status" \
    '|| playbook_rc=$?' "${execution_body}"
  assert_eq "remote log follower wraps nested playbook execution" "1" \
    "$(( follower_line < playbook_line && playbook_line < cleanup_line ))"
}

test_remote_scope_routes_target_operations() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  ENV_FILE="${tmp_dir}/state"
  INSTALL_SCOPE=remote
  TARGET_FQDN=aap.example.test
  ADMIN_USER=platformops
  ADMIN_HOME=/srv/platformops

  load_env() { :; }
  resolve_target_context() {
    TARGET_SCOPE=remote
    TARGET_DESC=platformops@192.0.2.15
  }
  run_remote_prework() { printf '%s %s' "$1" "$2" > "${tmp_dir}/prework"; }
  run_remote_host_identity() { printf '%s' "${TARGET_FQDN}" > "${tmp_dir}/identity"; }

  prework_packages >/dev/null
  set_fqdn_and_hosts >/dev/null

  assert_eq "remote prework disables security mutations by default" "false false" "$(cat "${tmp_dir}/prework")"
  assert_eq "remote identity uses selected target FQDN" "aap.example.test" "$(cat "${tmp_dir}/identity")"
  assert_status "prework playbook is controller-only" 0 \
    grep -q '^  hosts: controller$' "${SCRIPT_DIR}/aap_workflow_project/playbooks/prework.yml"
  assert_status "identity playbook is controller-only" 0 \
    grep -q '^  hosts: controller$' "${SCRIPT_DIR}/aap_workflow_project/playbooks/host_identity.yml"

  rm -rf "${tmp_dir}"
}

test_complete_install_pipeline_order() {
  local tmp_dir pipeline_status
  tmp_dir="$(mktemp -d)"
  SCOPE_CALLS_FILE="${tmp_dir}/calls"
  export SCOPE_CALLS_FILE

  (
    configure_install_scope() { printf '%s\n' scope >> "${SCOPE_CALLS_FILE}"; INSTALL_SCOPE=remote; }
    get_install_scope() { printf '%s' remote; }
    get_install_target_host() { printf '%s' 192.0.2.15; }
    setup_admin_user() { printf '%s\n' admin >> "${SCOPE_CALLS_FILE}"; }
    run_preflight_resource_checks() { printf '%s\n' preflight >> "${SCOPE_CALLS_FILE}"; }
    prepare_install_target() { printf '%s\n' security-prework >> "${SCOPE_CALLS_FILE}"; }
    set_fqdn_and_hosts() { printf '%s\n' identity >> "${SCOPE_CALLS_FILE}"; }
    capture_credentials() { printf '%s\n' credentials >> "${SCOPE_CALLS_FILE}"; }
    download_bundle() { printf '%s\n' download >> "${SCOPE_CALLS_FILE}"; }
    extract_bundle() { printf '%s\n' extract >> "${SCOPE_CALLS_FILE}"; }
    modify_inventory_growth() { printf '%s\n' inventory >> "${SCOPE_CALLS_FILE}"; }
    run_execution_playbook() { printf 'execute:%s\n' "$1" >> "${SCOPE_CALLS_FILE}"; }
    run_complete_install_pipeline >/dev/null
  )

  assert_eq "full install pipeline follows required order" \
    $'scope\nadmin\npreflight\nsecurity-prework\nidentity\ncredentials\ndownload\nextract\ninventory\nexecute:install' \
    "$(cat "${SCOPE_CALLS_FILE}")"

  : > "${SCOPE_CALLS_FILE}"
  pipeline_status=0
  (
    configure_install_scope() { printf '%s\n' scope >> "${SCOPE_CALLS_FILE}"; INSTALL_SCOPE=remote; }
    get_install_scope() { printf '%s' remote; }
    get_install_target_host() { printf '%s' 192.0.2.15; }
    setup_admin_user() { printf '%s\n' admin-failed >> "${SCOPE_CALLS_FILE}"; return 1; }
    run_complete_install_pipeline
  ) >/dev/null 2>&1 || pipeline_status=$?
  assert_eq "full install pipeline fails fast" "1" "${pipeline_status}"
  assert_eq "full install stops after failed bootstrap" $'scope\nadmin-failed' \
    "$(cat "${SCOPE_CALLS_FILE}")"

  unset SCOPE_CALLS_FILE
  rm -rf "${tmp_dir}"
}

test_remote_install_prework_relaxes_security() {
  local output

  output="$({
    load_env() { :; }
    resolve_target_context() { TARGET_SCOPE=remote; }
    run_remote_prework() { printf '%s %s' "$1" "$2"; }
    prepare_install_target
  })"

  assert_eq "remote full install applies package and security prework together" \
    "true true" "${output}"
}

test_remote_setup_runs_repository_bootstrap() {
  local output

  output="$({
    load_env() { :; }
    get_install_scope() { printf '%s' remote; }
    provision_remote_admin_via_ssh() { printf '%s' provisioned; }
    setup_admin_user
  })"

  assert_eq "remote admin setup runs repository and package bootstrap" \
    "provisioned" "${output}"
}

test_remote_root_bootstrap_contract() {
  local bootstrap_body registration_body registration_playbook
  local rhc_line activation_line password_line repos_line install_line ssh_config_line restart_line marker_line
  bootstrap_body="$(declare -f provision_remote_admin_via_ssh)"
  registration_body="$(declare -f register_remote_rhsm_via_ansible)"
  registration_playbook="${SCRIPT_DIR}/aap_workflow_project/playbooks/register_rhsm.yml"

  assert_contains "remote bootstrap readiness requires completion marker" \
    "/var/lib/aap27-bootstrap-complete" "${bootstrap_body}"
  assert_contains "remote bootstrap readiness requires podman" \
    "command -v podman" "${bootstrap_body}"
  assert_contains "remote bootstrap readiness miss starts preparation without warning" \
    'log "Bootstrap readiness not yet confirmed' "${bootstrap_body}"
  assert_contains "remote bootstrap collects RHSM credentials" \
    "ensure_registry_credentials" "${bootstrap_body}"
  assert_contains "remote bootstrap registers RHEL through Ansible" \
    "register_remote_rhsm_via_ansible" "${bootstrap_body}"
  assert_contains "RHSM registration runs the dedicated Ansible playbook" \
    "register_rhsm.yml" "${registration_body}"
  assert_contains "RHSM registration uses a protected variable file" \
    'chmod 600 "${inventory_file}" "${extra_vars_file}"' "${registration_body}"
  assert_eq "RHSM registration does not invoke SSH directly" "false" \
    "$([[ "${registration_body}" == *' ssh '* || "${registration_body}" == *'sshpass'* ]] && echo true || echo false)"
  assert_contains "RHSM registration detects rejected credentials" \
    "AAP27_RHSM_CREDENTIALS_REJECTED" "${registration_body}"
  assert_status "RHSM playbook keeps activation result separate" 0 \
    grep -q "register: rhsm_activation_registration" \
    "${SCRIPT_DIR}/aap_workflow_project/playbooks/register_rhsm.yml"
  assert_status "RHSM playbook keeps password result separate" 0 \
    grep -q "register: rhsm_password_registration" \
    "${registration_playbook}"
  assert_status "RHSM playbook attempts Red Hat Connector" 0 \
    grep -q -- '- rhc' "${registration_playbook}"
  assert_status "RHSM password fallback is independent of activation-key presence" 1 \
    bash -c "grep -A20 'name: Register with RHSM username and password' '$registration_playbook' | grep -q 'RHSM_ACTIVATION_KEY.*length == 0'"
  rhc_line="$(grep -n 'name: Register with Red Hat Connector' "${registration_playbook}" | cut -d: -f1)"
  activation_line="$(grep -n 'name: Register with RHSM activation key' "${registration_playbook}" | cut -d: -f1)"
  password_line="$(grep -n 'name: Register with RHSM username and password' "${registration_playbook}" | cut -d: -f1)"
  assert_eq "RHSM registration tries rhc before activation key" "1" \
    "$(( rhc_line < activation_line ))"
  assert_eq "RHSM registration tries activation key before password fallback" "1" \
    "$(( activation_line < password_line ))"
  assert_eq "RHSM registration does not prompt during execution" "false" \
    "$([[ "${registration_body}" == *"read -r"* || "${registration_body}" == *"ask_value"* || "${registration_body}" == *"read_secret_prompt"* ]] && echo true || echo false)"
  assert_contains "RHSM registration clears rejected activation key" \
    'save_env_kv "RHSM_ACTIVATION_KEY" ""' "${registration_body}"
  assert_contains "RHSM registration clears rejected username" \
    'save_env_kv "RHSM_USERNAME" ""' "${registration_body}"
  assert_contains "RHSM registration clears rejected password" \
    'save_env_kv "RHSM_PASSWORD" ""' "${registration_body}"
  # shellcheck disable=SC2016
  assert_contains "remote bootstrap enables BaseOS and AppStream" \
    'subscription-manager repos --enable "\${BASEOS_REPO}" --enable "\${APPSTREAM_REPO}"' "${bootstrap_body}"
  assert_contains "remote bootstrap installs required packages" \
    "rsync podman podman-docker python3 python3-pip" "${bootstrap_body}"
  # shellcheck disable=SC2016
  assert_contains "remote bootstrap uses sshpass root connection" \
    'sshpass -p "${root_password}"' "${bootstrap_body}"
  assert_contains "remote bootstrap defaults root password to redhat" \
    'true "redhat" || return 1' "${bootstrap_body}"
  assert_contains "remote bootstrap configures strict host-key checking off" \
    "StrictHostKeyChecking no" "${bootstrap_body}"
  assert_contains "remote bootstrap configures null known-hosts file" \
    "UserKnownHostsFile /dev/null" "${bootstrap_body}"
  assert_contains "remote bootstrap restarts sshd" \
    "systemctl restart sshd" "${bootstrap_body}"

  repos_line="$(grep -n 'subscription-manager repos --enable' <<< "${bootstrap_body}" | head -n1 | cut -d: -f1)"
  install_line="$(grep -n 'dnf -y install' <<< "${bootstrap_body}" | head -n1 | cut -d: -f1)"
  ssh_config_line="$(grep -n 'cat > /etc/ssh/ssh_config.d/90-aap27' <<< "${bootstrap_body}" | head -n1 | cut -d: -f1)"
  restart_line="$(grep -n 'systemctl restart sshd' <<< "${bootstrap_body}" | head -n1 | cut -d: -f1)"
  marker_line="$(grep -n 'install -o root -g root -m 0600' <<< "${bootstrap_body}" | head -n1 | cut -d: -f1)"
  assert_eq "remote bootstrap orders repositories before packages" "1" \
    "$(( repos_line < install_line ))"
  assert_eq "remote bootstrap writes SSH policy after package setup" "1" \
    "$(( install_line < ssh_config_line ))"
  assert_eq "remote bootstrap restarts sshd after SSH policy" "1" \
    "$(( ssh_config_line < restart_line ))"
  assert_eq "remote bootstrap writes marker after package setup" "1" \
    "$(( restart_line < marker_line ))"
}

test_inventory_growth_contract() {
  local tasks_file prepare_playbook install_playbook prework_playbook
  tasks_file="${SCRIPT_DIR}/roles/aap27_inventory_growth/tasks/main.yml"
  prepare_playbook="${SCRIPT_DIR}/aap_workflow_project/playbooks/prepare_inventory_growth.yml"
  install_playbook="${SCRIPT_DIR}/aap_workflow_project/playbooks/install_aap.yml"
  prework_playbook="${SCRIPT_DIR}/aap_workflow_project/playbooks/prework.yml"

  assert_status "inventory role requires target address" 0 \
    grep -q 'aap27_inventory_growth_target_address | length > 0' "${tasks_file}"
  assert_status "inventory role writes exact FQDN and ansible_host line" 0 \
    grep -q 'aap27_inventory_growth_target_fqdn }} ansible_host={{ aap27_inventory_growth_target_address' "${tasks_file}"
  assert_status "inventory role forces admin Ansible user" 0 \
    grep -q "ansible_user='admin'" "${tasks_file}"
  assert_status "inventory role removes stale registry and identity keys" 0 \
    grep -q 'registry_username|registry_password|ansible_user' "${tasks_file}"
  assert_status "inventory playbook maps uppercase RHSM username" 0 \
    grep -q 'aap27_inventory_growth_registry_username: "{{ RHSM_USERNAME }}"' "${prepare_playbook}"
  assert_status "inventory playbook maps uppercase RHSM password" 0 \
    grep -q 'aap27_inventory_growth_registry_password: "{{ RHSM_PASSWORD }}"' "${prepare_playbook}"
  assert_status "install workflow forwards target address" 0 \
    grep -q 'aap27_inventory_growth_target_address: "{{ target_address }}"' "${install_playbook}"
  assert_status "prework installs SSH no-host-key policy" 0 \
    grep -q '/etc/ssh/ssh_config.d/90-aap27-no-host-key-checking.conf' "${prework_playbook}"
  assert_status "prework notifies sshd restart" 0 \
    grep -q 'notify: Restart SSH service' "${prework_playbook}"
}

test_resource_shortfall_warning_and_pause() {
  local tmp_dir output
  tmp_dir="$(mktemp -d)"

  output="$({
    load_env() { :; }
    resolve_target_context() { TARGET_SCOPE=local; TARGET_DESC="local host"; }
    nproc() { printf '2\n'; }
    awk() {
      if [[ "${*: -1}" == "/proc/meminfo" ]]; then
        printf '8388608\n'
      else
        command awk "$@"
      fi
    }
    df() {
      printf 'Filesystem 1G-blocks Used Available Use%% Mounted on\n'
      printf '/dev/test 100G 80G 20G 80%% /\n'
    }
    pause_enter() { printf 'paused\n' >> "${tmp_dir}/pauses"; }

    INSTALL_SCOPE=local
    AAP_MIN_CPU=4
    AAP_MIN_RAM_GB=16
    AAP_MIN_DISK_GB=40
    preflight_resource_checks
  })"

  assert_contains "resource shortfall warns installation may not work" \
    "This installation may not work because one or more system resources are insufficient" "${output}"
  assert_contains "resource warning lists CPU shortfall" "CPU: 2 vCPU(s) available; 4 required" "${output}"
  assert_contains "resource warning lists RAM shortfall" "RAM: 8 GB available; 16 GB required" "${output}"
  assert_contains "resource warning lists storage shortfall" "Storage: 20 GB free on /; 40 GB required" "${output}"
  assert_eq "resource shortfall pauses once" "1" "$(wc -l < "${tmp_dir}/pauses")"

  rm -f "${tmp_dir}/pauses"
  {
    load_env() { :; }
    resolve_target_context() { TARGET_SCOPE=local; TARGET_DESC="local host"; }
    nproc() { printf '2\n'; }
    awk() {
      if [[ "${*: -1}" == "/proc/meminfo" ]]; then
        printf '8388608\n'
      else
        command awk "$@"
      fi
    }
    df() {
      printf 'Filesystem 1G-blocks Used Available Use%% Mounted on\n'
      printf '/dev/test 100G 80G 20G 80%% /\n'
    }
    pause_enter() { printf 'paused\n' >> "${tmp_dir}/pauses"; }

    INSTALL_SCOPE=local
    AAP_MIN_CPU=2
    AAP_MIN_RAM_GB=8
    AAP_MIN_DISK_GB=20
    preflight_resource_checks
  } >/dev/null
  assert_eq "sufficient resources do not pause" "false" "$(test -e "${tmp_dir}/pauses" && echo true || echo false)"

  rm -rf "${tmp_dir}"
}

test_env_schema_defines_supported_variables() {
  local schema_file key missing_keys lowercase_keys loader_keys schema_keys
  local -a required_keys
  schema_file="${SCRIPT_DIR}/templates/env.yml.example"
  missing_keys=""
  required_keys=(
    INSTALL_SCOPE NONINTERACTIVE ADMIN_USER ADMIN_HOME ADMIN_PASSWORD
    AAP_REMOTE_USER AAP_REMOTE_ROOT_PASSWORD AAP_CONTROLLER_IP
    AAP_CONTROLLER_FQDN AAP_CONTROLLER_USER AAP_CONTROLLER_SSH_KEY
    ANSIBLE_VERBOSITY BUNDLE_URL BUNDLE_FILE BUNDLE_DIR_NAME
    AAP_EXECUTION_PLAYBOOK AAP_ANSIBLE_PLAYBOOK AAP_AUTO_CREATE_ANSIBLE_VENV
    AAP_APPLY_COLLECTION_PATCHES AAP_CLEANUP_BUNDLE_ARCHIVE
    AAP_CLEANUP_PURGE_DOWNLOADS AAP_AUTO_CLEANUP_ON_UNINSTALL
    AAP_MIN_CPU AAP_MIN_RAM_GB AAP_MIN_DISK_GB RHSM_USERNAME RHSM_PASSWORD
    RH_OFFLINE_TOKEN RH_AH_TOKEN CDN_USERNAME CDN_PASSWORD REDHAT_USERNAME
    REDHAT_PASSWORD CONSOLE_USERNAME CONSOLE_PASSWORD POSTGRESQL_ADMIN_PASSWORD
    CONTROLLER_ADMIN_PASSWORD CONTROLLER_PG_PASSWORD GATEWAY_ADMIN_PASSWORD
    GATEWAY_PG_PASSWORD HUB_ADMIN_PASSWORD HUB_PG_PASSWORD EDA_ADMIN_PASSWORD
    EDA_PG_PASSWORD AUTOMATIONMETRICS_ADMIN_PASSWORD
    AUTOMATIONMETRICS_PG_PASSWORD
    AUTOMATIONMETRICS_CONTROLLER_READ_PG_PASSWORD
    AUTOMATIONMETRICS_HUB_READ_PG_PASSWORD
  )

  for key in "${required_keys[@]}"; do
    if ! grep -qE "^[[:space:]]+${key}:" "${schema_file}"; then
      missing_keys+=" ${key}"
    fi
  done

  assert_eq "env schema defines all supported variables" "" "${missing_keys}"
  lowercase_keys="$(sed -nE 's/^[[:space:]]+([A-Za-z_][A-Za-z0-9_]*):.*/\1/p' "${schema_file}" | grep -vE '^[A-Z][A-Z0-9_]*$' || true)"
  assert_eq "canonical env schema contains uppercase keys only" "" "${lowercase_keys}"
  schema_keys="$(sed -nE 's/^[[:space:]]+([A-Z][A-Z0-9_]*):.*/\1/p' "${schema_file}" | sort)"
  loader_keys="$(sed -n '/^AAP27_STATE_KEYS=(/,/^)/p' "${SCRIPT_DIR}/lib/state.sh" | tr ' ' '\n' | grep -E '^[A-Z][A-Z0-9_]*$' | sort)"
  assert_eq "canonical env schema matches shell loader" "${schema_keys}" "${loader_keys}"
  assert_status "local bundle prompt persists canonical path" 0 \
    grep -q 'save_env_kv "LOCAL_BUNDLE_PATH"' "${SCRIPT_DIR}/aap27_installer.sh"
  assert_status "installer secret collection includes admin password" 0 \
    grep -q 'ensure_required_secret "ADMIN_PASSWORD"' "${SCRIPT_DIR}/lib/state.sh"
  assert_status "installer secrets default component passwords from admin password" 0 \
    grep -q 'ensure_required_secret.*"$prompt".*"${ADMIN_PASSWORD}"' "${SCRIPT_DIR}/lib/state.sh"
  assert_status "controller workflow validates required credentials" 0 \
    grep -q 'Validate controller resource credentials' \
    "${SCRIPT_DIR}/aap_workflow_project/playbooks/create_controller_resources.yml"
}

test_installer_does_not_force_global_become() {
  local inventory_role cleanup_line managed_line
  inventory_role="${SCRIPT_DIR}/roles/aap27_inventory_growth/tasks/main.yml"
  cleanup_line="$(grep -nF -- '- name: Remove existing connection identity overrides' "${inventory_role}" | cut -d: -f1)"
  managed_line="$(grep -nF -- '- name: Set managed installer variables' "${inventory_role}" | cut -d: -f1)"

  assert_status "workflow does not force global become" 1 \
    grep -q "'ansible_become': true" "${SCRIPT_DIR}/aap_workflow_project/playbooks/install_aap.yml"
  assert_status "inventory role does not force global become" 1 \
    grep -q "ansible_become='true'" "${inventory_role}"
  assert_eq "inventory role removes connection overrides before managed values" "true" \
    "$([[ -n "${cleanup_line}" && -n "${managed_line}" && ${cleanup_line} -lt ${managed_line} ]] && echo true || echo false)"
  assert_status "inventory role removes stale user and connection variables" 0 \
    grep -qE 'ansible_user|ansible_user_dir|ansible_become_method|ansible_become|ansible_connection' "${inventory_role}"
  assert_status "role execution does not force global become" 1 \
    grep -qE "ansible_become(: true|='true')" "${SCRIPT_DIR}/roles/aap27_menu_installer/tasks/step_install.yml"
  assert_status "shell repairs stale global become" 0 \
    grep -q "sed -i '/\^ansible_become=/d'" "${SCRIPT_DIR}/aap27_installer.sh"
}

test_http_redirect_is_integrated() {
  local redirect_tasks sysctl_line service_line
  redirect_tasks="${SCRIPT_DIR}/roles/aap27_http_redirect/tasks/main.yml"

  assert_status "remote workflow configures HTTP redirect" 0 \
    grep -q "name: aap27_http_redirect" "${SCRIPT_DIR}/aap_workflow_project/playbooks/install_aap.yml"
  assert_status "role workflow configures HTTP redirect" 0 \
    grep -q "name: aap27_http_redirect" "${SCRIPT_DIR}/roles/aap27_menu_installer/tasks/step_install.yml"
  assert_status "local shell configures HTTP redirect" 0 \
    grep -q "configure_http_redirect_service || return 1" "${SCRIPT_DIR}/aap27_installer.sh"
  assert_status "HTTP redirect configures unprivileged port sysctl" 0 \
    grep -q "ansible.posix.sysctl" "${redirect_tasks}"
  assert_status "HTTP redirect persists dedicated sysctl file" 0 \
    grep -q "/etc/sysctl.d/90-aap27-http-redirect.conf" "${redirect_tasks}"
  assert_status "HTTP redirect verifies effective sysctl" 0 \
    grep -q "aap27_http_redirect_effective_unprivileged_port" "${redirect_tasks}"
  sysctl_line="$(grep -n 'name: Configure rootless access to the HTTP port' "${redirect_tasks}" | cut -d: -f1)"
  service_line="$(grep -n 'name: Enable and start HTTP redirect service' "${redirect_tasks}" | cut -d: -f1)"
  assert_eq "HTTP redirect configures sysctl before service startup" "1" \
    "$(( sysctl_line < service_line ))"
}

test_rebuilt_main_menu_layout() {
  local output expected_docs listed_docs main_body

  output="$(bash -c 'source "$1"; clear() { :; }; menu' _ "${SCRIPT_DIR}/aap27_installer.sh" <<< '0')"
  assert_contains "main menu includes documentation" "1) Documentation" "${output}"
  assert_contains "main menu includes install scope" "2) Set install scope (local/remote)" "${output}"
  assert_contains "main menu includes host preparation" \
    "3) Prepare host (packages, identity, admin user, credentials)" "${output}"
  assert_contains "main menu includes preflight" "4) Run preflight dependency checks" "${output}"
  assert_contains "main menu includes AAP install" "5) Install Ansible Automation Platform" "${output}"
  assert_contains "main menu includes environment reconfiguration" "6) Reconfigure Env" "${output}"
  assert_eq "main menu does not show scope prompt at startup" "false" \
    "$([[ "${output}" == *"Installation Mode"* ]] && echo true || echo false)"

  main_body="$(declare -f main)"
  assert_eq "interactive main does not force scope selection" "false" \
    "$([[ "${main_body}" == *"initial_install_scope_prompt"* ]] && echo true || echo false)"

  output="$(bash -c 'source "$1"; clear() { :; }; documentation_menu' _ "${SCRIPT_DIR}/aap27_installer.sh" <<< '0')"
  expected_docs="$(find "${SCRIPT_DIR}" -type f -name '*.md' \
    -not -path "${SCRIPT_DIR}/.git/*" \
    -not -path "${SCRIPT_DIR}/.venv-aap27/*" | wc -l)"
  listed_docs="$(printf '%s\n' "${output}" | sed -nE '/^[0-9]+\) .*\.md$/p' | wc -l)"
  assert_eq "documentation submenu lists every Markdown file" "${expected_docs}" "${listed_docs}"
}

test_debug_cli_contract() {
  local help_output main_body

  help_output="$(usage)"
  main_body="$(declare -f main)"
  assert_contains "help documents debug logging" \
    "--debug                     Enable Bash xtrace and Ansible -vvv output" "${help_output}"
  assert_contains "debug mode enables Bash xtrace" "set -x" "${main_body}"
  assert_contains "debug mode enables Ansible triple verbosity" \
    'ANSIBLE_VERBOSITY="-vvv"' "${main_body}"
  AAP_DEBUG=true
  assert_eq "debug mode overrides stored Ansible verbosity" \
    "-vvv" "$(normalize_ansible_verbosity none)"
  unset AAP_DEBUG
  assert_contains "project playbooks receive normalized verbosity" \
    'command+=("${ansible_verbosity}")' "$(declare -f run_project_playbook)"
}

test_reconfigure_environment_workflow() {
  local tmp_dir secret_value output reconfigure_status
  tmp_dir="$(mktemp -d)"

  NONINTERACTIVE=false
  secret_value="existing-secret"
  reconfigure_secret_value secret_value "Enter secret" <<< '' >/dev/null
  assert_eq "reconfigure secret keeps existing value on blank input" "existing-secret" "${secret_value}"
  reconfigure_secret_value secret_value "Enter secret" <<< 'replacement-secret' >/dev/null
  assert_eq "reconfigure secret accepts replacement value" "replacement-secret" "${secret_value}"

  RECONFIGURE_CALLS_FILE="${tmp_dir}/calls"
  export RECONFIGURE_CALLS_FILE
  (
    ENV_FILE="${tmp_dir}/state"
    touch "${ENV_FILE}"
    load_env() { :; }
    configure_install_scope() { printf '%s\n' scope >> "${RECONFIGURE_CALLS_FILE}"; }
    reconfigure_secret_value() {
      printf 'secret:%s\n' "$1" >> "${RECONFIGURE_CALLS_FILE}"
      printf -v "$1" 'configured-%s' "$1"
    }
    reconfigure_optional_secret_value() {
      printf 'optional-secret:%s\n' "$1" >> "${RECONFIGURE_CALLS_FILE}"
      printf -v "$1" 'configured-%s' "$1"
    }
    reconfigure_text_value() {
      printf 'text:%s\n' "$1" >> "${RECONFIGURE_CALLS_FILE}"
      printf -v "$1" 'configured-%s' "$1"
    }
    save_env_kv() { printf 'save:%s\n' "$1" >> "${RECONFIGURE_CALLS_FILE}"; }
    configure_ansible_verbosity() { printf '%s\n' verbosity >> "${RECONFIGURE_CALLS_FILE}"; }
    reconfigure_environment >/dev/null
  )
  output="$(cat "${RECONFIGURE_CALLS_FILE}")"
  assert_contains "reconfigure workflow updates install scope" "scope" "${output}"
  assert_contains "reconfigure workflow prompts admin password" "secret:ADMIN_PASSWORD" "${output}"
  assert_contains "reconfigure workflow prompts RHSM username" "text:RHSM_USERNAME" "${output}"
  assert_contains "reconfigure workflow prompts RHSM password" "secret:RHSM_PASSWORD" "${output}"
  assert_contains "reconfigure workflow prompts optional activation key" \
    "optional-secret:RHSM_ACTIVATION_KEY" "${output}"
  assert_contains "reconfigure workflow prompts offline token" "secret:RH_OFFLINE_TOKEN" "${output}"
  assert_contains "reconfigure workflow prompts Automation Hub token" "secret:RH_AH_TOKEN" "${output}"
  assert_contains "reconfigure workflow prompts bundle URL" "text:BUNDLE_URL" "${output}"
  assert_contains "reconfigure workflow prompts Ansible verbosity" "verbosity" "${output}"
  assert_contains "reconfigure workflow synchronizes CDN credentials" "save:CDN_USERNAME" "${output}"
  assert_contains "reconfigure workflow synchronizes console credentials" "save:CONSOLE_PASSWORD" "${output}"

  reconfigure_status=0
  (NONINTERACTIVE=true; reconfigure_environment) >/dev/null 2>&1 || reconfigure_status=$?
  assert_eq "reconfigure workflow rejects unattended execution" "1" "${reconfigure_status}"

  unset RECONFIGURE_CALLS_FILE
  rm -rf "${tmp_dir}"
}

test_rebuilt_menu_workflow_order() {
  local tmp_dir main_body
  tmp_dir="$(mktemp -d)"
  MENU_CALLS_FILE="${tmp_dir}/calls"
  export MENU_CALLS_FILE

  (
    require_install_scope() { :; }
    setup_admin_user() { printf '%s\n' admin >> "${MENU_CALLS_FILE}"; }
    prework_packages() { printf '%s\n' packages >> "${MENU_CALLS_FILE}"; }
    set_fqdn_and_hosts() { printf '%s\n' identity >> "${MENU_CALLS_FILE}"; }
    capture_credentials() { printf '%s\n' credentials >> "${MENU_CALLS_FILE}"; }
    INSTALL_SCOPE=remote
    prepare_host_workflow >/dev/null
  )
  assert_eq "remote host preparation follows required order" \
    $'admin\npackages\nidentity\ncredentials' "$(cat "${MENU_CALLS_FILE}")"

  : > "${MENU_CALLS_FILE}"
  (
    NONINTERACTIVE=false
    # shellcheck disable=SC2329
    run_complete_install_pipeline() {
      printf 'full-flow:noninteractive=%s\n' "${NONINTERACTIVE}" >> "${MENU_CALLS_FILE}"
    }
    install_ansible_automation_platform >/dev/null
  )
  assert_eq "AAP install menu action uses automated full workflow" \
    "full-flow:noninteractive=true" "$(cat "${MENU_CALLS_FILE}")"
  main_body="$(declare -f main)"
  assert_contains "CLI automated path uses shared full workflow" \
    "run_full_install_workflow" "${main_body}"

  unset MENU_CALLS_FILE
  rm -rf "${tmp_dir}"
}

echo "== aap27_installer.sh regression tests =="
test_ask_value_and_ask_yn_noninteractive
test_required_prompts_reject_empty_values
test_startup_requires_all_primary_secrets
test_installer_passwords_default_from_admin_password
test_derive_domain_from_fqdn
test_build_inventory_host_line
test_extract_bundle_detects_version_mismatch
test_get_preferred_remote_user_remote_scope
test_state_file_is_data_not_code
test_all_credentials_round_trip_encrypted_state
test_rhsm_registration_forwards_credentials_exactly
test_offline_token_exchange_and_fallback
test_legacy_env_file_migrates_to_yaml
test_collection_patch_version_gate
test_sourcing_preserves_caller_options
test_state_home_ignores_inherited_home
test_startup_repairs_stale_installer_key
test_ansible_runtime_creation_returns_clean_path
test_remote_inventory_uses_saved_fqdn_alias
test_explicit_target_reconfiguration_prompts
test_configurable_admin_identity
test_rootless_playbook_wrapper_hides_secrets
test_2_7_4_tls_hotfix_is_idempotent
test_2_7_4_rootless_env_hotfix_preserves_yaml
test_2_7_4_controller_tls_key_hotfix_is_scoped
test_2_7_4_gateway_api_hotfix_retries_transient_timeouts
test_nested_installer_validates_patched_yaml_first
test_remote_installer_streams_nested_playbook_log
test_remote_scope_routes_target_operations
test_complete_install_pipeline_order
test_remote_install_prework_relaxes_security
test_remote_setup_runs_repository_bootstrap
test_remote_root_bootstrap_contract
test_inventory_growth_contract
test_resource_shortfall_warning_and_pause
test_env_schema_defines_supported_variables
test_installer_does_not_force_global_become
test_http_redirect_is_integrated
test_rebuilt_main_menu_layout
test_debug_cli_contract
test_reconfigure_environment_workflow
test_rebuilt_menu_workflow_order

echo
echo "Passed: ${pass_count}, Failed: ${fail_count}"
[[ "${fail_count}" -eq 0 ]]
