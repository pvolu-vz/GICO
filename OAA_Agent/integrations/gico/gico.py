#!/usr/bin/env python3
"""
GICO to Veza OAA Integration Script
Collects identity and permission data from GICO export files and pushes to Veza.

Source files (tab-delimited .txt):
  Users.txt      — User accounts (username, name, email, department, flags)
  Roles.txt      — Role definitions (role code and display name)
  Scopes.txt     — Plant/site scope definitions (code, active flag, name)
  Actions.txt    — Action/permission definitions (code, description path, language)
  RoleActions.txt — Role-to-action mappings with granted flag (0/1)
  UserRoles.txt  — User-to-role assignments per scope

OAA Entity Mapping:
  GICO Scope     →  OAA Resource  (type: scope)
  GICO User      →  OAA Local User
  GICO Role      →  OAA Local Role
  GICO Action    →  OAA Custom Permission
  RoleAction     →  Role ↔ Permission binding
  UserRole       →  User ↔ Role assignment on Scope resource
"""

import argparse
import csv
import json
import logging
import os
import sys
from collections import defaultdict
from pathlib import Path

from dotenv import load_dotenv
from oaaclient.client import OAAClient, OAAClientError
from oaaclient.templates import CustomApplication, OAAPermission, OAAPropertyType

log = logging.getLogger(__name__)

# ─── File Parsers ────────────────────────────────────────────────────────────

EXPECTED_FILES = [
    "Users.txt",
    "Roles.txt",
    "Scopes.txt",
    "Actions.txt",
    "RoleActions.txt",
    "UserRoles.txt",
]


def _open_tab_reader(filepath):
    """Open a tab-delimited file and return a csv.reader."""
    fh = open(filepath, "r", encoding="utf-8", errors="replace", newline="")
    return csv.reader(fh, delimiter="\t"), fh


def parse_users(filepath):
    """Parse Users.txt — tab-delimited, no header.

    Columns: username  first_name  last_name  col4  col5  is_active  is_admin  email  department
    """
    users = []
    reader, fh = _open_tab_reader(filepath)
    try:
        for row in reader:
            if len(row) < 7:
                continue
            username = row[0].strip()
            if not username:
                continue
            users.append(
                {
                    "username": username,
                    "first_name": row[1].strip(),
                    "last_name": row[2].strip(),
                    "is_active": row[5].strip() == "1" if len(row) > 5 else True,
                    "is_admin": row[6].strip() == "1" if len(row) > 6 else False,
                    "email": row[7].strip() if len(row) > 7 else "",
                    "department": row[8].strip() if len(row) > 8 else "",
                }
            )
    finally:
        fh.close()
    return users


def parse_roles(filepath):
    """Parse Roles.txt — tab-delimited, no header.

    Columns: role_code  role_display_name
    """
    roles = []
    reader, fh = _open_tab_reader(filepath)
    try:
        for row in reader:
            if not row or not row[0].strip():
                continue
            roles.append(
                {
                    "role_code": row[0].strip(),
                    "role_name": row[1].strip() if len(row) > 1 else row[0].strip(),
                }
            )
    finally:
        fh.close()
    return roles


def parse_scopes(filepath):
    """Parse Scopes.txt — tab-delimited, no header.

    Columns: scope_code  active_flag  scope_name
    """
    scopes = []
    reader, fh = _open_tab_reader(filepath)
    try:
        for row in reader:
            if len(row) < 3:
                continue
            scopes.append(
                {
                    "scope_code": row[0].strip(),
                    "active": row[1].strip() == "1",
                    "scope_name": row[2].strip(),
                }
            )
    finally:
        fh.close()
    return scopes


def parse_actions(filepath):
    """Parse Actions.txt — tab-delimited, no header.

    Columns: action_code  description  (empty)  language  flag
    The description is a hierarchical dot-separated path.
    """
    actions = {}
    reader, fh = _open_tab_reader(filepath)
    try:
        for row in reader:
            if not row or not row[0].strip():
                continue
            action_code = row[0].strip()
            description = row[1].strip() if len(row) > 1 else ""
            actions[action_code] = {
                "code": action_code,
                "description": description,
            }
    finally:
        fh.close()
    return actions


