#!/usr/bin/env bash
# Lightweight regression tests for aap27_menu_installer.sh.
# Sources the script's functions and exercises them directly, without touching
# the real system.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck disable=SC1090
source "${SCRIPT_DIR}/aap27_menu_installer.sh"

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
  local tmp_dir marker
  tmp_dir="$(mktemp -d)"
  marker="${tmp_dir}/executed"
  ENV_FILE="${tmp_dir}/state"

  cat > "${ENV_FILE}" <<EOF
RHSM_USERNAME='legacy-user'
EVIL=\$(touch "${marker}")
EOF

  unset RHSM_USERNAME RHSM_PASSWORD
  load_env
  assert_eq "legacy state remains readable" "legacy-user" "${RHSM_USERNAME}"
  [[ ! -e "${marker}" ]] || { echo "[FAIL] state file executed shell content"; fail_count=$((fail_count + 1)); }

  save_env_kv RHSM_PASSWORD "p@ss word"
  unset RHSM_PASSWORD
  load_env
  assert_eq "base64 state value round-trips" "p@ss word" "${RHSM_PASSWORD}"
  grep -q '^RHSM_PASSWORD_B64=' "${ENV_FILE}"
  assert_status "unknown state key is rejected" 1 save_env_kv PATH bad

  rm -rf "${tmp_dir}"
}

test_collection_patch_version_gate() {
  local tmp_dir original_bundle_dir
  tmp_dir="$(mktemp -d)"
  mkdir -p "${tmp_dir}/collections/ansible_collections/ansible/containerized_installer"
  original_bundle_dir="${BUNDLE_DIR_NAME}"

  BUNDLE_DIR_NAME="ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64"
  assert_status "validated 2.7-2 patch set is accepted" 0 patch_containerized_installer_user_bus_task "${tmp_dir}"

  BUNDLE_DIR_NAME="ansible-automation-platform-containerized-setup-bundle-2.7-4-x86_64"
  assert_status "unvalidated 2.7-4 patch set is rejected" 1 patch_containerized_installer_user_bus_task "${tmp_dir}"

  BUNDLE_DIR_NAME="${original_bundle_dir}"
  rm -rf "${tmp_dir}"
}

test_sourcing_preserves_caller_options() {
  # shellcheck disable=SC2016
  assert_status "sourcing does not enable nounset in caller" 0 \
    bash -c 'set +u; source "$1"; [[ $- != *u* ]]' _ "${SCRIPT_DIR}/aap27_menu_installer.sh"
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
  AAP_CONTROLLER_FQDN="aap.example.test"

  initial_install_scope_prompt >/dev/null

  assert_status "generated controller inventory uses saved FQDN alias" 0 \
    grep -q '^aap\.example\.test ansible_host=192\.0\.2\.15 ' \
    "${tmp_dir}/aap_workflow_project/inventory/controller.ini"

  SCRIPT_DIR="${original_script_dir}"
  ENV_FILE="${original_env_file}"
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
  local tmp_dir original_script_dir original_path
  tmp_dir="$(mktemp -d)"
  original_script_dir="${SCRIPT_DIR}"
  original_path="${PATH}"

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

  run_rootless_podman_playbook platformops true registry-user 'test password' >/dev/null

  assert_status "rootless wrapper keeps password out of argv" 1 grep -q 'test password' "${CAPTURE_ARGS}"
  assert_eq "rootless wrapper uses mode-0600 vars" "600" "$(cat "${CAPTURE_MODE}")"
  assert_eq "rootless wrapper forwards deployment user" "platformops" "$(jq -r .deployment_user "${CAPTURE_VARS}")"
  assert_eq "rootless wrapper forwards registry login flag" "true" "$(jq -r .registry_login "${CAPTURE_VARS}")"

  SCRIPT_DIR="${original_script_dir}"
  PATH="${original_path}"
  unset CAPTURE_ARGS CAPTURE_MODE CAPTURE_VARS
  rm -rf "${tmp_dir}"
}

echo "== aap27_menu_installer.sh regression tests =="
test_ask_value_and_ask_yn_noninteractive
test_derive_domain_from_fqdn
test_build_inventory_host_line
test_extract_bundle_detects_version_mismatch
test_get_preferred_remote_user_remote_scope
test_state_file_is_data_not_code
test_collection_patch_version_gate
test_sourcing_preserves_caller_options
test_remote_inventory_uses_saved_fqdn_alias
test_configurable_admin_identity
test_rootless_playbook_wrapper_hides_secrets

echo
echo "Passed: ${pass_count}, Failed: ${fail_count}"
[[ "${fail_count}" -eq 0 ]]
