# shellcheck shell=bash

run_full_install_step() {
    local step_number="${1:-0}"
    local description="${2:-step ${step_number}}"
    local function_name="${3:-true}"
    shift 3 || true

    log "Full install ${step_number}: ${description}"
    if [[ "${function_name}" == "true" ]]; then
        return 0
    fi
    if [[ "$(type -t "${function_name}")" != "function" ]]; then
        err "Full install step ${step_number} references unknown function: ${function_name}"
        return 1
    fi
    "${function_name}" "$@"
}

prepare_install_target() {
    load_env
    resolve_target_context

    if [[ "${TARGET_SCOPE}" == "remote" ]]; then
        run_remote_prework true true
        return $?
    fi

    prework_packages || return 1
    disable_firewall_selinux
}

run_complete_install_pipeline() {
    run_full_install_step 1 "load installation target" configure_install_scope false || return 1
    if [[ "$(get_install_scope)" == "remote" ]]; then
        bootstrap_remote_admin "$(get_install_target_host)" || return 1
    fi
    run_full_install_step 2 "bootstrap admin, RHEL repositories, and prerequisite packages" setup_admin_user || return 1
    run_full_install_step 3 "prerequisite resource and package checks" run_preflight_resource_checks || return 1
    run_full_install_step 4 "prepare host and relax firewalld/SELinux for installation" prepare_install_target || return 1
    run_full_install_step 5 "configure target host identity" set_fqdn_and_hosts || return 1
    run_full_install_step 6 "capture credentials and tokens" capture_credentials || return 1
    run_full_install_step 7 "download and extract the AAP bundle" download_bundle || return 1
    run_full_install_step 8 "verify extracted bundle" extract_bundle || return 1
    run_full_install_step 9 "prepare inventory-growth" modify_inventory_growth || return 1
    run_full_install_step 10 "run the AAP containerized installer" run_execution_playbook install || return 1

    ok "Ansible Automation Platform full installation pipeline completed."
}

run_full_install_workflow() {
    local original_noninteractive workflow_status

    original_noninteractive="${NONINTERACTIVE}"
    NONINTERACTIVE=true
    run_complete_install_pipeline
    workflow_status=$?
    NONINTERACTIVE="${original_noninteractive}"
    return "${workflow_status}"
}
