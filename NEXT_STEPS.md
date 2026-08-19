# Next Steps (post-reboot / resume)

After a reboot or new terminal session, resume the install non-interactively
using the values already saved from a previous run:

```bash
cd /run/media/sgallego/SD_Card/GIT/Ansible_2.7_install
./aap27_menu_installer.sh --non-interactive
```

This reuses `INSTALL_SCOPE`, `AAP_CONTROLLER_IP`/`AAP_CONTROLLER_FQDN`,
`ADMIN_PASSWORD`, RHSM credentials, and tokens from `~/.aap27_install.env`
(created on the first interactive run), and:

- Re-asks install scope + remote host details fresh (per design, these are
  never silently skipped - see `roles/aap27_menu_installer`/script comments).
- Skips the remote admin SSH bootstrap step if `admin@<remote host>` is
  already reachable with the saved key.
- Errors out clearly (naming the missing variable) instead of hanging if a
  required secret isn't already saved.

To check current status without re-running the full flow:

```bash
./aap27_menu_installer.sh
# then select: 6) Inspect (checklist/status)
```
