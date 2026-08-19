# aap27_rootless_podman role

Configures one non-root user for reliable rootless Podman operation:

- Optional user/package creation
- `/etc/subuid` and `/etc/subgid`
- `user.max_user_namespaces`
- systemd linger and `user@UID.service`
- DBus socket readiness
- `podman system migrate`
- rootless `podman.socket` and optional rootful socket
- Docker-compatible `DOCKER_HOST`
- Optional `registry.redhat.io` login
- `podman info` validation

## Example

```yaml
roles:
  - role: aap27_rootless_podman
    vars:
      aap27_rootless_podman_user: admin
      aap27_rootless_podman_enable_rootful_socket: true
      aap27_rootless_podman_registry_login: true
      aap27_rootless_podman_registry_username: "{{ rhsm_username }}"
      aap27_rootless_podman_registry_password: "{{ rhsm_password }}"
```

Credentials are passed with `no_log: true` and sent to Podman over stdin.

## Standalone playbook

```bash
cd aap_workflow_project
ansible-playbook -i inventory/controller.ini \
  playbooks/fix_podman_user_bus.yml \
  -e deployment_user=admin
```

Set `rootless_podman_hosts` to override the default `controller` group.