def parse_role_actions(filepath):
    """Parse RoleActions.txt — tab-delimited, no header.

    Columns: role_name  action_code  granted(0/1)  (trailing empty)
    Returns dict of role_name → set of granted action codes.
    """
    role_actions = defaultdict(set)
    reader, fh = _open_tab_reader(filepath)
    try:
        for row in reader:
            if len(row) < 3:
                continue
            role_name = row[0].strip()
            action_code = row[1].strip()
            granted = row[2].strip() == "1"
            if role_name and action_code and granted:
                role_actions[role_name].add(action_code)
    finally:
        fh.close()
    return dict(role_actions)


def parse_user_roles(filepath):
    """Parse UserRoles.txt — tab-delimited, no header.

    Columns: username  role_name  scope_code
    """
    user_roles = []
    reader, fh = _open_tab_reader(filepath)
    try:
        for row in reader:
            if len(row) < 2:
                continue
            username = row[0].strip()
            role_name = row[1].strip()
            if not username or not role_name:
                continue
            user_roles.append(
                {
                    "username": username,
                    "role_name": role_name,
                    "scope_code": row[2].strip() if len(row) > 2 else "",
                }
            )
    finally:
        fh.close()
    return user_roles


# ─── OAA Payload Builder ────────────────────────────────────────────────────


def build_oaa_payload(users, roles, scopes, actions, role_actions, user_roles, args):
    """Build the OAA CustomApplication from parsed GICO data."""

    app = CustomApplication(
        name=args.datasource_name,
        application_type=args.provider_name,
    )

    # ── Custom property definitions ──────────────────────────────────────
    app.property_definitions.define_local_user_property(
        "email", OAAPropertyType.STRING
    )
    app.property_definitions.define_local_user_property(
        "first_name", OAAPropertyType.STRING
    )
    app.property_definitions.define_local_user_property(
        "last_name", OAAPropertyType.STRING
    )
    app.property_definitions.define_local_user_property(
        "department", OAAPropertyType.STRING
    )
    app.property_definitions.define_local_user_property(
        "is_admin", OAAPropertyType.BOOLEAN
    )

    app.property_definitions.define_resource_property(
        "scope", "scope_code", OAAPropertyType.STRING
    )
    app.property_definitions.define_resource_property(
        "scope", "scope_name", OAAPropertyType.STRING
    )

    # ── Custom permissions (one per GICO action) ─────────────────────────
    log.info("Defining %d custom permissions from GICO actions...", len(actions))
    for action_code in sorted(actions.keys()):
        app.add_custom_permission(action_code, [OAAPermission.NonData])

    # ── Scope resources ──────────────────────────────────────────────────
    scope_resources = {}
    log.info("Adding %d scope resources...", len(scopes))
    for scope in scopes:
        code = scope["scope_code"]
        name = scope["scope_name"]
        display = f"{name} ({code})" if code else name
        uid = code if code else "default"
        resource = app.add_resource(
            name=display,
            resource_type="scope",
            unique_id=uid,
        )
        resource.set_property("scope_code", code)
        resource.set_property("scope_name", name)
        scope_resources[code] = resource
        log.debug("  Scope: %s (uid=%s)", display, uid)

    # ── Local roles with their granted actions ───────────────────────────
    log.info("Adding %d local roles...", len(roles))
    for role in roles:
        rname = role["role_name"]
        granted = list(role_actions.get(rname, set()))
        # Keep only actions that exist in our actions dictionary
        valid = [a for a in granted if a in actions]
        app.add_local_role(name=rname, unique_id=rname, permissions=valid)
        log.debug("  Role '%s': %d granted actions", rname, len(valid))

    # ── Local users ──────────────────────────────────────────────────────
    log.info("Adding %d local users...", len(users))
    for user in users:
        uname = user["username"]
        full_name = f"{user['first_name']} {user['last_name']}".strip()
        identities = [user["email"]] if user["email"] else []

        local_user = app.add_local_user(
            name=full_name or uname,
            unique_id=uname,
            identities=identities,
        )
        local_user.is_active = user["is_active"]

        if user["email"]:
            local_user.set_property("email", user["email"])
        if user["first_name"]:
            local_user.set_property("first_name", user["first_name"])
        if user["last_name"]:
            local_user.set_property("last_name", user["last_name"])
        if user["department"]:
            local_user.set_property("department", user["department"])
        local_user.set_property("is_admin", user["is_admin"])

    # ── User → Role → Scope assignments ──────────────────────────────────
    # Group by (username, role_name) → [scope_codes]
    user_role_scopes = defaultdict(list)
    for ur in user_roles:
        user_role_scopes[(ur["username"], ur["role_name"])].append(ur["scope_code"])

    log.info("Processing %d unique user-role assignments...", len(user_role_scopes))
    assignments_ok = 0
    assignments_skip = 0

    for (uname, rname), scope_codes in user_role_scopes.items():
        if uname not in app.local_users:
            log.warning(
                "User '%s' found in UserRoles but not in Users — skipping", uname
            )
            assignments_skip += 1
            continue
        if rname not in app.local_roles:
            log.warning(
                "Role '%s' found in UserRoles but not in Roles — skipping", rname
            )
            assignments_skip += 1
            continue

        resources = []
        for sc in scope_codes:
            if sc in scope_resources:
                resources.append(scope_resources[sc])
            else:
                log.warning(
                    "Scope code '%s' not in Scopes for user '%s' role '%s'",
                    sc,
                    uname,
                    rname,
                )

        if resources:
            app.local_users[uname].add_role(
                rname, resources=resources, apply_to_application=False
            )
            assignments_ok += 1
        else:
            # Role applies to the whole application (no specific scope)
            app.local_users[uname].add_role(
                rname, apply_to_application=True
            )
            assignments_ok += 1

    log.info(
        "Role assignments: %d created, %d skipped", assignments_ok, assignments_skip
    )

    return app


