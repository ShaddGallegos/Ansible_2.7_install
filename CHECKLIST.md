# AAP 2.7-2 Install Checklist

Use this checklist before running the installer or the AAP workflow project.

## Accounts, Tokens, and Credentials

- [ ] RHSM username/password
- [ ] RHSM account registration completed if needed: https://www.redhat.com/wapps/ugc/register.html?_flowId=register-flow&_flowExecutionKey=e1s1
- [ ] Red Hat offline token
- [ ] Red Hat offline token generated: https://access.redhat.com/management/api
- [ ] Red Hat Remote Automation Hub token
- [ ] Red Hat Remote Automation Hub token generated: https://console.redhat.com/ansible/automation-hub/token

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
- [ ] Execution playbook selected and verified

## Execution Playbook Options

- [ ] install
- [ ] backup
- [ ] bundle
- [ ] install_standalone_mcp
- [ ] log_gathering
- [ ] restore
- [ ] uninstall

## Shell Menu Execution Command

```bash
ansible-playbook -i inventory-growth ansible.containerized_installer.install
```

## Ansible Workflow (Controller-Driven)

Use this path when launching installation through AAP Job Templates and Workflow Templates.

### Workflow Setup

- [ ] Change directory to `/home/sgallego/GIT/Ansible_2.7_install/aap_workflow_project`
- [ ] Install required collections:

```bash
cd /home/sgallego/GIT/Ansible_2.7_install/aap_workflow_project
ansible-galaxy collection install -r requirements.yml
```

- [ ] Update controller and credential values in `aap_workflow_project/group_vars/all.yml`
- [ ] Verify `aap_workflow_project/inventory/controller.ini`

### Create Controller Resources

```bash
cd /home/sgallego/GIT/Ansible_2.7_install/aap_workflow_project
ansible-playbook -i inventory/controller.ini playbooks/create_controller_resources.yml
```

### Launch Workflow in AAP

- [ ] Open generated workflow template in AAP Controller
- [ ] Launch and complete survey values
- [ ] Set `execution_playbook` to one of: `install`, `backup`, `bundle`, `install_standalone_mcp`, `log_gathering`, `restore`, `uninstall`
