# aap27_bundle_hotfixes role

Applies narrowly scoped, version-gated compatibility fixes to an extracted AAP
bundle on the installation target. Every fix validates the expected upstream
task structure and fails closed if that structure changes.

Currently supported:

- AAP 2.7-4: delegated TLS CA synchronization uses a controller-owned mode-0700
  local temporary directory and disables escalation for local creation/cleanup.
  The role also recognizes the newer `common_ca_temp` structure when it already
  creates and removes the delegated directory without escalation and includes
  the upstream writable-directory task.
- AAP 2.7-4: exports `XDG_RUNTIME_DIR` and `HOME` alongside `TMPDIR` in the
  common role's bundled image-load shell scripts, fixing rootless podman
  storage failures when loading the bundled container images.
- AAP 2.7-4: relaxes strict TLS validation on the automation gateway proxy
  readiness probe (`Ensure automation gateway proxy is ready`), since the
  gateway's own proxy certificate is not expected to validate against the
  installer's public trust bundle.
- AAP 2.7-4: fixes the automationeda role's systemd task, which otherwise
  inherits a stale `__services` fact left over from the automationcontroller
  role earlier in the same play, causing it to manage the wrong systemd units
  instead of the EDA api/daphne/web/worker containers.
- AAP 2.7-4: relaxes the `controller_secret_key` podman secret mount mode from
  0400 to 0444, matching the other controller secrets. Without this, the
  awx process (running as a non-root, non-keep-id container UID) cannot read
  `/etc/tower/SECRET_KEY`, causing the controller-web container to crash loop.
- AAP 2.7-4: ensures the installer's internal CA certificate is present in the
  extracted TLS trust bundle (`aap/tls/extracted/pem/tls-ca-bundle.pem`) on
  every run, working around the collection's CA-trust-update task failing to
  target the custom trust directory. Without this, gateway-proxied services
  (controller, eda, galaxy, metrics) fail SSL certificate validation.