# ─── Veza Push ───────────────────────────────────────────────────────────────


def push_to_veza(
    veza_url, veza_api_key, provider_name, datasource_name, app, dry_run=False, save_json=False
):
    """Push the CustomApplication payload to Veza."""
    if dry_run:
        log.info("[DRY RUN] Payload built successfully — skipping Veza push")
        if save_json:
            _save_payload_json(app, datasource_name)
        return True

    try:
        veza_con = OAAClient(url=veza_url, api_key=veza_api_key)

        log.info("Getting or creating provider '%s'...", provider_name)
        provider = veza_con.get_provider(provider_name)
        if not provider:
            log.info("Creating new provider '%s'...", provider_name)
            provider = veza_con.create_provider(provider_name, "application")

        log.info("Pushing datasource '%s'...", datasource_name)
        response = veza_con.push_application(
            provider_name=provider_name,
            data_source_name=datasource_name,
            application_object=app,
            save_json=save_json,
        )

        if response.get("warnings"):
            for w in response["warnings"]:
                log.warning("Veza warning: %s", w)

        log.info("Successfully pushed to Veza")
        if response.get("id"):
            log.info("Data Source ID: %s", response["id"])
        return True

    except OAAClientError as e:
        log.error(
            "Veza push failed: %s — %s (HTTP %s)", e.error, e.message, e.status_code
        )
        if hasattr(e, "details"):
            for d in e.details:
                log.error("  Detail: %s", d)
        return False


def _save_payload_json(app, datasource_name):
    """Save the OAA payload to a local JSON file (for dry-run debugging)."""
    try:
        payload = app.get_payload()
        filename = f"{datasource_name.replace(' ', '_')}_payload.json"
        with open(filename, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, default=str)
        log.info("Payload saved to %s", filename)
    except Exception as exc:
        log.warning("Could not save payload JSON: %s", exc)


