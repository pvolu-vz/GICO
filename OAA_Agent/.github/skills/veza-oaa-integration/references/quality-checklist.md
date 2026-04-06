# Output Summary & Quality Checklist

## Step 3 — Output Summary

After generating all five files, provide:

1. **File tree** of everything created
2. **One-command install invocation** (ready to copy-paste once the GitHub URL is known):
   ```bash
   curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/main/install_<system_name>.sh | bash
   ```
3. **Example run command** using the generated CLI args:
   ```bash
   cd /opt/<system-slug>-veza/scripts
   source venv/bin/activate
   python3 <system_name>.py --env-file .env --dry-run
   ```
4. **What appears in Veza** — provider name, datasource name, entity types visible in Access Graph

---

## Quality Checklist

Verify each file before marking the task complete:

- [ ] Python script runs with `python3 <script>.py --help` without errors
- [ ] All credentials read from env/args — none hardcoded
- [ ] SQL queries use parameterized form — no string interpolation
- [ ] Installer supports both RHEL (`dnf`/`yum`) and Ubuntu (`apt`)
- [ ] Installer supports `--non-interactive` mode with env vars
- [ ] `.env.example` has placeholder values only — no real credentials
- [ ] README includes both interactive and non-interactive install instructions
- [ ] README includes a cron scheduling example
- [ ] README includes a troubleshooting section
- [ ] Logging uses `logging` module throughout — no bare `print()` (startup banner excepted)
- [ ] `--dry-run` skips Veza push and exits cleanly
- [ ] If `samples/` contained files, generated field names match sample data exactly
- [ ] If `samples/` was empty, `samples/SAMPLES.md` placeholder was created
