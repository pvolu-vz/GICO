# GICO to Veza Integration Script

## Overview

The `gico.py` script is an OAA (Open Authorization API) integration that reads GICO application export files and pushes identity, role, and permission data to Veza's Access Graph. It creates a **CustomApplication** in Veza that models GICO users, roles, scopes (plants/sites), and actions (permissions).

### Data Flow

1. **Parse** — Reads six tab-delimited `.txt` export files from a local directory (or mounted SMB/CIFS share)
2. **Model** — Maps GICO entities to the OAA CustomApplication template
3. **Push** — Submits the payload to the Veza platform via the OAA Python SDK

### Entity Mapping

| GICO Entity | Veza OAA Entity       | Description |
|-------------|-----------------------|-------------|
| Scope       | Resource (`scope`)    | Plant / site where access applies |
| User        | Local User            | GICO user account |
| Role        | Local Role            | Collection of granted actions |
| Action      | Custom Permission     | Individual application function |
| RoleAction  | Role → Permission     | Which actions each role grants |
| UserRole    | Role Assignment       | User assigned to role on scope resource |

### What Appears in Veza

After a successful push, you will see in the Veza Access Graph:

- **Provider**: `GICO` (configurable via `--provider-name`)
- **Datasource**: `GICO` (configurable via `--datasource-name`)
- **Resources**: One per scope/plant (e.g., `GSKN`, `GEWLT (0)`, `GEDUS (030)`)
- **Local Users**: All GICO users with email, department, active status
- **Local Roles**: All GICO roles with their granted action permissions
- **Permissions**: Each GICO action code as a custom permission

---

## How It Works

1. Validates that all six required export files exist in the `--data-dir` directory
2. Parses each file into structured data (users, roles, scopes, actions, role-actions, user-roles)
3. Creates a `CustomApplication` with scope resources and custom permissions for every GICO action
4. Adds local roles with their granted actions (from `RoleActions.txt` where granted=1)
5. Adds local users with identity properties (email, department, admin flag)
6. Assigns each user-role-scope triple as a role assignment on the scope resource
7. Pushes the complete payload to Veza (or saves JSON in `--dry-run` mode)

---

## Prerequisites

### System Requirements

- **Operating System**: Red Hat Enterprise Linux 8+ or Ubuntu/Debian (any Linux with Python 3.8+)
- **Python**: 3.8 or higher
- **Network**: Outbound HTTPS access to your Veza instance
- **Storage**: Access to GICO export files (local path or mounted SMB/CIFS share)

### GICO Requirements

The following tab-delimited `.txt` files must be exported from GICO:

| File | Description | Columns |
|------|-------------|---------|
| `Users.txt` | User accounts | username, first\_name, last\_name, col4, col5, is\_active, is\_admin, email, department |
| `Roles.txt` | Role definitions | role\_code, role\_display\_name |
| `Scopes.txt` | Plant/site scopes | scope\_code, active\_flag, scope\_name |
| `Actions.txt` | Action definitions | action\_code, description, (empty), language, flag |
| `RoleActions.txt` | Role → action grants | role\_name, action\_code, granted(0/1) |
| `UserRoles.txt` | User → role per scope | username, role\_name, scope\_code |

### Veza Requirements

- Veza instance URL
- Veza API key with OAA push permissions

---

## Quick Start

### One-Command Installer (Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/main/integrations/gico/install_gico.sh | bash
```

The installer will:
- Detect your Linux distribution and install system packages
- Clone the repository into `/opt/gico-veza/scripts/`
- Create a Python virtual environment and install dependencies
- Prompt for Veza credentials and generate a `.env` file

Non-interactive mode (CI/automation):

```bash
VEZA_URL=your-company.veza.com \
VEZA_API_KEY='your_api_key' \
bash install_gico.sh --non-interactive
```

---

## Manual Installation

### RHEL / CentOS / Fedora

```bash
# Install Python 3 and dependencies
sudo dnf install python3 python3-pip python3-venv git -y

# Clone the repository
git clone https://github.com/<org>/<repo>.git /opt/gico-veza/scripts
cd /opt/gico-veza/scripts

# Create virtual environment
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r integrations/gico/requirements.txt
```

### Ubuntu / Debian

```bash
sudo apt-get update && sudo apt-get install -y python3 python3-pip python3-venv git

