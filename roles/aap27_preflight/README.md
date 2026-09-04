# aap27_preflight role

Idempotent CPU, RAM, and available-disk validation for AAP target hosts.

## Contents

- Description
- Example
Defaults match the shell installer checks: 4 vCPUs, 16 GB RAM, and 40 GB free
on `/`.

By default insufficient resources produce warnings. Set
`aap27_preflight_fail_on_insufficient: true` to enforce the thresholds.

```yaml
roles:
  - role: aap27_preflight
    vars:
      aap27_preflight_min_cpu: 4
      aap27_preflight_min_ram_gb: 16
      aap27_preflight_min_disk_gb: 40
      aap27_preflight_fail_on_insufficient: true
```
