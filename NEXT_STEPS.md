# Next Steps (post-reboot / resume)

After a reboot or new terminal session, resume the automated full-install
workflow using the values already saved from a previous run:

```bash
cd /run/media/sgallego/SD_Card/GIT/Ansible_2.7_install
./aap27_installer.sh --non-interactive
```

This reuses `INSTALL_SCOPE`, `AAP_CONTROLLER_IP`/`AAP_CONTROLLER_FQDN`,
`ADMIN_PASSWORD`, RHSM credentials, and tokens from `~/.ansible/conf/env.yml`
(created on the first interactive run), and:

- Re-asks install scope + remote host details fresh (per design, these are
  never silently skipped - see `roles/aap27_menu_installer`/script comments).
- Skips root bootstrap only when the completion marker, RHEL registration,
  required repositories and packages, passwordless sudo, and admin SSH key
  access are all ready.
- Errors out clearly (naming the missing variable) instead of hanging if a
  required secret isn't already saved.

Selecting `5) Install Ansible Automation Platform` from the interactive menu
runs this same workflow with the same required target prompts.
