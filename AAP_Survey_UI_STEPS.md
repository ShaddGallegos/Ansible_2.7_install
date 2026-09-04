# Short UI steps: create a Job Template Survey in Ansible Automation Platform

## Contents

- Steps
- Notes

1. Open the Controller web UI and sign in as an admin.
2. Navigate to Templates -> Job Templates and open the Template used to run `install_aap.yml` (or create one pointing at the project/playbook).
3. Click the "SURVEY" tab and then "Add" to create a new survey.
4. Add a question with these fields:
   - Question: PostgreSQL admin password
   - Answer variable name: postgresql_admin_password
   - Answer type: Password
   - Required: Yes
   - Default: (leave empty) or put `redhat` if you want a default for CLI parity
   - Prompt on launch: Yes
5. Save the survey and enable it on the Job Template.
6. Launch the Job Template; the Controller will prompt for the password (masked) and inject it into `extra_vars` available to the job.

Notes:
- Use a sensitive credential instead of surveys for production secrets where possible.
- If the playbook is invoked via the wrapper script `run_install_aap.sh`, the CLI prompt supplies the same `postgresql_admin_password` key so both workflows are compatible.
