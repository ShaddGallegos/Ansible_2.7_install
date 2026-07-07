# AAP 2.7-2 Install Checklist

Use this checklist before running the installer or the AAP workflow project.

## Accounts, Tokens, and Credentials

- [ ] RHSM username/password
  - Account registration (if needed): https://www.redhat.com/wapps/ugc/register.html?_flowId=register-flow&_flowExecutionKey=e1s1
- [ ] Red Hat offline token
  - Generate token: https://access.redhat.com/management/api
- [ ] Red Hat Remote Automation Hub token
  - Generate token: https://console.redhat.com/ansible/automation-hub/token

## Host Readiness

- [ ] Root or passwordless sudo access
- [ ] RHEL host meets CPU/RAM/storage requirements
- [ ] DNS and reverse DNS configured
- [ ] NTP/chrony synchronized
- [ ] FQDN set correctly
- [ ] `/etc/hosts` contains `<IP> <FQDN> aap`

## Security and Access

- [ ] `admin` user exists
- [ ] `admin` has passwordless sudo (`/etc/sudoers.d/admin`)
- [ ] SSH keys created for `admin`
- [ ] `admin` key copied to target node(s)

## Platform Components

- [ ] AAP bundle downloaded to `/home/admin/Downloads/`
- [ ] Bundle extracted
- [ ] `inventory-growth` updated
- [ ] Install command verified

## Install Command

```bash
ansible-playbook -i inventory-growth ansible.containerized_installer.install
```