# ─── CLI & Main ──────────────────────────────────────────────────────────────


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="GICO to Veza OAA Integration — reads GICO export files and pushes to Veza",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --data-dir /path/to/gico/exports --dry-run
  %(prog)s --data-dir /mnt/gico-share/exports --env-file .env
  %(prog)s --data-dir ./samples --provider-name "GICO" --datasource-name "GICO DE Production"
  %(prog)s --data-dir ./samples --dry-run --save-json
        """,
    )

    parser.add_argument(
        "--data-dir",
        required=True,
        help="Directory containing GICO export files (Users.txt, Roles.txt, etc.)",
    )
    parser.add_argument(
        "--env-file",
        default=".env",
        help="Path to .env file (default: .env)",
    )
    parser.add_argument(
        "--veza-url",
        help="Veza instance URL (overrides VEZA_URL env var)",
    )
    parser.add_argument(
        "--veza-api-key",
        help="Veza API key (overrides VEZA_API_KEY env var)",
    )
    parser.add_argument(
        "--provider-name",
        default="GICO",
        help="Veza provider name (default: GICO)",
    )
    parser.add_argument(
        "--datasource-name",
        default="GICO",
        help="Veza datasource name — use a unique name per plant/environment (default: GICO)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Build OAA payload but skip Veza push",
    )
    parser.add_argument(
        "--save-json",
        action="store_true",
        help="Save OAA payload as JSON file for debugging",
    )
    parser.add_argument(
        "--log-level",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        default="INFO",
        help="Logging level (default: INFO)",
    )
    return parser.parse_args()


def load_config(args):
    """Load credentials with CLI → env var → .env file precedence."""
    if args.env_file and os.path.exists(args.env_file):
        load_dotenv(args.env_file)
    return {
        "veza_url": args.veza_url or os.getenv("VEZA_URL"),
        "veza_api_key": args.veza_api_key or os.getenv("VEZA_API_KEY"),
    }


def validate_data_dir(data_dir):
    """Ensure all required GICO export files are present."""
    if not os.path.isdir(data_dir):
        log.error("Data directory does not exist: %s", data_dir)
        sys.exit(1)

    missing = [f for f in EXPECTED_FILES if not os.path.isfile(os.path.join(data_dir, f))]
    if missing:
        log.error(
            "Missing required files in %s: %s", data_dir, ", ".join(missing)
        )
        sys.exit(1)


def main():
    args = parse_arguments()

    # ── Logging setup ────────────────────────────────────────────────────
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s  %(levelname)-8s  %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # ── Banner ───────────────────────────────────────────────────────────
    print("=" * 60)
    print("GICO to Veza OAA Integration")
    print(f"Data Directory:  {args.data_dir}")
    print(f"Provider:        {args.provider_name}")
    print(f"Datasource:      {args.datasource_name}")
    if args.dry_run:
        print("Mode:            DRY RUN")
    print("=" * 60)
    print()

    # ── Config & validation ──────────────────────────────────────────────
    config = load_config(args)

    if not args.dry_run:
        if not config["veza_url"] or not config["veza_api_key"]:
            log.error(
                "VEZA_URL and VEZA_API_KEY must be set (via CLI args, env vars, or .env file)"
            )
            sys.exit(1)

    validate_data_dir(args.data_dir)

    # ── Parse GICO export files ──────────────────────────────────────────
    data_dir = Path(args.data_dir)

    log.info("Parsing Users.txt...")
    users = parse_users(data_dir / "Users.txt")
    log.info("  Loaded %d users", len(users))

    log.info("Parsing Roles.txt...")
    roles = parse_roles(data_dir / "Roles.txt")
    log.info("  Loaded %d roles", len(roles))

    log.info("Parsing Scopes.txt...")
    scopes = parse_scopes(data_dir / "Scopes.txt")
    log.info("  Loaded %d scopes", len(scopes))

    log.info("Parsing Actions.txt...")
    actions = parse_actions(data_dir / "Actions.txt")
    log.info("  Loaded %d actions", len(actions))

    log.info("Parsing RoleActions.txt...")
    role_actions = parse_role_actions(data_dir / "RoleActions.txt")
    log.info("  Loaded action mappings for %d roles", len(role_actions))

    log.info("Parsing UserRoles.txt...")
    user_roles = parse_user_roles(data_dir / "UserRoles.txt")
    log.info("  Loaded %d user-role assignments", len(user_roles))

    # ── Build OAA payload ────────────────────────────────────────────────
    print()
    log.info("Building OAA payload...")
    app = build_oaa_payload(users, roles, scopes, actions, role_actions, user_roles, args)
    log.info(
        "Payload built: %d users, %d roles, %d scope resources, %d custom permissions",
        len(app.local_users),
        len(app.local_roles),
        len(app.resources),
        len(app.custom_permissions),
    )

    # ── Push to Veza ─────────────────────────────────────────────────────
    print()
    success = push_to_veza(
        config["veza_url"],
        config["veza_api_key"],
        args.provider_name,
        args.datasource_name,
        app,
        dry_run=args.dry_run,
        save_json=args.save_json,
    )

    if success:
        print()
        print("=" * 60)
        print("✓ GICO integration completed successfully")
        print("=" * 60)
        sys.exit(0)
    else:
        print()
        print("=" * 60)
        print("✗ GICO integration failed")
        print("=" * 60)
        sys.exit(1)


if __name__ == "__main__":
    main()
