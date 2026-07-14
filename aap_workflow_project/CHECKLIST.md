# Workflow Project Checklist

## Repository Automation Completed

- [x] Prework configures rootless podman for runtime `remote_user` (survey value), not only `admin`.
- [x] Prework enables linger, starts `user@<uid>`, and waits for `/run/user/<uid>/bus` before installer execution.
- [x] Install playbook validates survey `remote_user` and `machine_credential_username` alignment.
- [x] Prework configures rootless `podman.socket` for installer user and rootful `podman.socket` for system scope.
- [x] Prework ensures `DOCKER_HOST` compatibility export in installer user `.bashrc`.

## Controller Access

- [ ] `aap_controller_host` is reachable
- [ ] Controller credentials/token are set in `group_vars/all.yml`
- [ ] Account can create org/inventory/credentials/projects/templates/workflows

## Token and Credential Sources

- [ ] RHSM username/password
  - https://www.redhat.com/wapps/ugc/register.html?_flowId=register-flow&_flowExecutionKey=e1s1
- [ ] Red Hat offline token
  - https://access.redhat.com/management/api
- [ ] Red Hat Remote Automation Hub token
  - https://console.redhat.com/ansible/automation-hub/token

## AAP Workflow Content

- [ ] Project synced from GitHub
- [ ] Inventory contains target install host
- [ ] Machine credential for target host created
- [ ] Machine credential username is non-root (for example `admin`)
- [ ] Rootless podman prepared for installer `remote_user` (`/etc/subuid`, `/etc/subgid`, linger)
- [ ] Registry login valid for installer `remote_user` (`registry.redhat.io`)
- [ ] Job templates created and linked
- [ ] Surveys reviewed and adjusted for your environment

## Launch Validation

- [ ] Launch workflow template from AAP UI/API
- [ ] Survey prompts appear as expected
- [ ] `remote_user` survey value is non-root (for example `admin`)
- [ ] Each node completes in order