git clone https://github.com/<org>/<repo>.git /opt/gico-veza/scripts
cd /opt/gico-veza/scripts

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r integrations/gico/requirements.txt
```

### Configure credentials

```bash
cp integrations/gico/.env.example integrations/gico/.env
chmod 600 integrations/gico/.env
# Edit .env with your Veza URL, API key, and data directory
```

---

## Usage

```bash
cd /opt/gico-veza/scripts
source venv/bin/activate
python3 integrations/gico/gico.py --data-dir /path/to/gico/exports [options]
```

### Command-Line Arguments

| Argument | Required | Default | Description |
|----------|----------|---------|-------------|
| `--data-dir` | Yes | — | Directory containing GICO export `.txt` files |
| `--env-file` | No | `.env` | Path to `.env` file for credentials |
| `--veza-url` | No | `VEZA_URL` env var | Veza instance URL |
| `--veza-api-key` | No | `VEZA_API_KEY` env var | Veza API key |
| `--provider-name` | No | `GICO` | Provider name in Veza UI |
| `--datasource-name` | No | `GICO` | Datasource name — use unique name per plant/environment |
| `--dry-run` | No | — | Build payload without pushing to Veza |
| `--save-json` | No | — | Save OAA payload as JSON file for debugging |
| `--log-level` | No | `INFO` | Logging level: DEBUG, INFO, WARNING, ERROR |

### Examples

```bash
# Dry run with local sample data
python3 integrations/gico/gico.py --data-dir ./integrations/gico/samples --dry-run

# Production push with .env credentials
python3 integrations/gico/gico.py \
  --data-dir /mnt/gico-export/de-production \
  --env-file /opt/gico-veza/scripts/.env \
  --datasource-name "GICO DE Production"

# Debug mode with JSON output
python3 integrations/gico/gico.py \
  --data-dir /mnt/gico-export/de-production \
  --dry-run --save-json --log-level DEBUG

# Using CLI args instead of .env
python3 integrations/gico/gico.py \
  --data-dir /path/to/exports \
  --veza-url your-company.veza.com \
  --veza-api-key "your_key_here" \
  --provider-name "GICO" \
  --datasource-name "GICO NL Staging"
```

---

## Deployment on Linux

### 1. Create Dedicated Service Account

```bash
sudo useradd -r -s /bin/bash -m -d /opt/gico-veza gico-veza
```

### 2. File Permissions

```bash
# Secure credentials
chmod 600 /opt/gico-veza/scripts/.env
chmod 600 /opt/gico-veza/scripts/integrations/gico/.env

# Secure scripts directory
chmod 700 /opt/gico-veza/scripts
chown -R gico-veza:gico-veza /opt/gico-veza
```

### 3. SELinux (RHEL)

```bash
# Check if SELinux is enabled
getenforce

# Set proper file contexts
sudo semanage fcontext -a -t bin_t "/opt/gico-veza/scripts/.*\.py"
sudo semanage fcontext -a -t bin_t "/opt/gico-veza/scripts/.*\.sh"
sudo restorecon -Rv /opt/gico-veza/scripts
```

### 4. Wrapper Script for Cron

Create `/opt/gico-veza/scripts/run_gico_sync.sh`:

```bash
#!/bin/bash
# GICO-Veza Integration Cron Wrapper

SCRIPT_DIR="/opt/gico-veza/scripts"
LOG_DIR="/opt/gico-veza/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/gico_sync_${TIMESTAMP}.log"

# Activate virtual environment
source "${SCRIPT_DIR}/venv/bin/activate"
cd "${SCRIPT_DIR}"

python3 integrations/gico/gico.py \
  --data-dir /path/to/gico/exports \
  --env-file "${SCRIPT_DIR}/.env" \
  --datasource-name "GICO Production" \
  >> "${LOG_FILE}" 2>&1

EXIT_CODE=$?
echo "Completed with exit code: ${EXIT_CODE}" >> "${LOG_FILE}"

# Rotate logs older than 30 days
find "${LOG_DIR}" -name "gico_sync_*.log" -mtime +30 -delete

exit ${EXIT_CODE}
```

```bash
chmod 755 /opt/gico-veza/scripts/run_gico_sync.sh
```

### 5. Cron Scheduling

```bash
# Edit crontab for the service account
sudo su - gico-veza
crontab -e
```

```cron
# Run GICO sync daily at 2:00 AM
0 2 * * * /opt/gico-veza/scripts/run_gico_sync.sh

