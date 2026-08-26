# aap27_inventory_growth role

Idempotently prepares an extracted AAP `inventory-growth` file on the target
host. Every component host entry before `[all:vars]` is normalized to:

```ini
<target-fqdn> ansible_host=<target-address>
```

The nested containerized installer still executes with `-c local` on that
target. The managed variables set `ansible_user='admin'`, map
`registry_username` and `registry_password` from the saved RHSM credentials,
and remove stale definitions that would override those values.

Secret-bearing mutations use `no_log: true`; the inventory file should remain
owned by the platform admin with restrictive host permissions.
