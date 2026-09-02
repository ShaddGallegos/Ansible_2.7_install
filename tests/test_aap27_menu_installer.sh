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
    bootstrap_remote_admin() { :; }
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
    bootstrap_remote_admin() { :; }
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

test_remote_root_bootstrap_contract() {
  local bootstrap_body register_line repos_line install_line ssh_config_line restart_line marker_line
  bootstrap_body="$(declare -f provision_remote_admin_via_ssh)"

  assert_contains "remote bootstrap readiness requires completion marker" \
    "/var/lib/aap27-bootstrap-complete" "${bootstrap_body}"
  assert_contains "remote bootstrap readiness requires podman" \
    "command -v podman" "${bootstrap_body}"
  assert_contains "remote bootstrap collects RHSM credentials" \
    "ensure_registry_credentials" "${bootstrap_body}"
  assert_contains "remote bootstrap registers RHEL through root" \
    "subscription-manager register" "${bootstrap_body}"
  # shellcheck disable=SC2016
  assert_contains "remote bootstrap enables BaseOS and AppStream" \
    'subscription-manager repos --enable "\${BASEOS_REPO}" --enable "\${APPSTREAM_REPO}"' "${bootstrap_body}"
  assert_contains "remote bootstrap installs required packages" \
    "rsync podman podman-docker python3 python3-pip" "${bootstrap_body}"
  # shellcheck disable=SC2016
  assert_contains "remote bootstrap uses sshpass root connection" \
    'sshpass -p "${root_password}"' "${bootstrap_body}"
  assert_contains "remote bootstrap forces one-time root password prompt" \
    'true || return 1' "${bootstrap_body}"
  assert_contains "remote bootstrap configures strict host-key checking off" \
    "StrictHostKeyChecking no" "${bootstrap_body}"
  assert_contains "remote bootstrap configures null known-hosts file" \
    "UserKnownHostsFile /dev/null" "${bootstrap_body}"
  assert_contains "remote bootstrap restarts sshd" \
    "systemctl restart sshd" "${bootstrap_body}"

  register_line="$(grep -n 'subscription-manager register' <<< "${bootstrap_body}" | head -n1 | cut -d: -f1)"
  repos_line="$(grep -n 'subscription-manager repos --enable' <<< "${bootstrap_body}" | head -n1 | cut -d: -f1)"
  install_line="$(grep -n 'dnf -y install' <<< "${bootstrap_body}" | head -n1 | cut -d: -f1)"
  ssh_config_line="$(grep -n 'cat > /etc/ssh/ssh_config.d/90-aap27' <<< "${bootstrap_body}" | head -n1 | cut -d: -f1)"
  restart_line="$(grep -n 'systemctl restart sshd' <<< "${bootstrap_body}" | head -n1 | cut -d: -f1)"
  marker_line="$(grep -n 'install -o root -g root -m 0600' <<< "${bootstrap_body}" | head -n1 | cut -d: -f1)"
  assert_eq "remote bootstrap orders registration before repositories" "1" \
    "$(( register_line < repos_line ))"
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
    grep -q 'ADMIN_PASSWORD|Enter admin_password' "${SCRIPT_DIR}/lib/state.sh"
  assert_status "controller workflow validates required credentials" 0 \
    grep -q 'Validate controller resource credentials' \
    "${SCRIPT_DIR}/aap_workflow_project/playbooks/create_controller_resources.yml"
}

test_installer_does_not_force_global_become() {
  assert_status "workflow does not force global become" 1 \
    grep -q "'ansible_become': true" "${SCRIPT_DIR}/aap_workflow_project/playbooks/install_aap.yml"
  assert_status "inventory role does not force global become" 1 \
    grep -q "ansible_become='true'" "${SCRIPT_DIR}/roles/aap27_inventory_growth/tasks/main.yml"
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
test_derive_domain_from_fqdn
test_build_inventory_host_line
test_extract_bundle_detects_version_mismatch
test_get_preferred_remote_user_remote_scope
test_state_file_is_data_not_code
test_legacy_env_file_migrates_to_yaml
test_collection_patch_version_gate
test_sourcing_preserves_caller_options
test_remote_inventory_uses_saved_fqdn_alias
test_explicit_target_reconfiguration_prompts
test_configurable_admin_identity
test_rootless_playbook_wrapper_hides_secrets
test_2_7_4_tls_hotfix_is_idempotent
test_remote_scope_routes_target_operations
test_complete_install_pipeline_order
test_remote_install_prework_relaxes_security
test_remote_root_bootstrap_contract
test_inventory_growth_contract
test_resource_shortfall_warning_and_pause
test_env_schema_defines_supported_variables
test_installer_does_not_force_global_become
test_http_redirect_is_integrated
test_rebuilt_main_menu_layout
test_reconfigure_environment_workflow
test_rebuilt_menu_workflow_order

echo
echo "Passed: ${pass_count}, Failed: ${fail_count}"
[[ "${fail_count}" -eq 0 ]]