# Or every 6 hours
0 */6 * * * /opt/gico-veza/scripts/run_gico_sync.sh
```

Or use a system cron job:

```bash
sudo bash -c 'cat > /etc/cron.d/gico-veza << EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=admin@example.com

0 2 * * * gico-veza /opt/gico-veza/scripts/run_gico_sync.sh
EOF'
sudo chmod 644 /etc/cron.d/gico-veza
```

### 6. Log Rotation

Create `/etc/logrotate.d/gico-veza`:

```
/opt/gico-veza/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 0640 gico-veza gico-veza
}
```

---

## Multiple Instances

If you have multiple GICO environments (different plants, regions, or staging/production), use separate `.env` files and `--datasource-name` values.

### Setup

```bash
cd /opt/gico-veza/scripts

# Create per-environment configs
cp integrations/gico/.env.example configs/gico-de-prod.env
cp integrations/gico/.env.example configs/gico-nl-prod.env
cp integrations/gico/.env.example configs/gico-staging.env

# Edit each with environment-specific paths and datasource names
vim configs/gico-de-prod.env
vim configs/gico-nl-prod.env

chmod 600 configs/*.env
```

### Datasource Naming

Each environment creates a separate datasource in Veza under one shared provider:

```
Provider: GICO
  ├── GICO DE Production
  ├── GICO NL Production
  └── GICO Staging
```

### Cron for Multiple Instances

```cron
# Stagger start times by 15 minutes
0  2 * * * cd /opt/gico-veza/scripts && ./venv/bin/python integrations/gico/gico.py --data-dir /mnt/gico-de/exports --env-file configs/gico-de-prod.env --datasource-name "GICO DE Production" >> logs/gico-de-cron.log 2>&1
15 2 * * * cd /opt/gico-veza/scripts && ./venv/bin/python integrations/gico/gico.py --data-dir /mnt/gico-nl/exports --env-file configs/gico-nl-prod.env --datasource-name "GICO NL Production" >> logs/gico-nl-cron.log 2>&1
```

---

## Security Considerations

- **Credential storage**: `.env` files must have `chmod 600` — never commit to version control
- **API key rotation**: Rotate Veza API keys periodically; update `.env` and test before revoking old keys
- **File permissions**: Service account should own `/opt/gico-veza/` with minimal permissions
- **SELinux/AppArmor**: Apply proper security contexts on RHEL; verify with `restorecon`
- **SMB/CIFS shares**: If mounting a remote share for GICO exports, use a dedicated read-only service account and `sec=krb5` where possible
- **No hardcoded credentials**: All secrets are read from `.env` files or environment variables

---

## Troubleshooting

### Authentication Failures

```bash
# Verify Veza URL and API key
source venv/bin/activate
python3 -c "
from dotenv import load_dotenv; import os; load_dotenv('.env')
print('VEZA_URL:', os.getenv('VEZA_URL'))
print('API_KEY set:', bool(os.getenv('VEZA_API_KEY')))
"

# Test Veza connectivity
curl -H "Authorization: Bearer YOUR_API_KEY" https://your-company.veza.com/api/v1/providers
```

### Missing Export Files

```
ERROR  Missing required files in /path/to/exports: Actions.txt, Scopes.txt
```

Ensure all six `.txt` files are present in the `--data-dir` directory.

### Module Not Found

```bash
source venv/bin/activate
pip install -r integrations/gico/requirements.txt --force-reinstall
```

### Veza Push Warnings

Warnings during push typically indicate that identity mappings could not be resolved. Check:
- User emails match IdP identities in Veza
- Provider name is consistent across runs

### Dry Run for Debugging

```bash
python3 integrations/gico/gico.py --data-dir ./samples --dry-run --save-json --log-level DEBUG
```

This builds the full payload without pushing and saves it as a JSON file for inspection.

---

## Changelog

### v1.0 — Initial Release

- Tab-delimited file parsing for all six GICO export file types
- OAA CustomApplication model with scopes as resources
- Local roles with granular action-level permissions (624 actions)
- User → role → scope assignment mapping
- Dry run and JSON debug output support
- Linux installer with RHEL and Ubuntu support
- Multiple instance/environment support via `--env-file` and `--datasource-name`
