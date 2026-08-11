#!/usr/bin/env python3
"""
cmdforge - A config-driven console form for generating AWS CLI / kubectl commands.

Designed to run in an AWS CloudShell / console terminal with zero external deps
(uses only the Python standard library, including curses).

Usage:
    python3 cmdforge.py [--config CONFIG.json] [--no-curses]

Controls (curses mode):
    Up/Down or j/k   move between fields
    Enter / Space    edit field / toggle / open select
    Tab              next field
    g                generate command(s)
    r                run last generated command (asks confirmation)
    q                quit
"""

import argparse
import json
import os
import shlex
import subprocess
import sys
import textwrap

# --------------------------------------------------------------------------- #
# Default configuration (written to disk if no config is supplied)
# --------------------------------------------------------------------------- #
DEFAULT_CONFIG = {
    "title": "CmdForge - AWS / kubectl Command Builder",
    "forms": [
        {
            "id": "nodegroup",
            "label": "Create EKS Node Group",
            "tool": "aws",
            "template": (
                "aws eks create-nodegroup "
                "--cluster-name {cluster_name} "
                "--nodegroup-name {nodegroup_name} "
                "--node-role {node_role} "
                "--subnets {subnets} "
                "--scaling-config minSize={min_size},maxSize={max_size},desiredSize={desired_size} "
                "--instance-types {instance_type} "
                "--ami-type {ami_type} "
                "--capacity-type {capacity_type}"
                "{labels_opt}{taints_opt}{region_opt}"
            ),
            "fields": [
                {"name": "cluster_name", "label": "Cluster name", "type": "text", "default": "my-cluster", "required": True},
                {"name": "nodegroup_name", "label": "Node group name", "type": "text", "default": "ng-1", "required": True},
                {"name": "node_role", "label": "Node IAM role ARN", "type": "text", "default": "arn:aws:iam::111122223333:role/EKSNodeRole", "required": True},
                {"name": "subnets", "label": "Subnet IDs (space-sep)", "type": "text", "default": "subnet-aaaa1111 subnet-bbbb2222"},
                {"name": "instance_type", "label": "Instance type", "type": "select", "options": ["t3.medium", "t3.large", "m5.large", "m5.xlarge", "c5.large"], "default": "t3.medium"},
                {"name": "ami_type", "label": "AMI type", "type": "select", "options": ["AL2_x86_64", "AL2_x86_64_GPU", "AL2_ARM_64", "BOTTLEROCKET_x86_64", "BOTTLEROCKET_ARM_64"], "default": "AL2_x86_64"},
                {"name": "capacity_type", "label": "Capacity type", "type": "select", "options": ["ON_DEMAND", "SPOT"], "default": "ON_DEMAND"},
                {"name": "min_size", "label": "Min size", "type": "number", "default": "1"},
                {"name": "desired_size", "label": "Desired size", "type": "number", "default": "2"},
                {"name": "max_size", "label": "Max size", "type": "number", "default": "3"},
                {"name": "labels", "label": "Labels (k=v,k=v)", "type": "text", "default": ""},
                {"name": "taints", "label": "Taints (key=value:Effect, ...)", "type": "text", "default": ""},
                {"name": "region", "label": "Region (blank=default)", "type": "text", "default": ""}
            ],
            "transforms": {
                "labels_opt": {"from": "labels", "kv_to": " --labels {kv}", "empty": ""},
                "taints_opt": {"from": "taints", "taints_to": " --taints {taints}", "empty": ""},
                "region_opt": {"from": "region", "prefix": " --region ", "empty": ""}
            }
        },
        {
            "id": "taint",
            "label": "Apply Taint to Nodes (kubectl)",
            "tool": "kubectl",
            "template": "kubectl taint nodes {node_selector} {key}={value}:{effect}{overwrite_opt}",
            "fields": [
                {"name": "node_selector", "label": "Node name or -l selector", "type": "text", "default": "-l role=worker", "required": True},
                {"name": "key", "label": "Taint key", "type": "text", "default": "dedicated", "required": True},
                {"name": "value", "label": "Taint value", "type": "text", "default": "gpu"},
                {"name": "effect", "label": "Effect", "type": "select", "options": ["NoSchedule", "PreferNoSchedule", "NoExecute"], "default": "NoSchedule"},
                {"name": "overwrite", "label": "Overwrite existing?", "type": "bool", "default": False}
            ],
            "transforms": {
                "overwrite_opt": {"from": "overwrite", "true": " --overwrite", "false": ""}
            }
        },
        {
            "id": "subnet",
            "label": "Create VPC Subnet",
            "tool": "aws",
            "template": (
                "aws ec2 create-subnet "
                "--vpc-id {vpc_id} "
                "--cidr-block {cidr} "
                "--availability-zone {az}"
                "{tags_opt}{region_opt}"
            ),
            "fields": [
                {"name": "vpc_id", "label": "VPC ID", "type": "text", "default": "vpc-0123456789", "required": True},
                {"name": "cidr", "label": "CIDR block", "type": "text", "default": "10.0.1.0/24", "required": True},
                {"name": "az", "label": "Availability zone", "type": "text", "default": "us-east-1a", "required": True},
                {"name": "name_tag", "label": "Name tag", "type": "text", "default": "eks-subnet"},
                {"name": "region", "label": "Region (blank=default)", "type": "text", "default": ""}
            ],
            "transforms": {
                "tags_opt": {"from": "name_tag", "prefix": " --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=", "suffix": "}]'", "empty": ""},
                "region_opt": {"from": "region", "prefix": " --region ", "empty": ""}
            }
        },
        {
            "id": "nacl",
            "label": "Add Network ACL Entry",
            "tool": "aws",
            "template": (
                "aws ec2 create-network-acl-entry "
                "--network-acl-id {nacl_id} "
                "--rule-number {rule_number} "
                "--protocol {protocol} "
                "--rule-action {rule_action} "
                "--egress {egress} "
                "--cidr-block {cidr} "
                "--port-range From={from_port},To={to_port}"
                "{region_opt}"
            ),
            "fields": [
                {"name": "nacl_id", "label": "Network ACL ID", "type": "text", "default": "acl-0123456789", "required": True},
                {"name": "rule_number", "label": "Rule number", "type": "number", "default": "100", "required": True},
                {"name": "protocol", "label": "Protocol (6=tcp,17=udp,-1=all)", "type": "select", "options": ["6", "17", "1", "-1"], "default": "6"},
                {"name": "rule_action", "label": "Action", "type": "select", "options": ["allow", "deny"], "default": "allow"},
                {"name": "egress", "label": "Direction", "type": "select", "options": ["false", "true"], "default": "false"},
                {"name": "cidr", "label": "CIDR block", "type": "text", "default": "0.0.0.0/0", "required": True},
                {"name": "from_port", "label": "From port", "type": "number", "default": "443"},
                {"name": "to_port", "label": "To port", "type": "number", "default": "443"},
                {"name": "region", "label": "Region (blank=default)", "type": "text", "default": ""}
            ],
            "transforms": {
                "region_opt": {"from": "region", "prefix": " --region ", "empty": ""}
            }
        },
        {
            "id": "cert",
            "label": "Import ACM Certificate",
            "tool": "aws",
            "template": (
                "aws acm import-certificate "
                "--certificate fileb://{cert_path} "
                "--private-key fileb://{key_path}"
                "{chain_opt}{region_opt}"
            ),
            "fields": [
                {"name": "cert_path", "label": "Certificate file path", "type": "text", "default": "./cert.pem", "required": True},
                {"name": "key_path", "label": "Private key file path", "type": "text", "default": "./key.pem", "required": True},
                {"name": "chain_path", "label": "Chain file path (optional)", "type": "text", "default": ""},
                {"name": "region", "label": "Region (blank=default)", "type": "text", "default": ""}
            ],
            "transforms": {
                "chain_opt": {"from": "chain_path", "prefix": " --certificate-chain fileb://", "empty": ""},
                "region_opt": {"from": "region", "prefix": " --region ", "empty": ""}
            }
        },
        {
            "id": "role",
            "label": "Create IAM Role",
            "tool": "aws",
            "template": (
                "aws iam create-role "
                "--role-name {role_name} "
                "--assume-role-policy-document file://{trust_policy_path}"
                "{desc_opt}"
            ),
            "fields": [
                {"name": "role_name", "label": "Role name", "type": "text", "default": "EKSNodeRole", "required": True},
                {"name": "trust_policy_path", "label": "Trust policy JSON path", "type": "text", "default": "./trust-policy.json", "required": True},
                {"name": "description", "label": "Description", "type": "text", "default": ""}
            ],
            "transforms": {
                "desc_opt": {"from": "description", "prefix": " --description ", "quote": True, "empty": ""}
            }
        }
    ]
}


# --------------------------------------------------------------------------- #
# Command generation logic (pure, testable, no curses)
# --------------------------------------------------------------------------- #
def _parse_kv(s):
    """'k=v,k2=v2' -> 'k=v,k2=v2' validated; returns cleaned string or ''."""
    pairs = [p.strip() for p in s.split(",") if p.strip()]
    return ",".join(pairs)


def _apply_transform(name, spec, values):
    src = values.get(spec["from"], "")
    if isinstance(src, bool):
        return spec.get("true" if src else "false", "")
    src = str(src).strip()
    if src == "":
        return spec.get("empty", "")
    if "kv_to" in spec:
        return spec["kv_to"].format(kv=_parse_kv(src))
    if "taints_to" in spec:
        return spec["taints_to"].format(taints=src)
    prefix = spec.get("prefix", "")
    suffix = spec.get("suffix", "")
    if spec.get("quote"):
        src = shlex.quote(src)
    return f"{prefix}{src}{suffix}"


def generate_command(form, values):
    """Return (command_string, errors_list)."""
    errors = []
    for f in form["fields"]:
        if f.get("required") and not str(values.get(f["name"], "")).strip():
            errors.append(f"'{f['label']}' is required")

    ctx = dict(values)
    for tname, tspec in form.get("transforms", {}).items():
        ctx[tname] = _apply_transform(tname, tspec, values)

    try:
        cmd = form["template"].format(**ctx)
    except KeyError as e:
        errors.append(f"Template references missing field {e}")
        return "", errors

    # Collapse accidental double spaces from optional blocks
    cmd = " ".join(cmd.split())
    return cmd, errors


def default_values(form):
    vals = {}
    for f in form["fields"]:
        vals[f["name"]] = f.get("default", False if f["type"] == "bool" else "")
    return vals


# --------------------------------------------------------------------------- #
# Curses-based interactive form
# --------------------------------------------------------------------------- #
def run_curses(config):
    import curses

    def _main(stdscr):
        curses.curs_set(0)
        curses.use_default_colors()
        try:
            curses.init_pair(1, curses.COLOR_CYAN, -1)
            curses.init_pair(2, curses.COLOR_GREEN, -1)
            curses.init_pair(3, curses.COLOR_YELLOW, -1)
            curses.init_pair(4, curses.COLOR_RED, -1)
        except curses.error:
            pass

        forms = config["forms"]
        form_idx = pick_form(stdscr, forms, config.get("title", "CmdForge"))
        if form_idx is None:
            return
        form = forms[form_idx]
        values = default_values(form)
        cursor = 0
        last_cmd = ""
        message = "Up/Down move - Enter edit - g generate - b back - q quit"

        while True:
            stdscr.erase()
            h, w = stdscr.getmaxyx()
            _addstr(stdscr, 0, 0, f" {form['label']}  [{form['tool']}] ", curses.A_REVERSE)
            for i, f in enumerate(form["fields"]):
                y = 2 + i
                if y >= h - 6:
                    break
                marker = ">" if i == cursor else " "
                val = values[f["name"]]
                shown = "[x]" if (f["type"] == "bool" and val) else ("[ ]" if f["type"] == "bool" else str(val))
                req = "*" if f.get("required") else " "
                attr = curses.A_BOLD if i == cursor else curses.A_NORMAL
                label = f"{marker}{req}{f['label']:<28}"
                _addstr(stdscr, y, 0, label, attr | _cp(1))
                _addstr(stdscr, y, 31, shown[: max(0, w - 32)], attr)

            cy = h - 4
            if last_cmd:
                _addstr(stdscr, cy - 1, 0, "Generated:", _cp(2) | curses.A_BOLD)
                for j, line in enumerate(textwrap.wrap(last_cmd, max(10, w - 1))[:2]):
                    _addstr(stdscr, cy + j, 0, line, _cp(2))
            _addstr(stdscr, h - 1, 0, message[: w - 1], _cp(3))
            stdscr.refresh()

            key = stdscr.getch()
            if key in (ord("q"),):
                return
            elif key in (ord("b"),):
                form_idx = pick_form(stdscr, forms, config.get("title", "CmdForge"))
                if form_idx is None:
                    return
                form = forms[form_idx]
                values = default_values(form)
                cursor, last_cmd = 0, ""
            elif key in (curses.KEY_UP, ord("k")):
                cursor = (cursor - 1) % len(form["fields"])
            elif key in (curses.KEY_DOWN, ord("j"), ord("\t")):
                cursor = (cursor + 1) % len(form["fields"])
            elif key in (curses.KEY_ENTER, 10, 13, ord(" ")):
                f = form["fields"][cursor]
                if f["type"] == "bool":
                    values[f["name"]] = not values[f["name"]]
                elif f["type"] == "select":
                    values[f["name"]] = pick_option(stdscr, f, values[f["name"]])
                else:
                    values[f["name"]] = edit_text(stdscr, f, str(values[f["name"]]))
            elif key == ord("g"):
                cmd, errs = generate_command(form, values)
                if errs:
                    message = "ERROR: " + "; ".join(errs)
                else:
                    last_cmd = cmd
                    message = "Generated. Press 'r' to run, 'w' to save to file."
            elif key == ord("r") and last_cmd:
                run_command_curses(stdscr, last_cmd)
                message = "Returned from run. 'g' regenerate - 'q' quit"
            elif key == ord("w") and last_cmd:
                path = edit_text(stdscr, {"label": "Save command to file"}, "command.sh")
                if path:
                    with open(path, "w") as fh:
                        fh.write("#!/bin/sh\n" + last_cmd + "\n")
                    os.chmod(path, 0o755)
                    message = f"Saved to {path}"

    def _cp(n):
        try:
            return curses.color_pair(n)
        except curses.error:
            return 0

    def _addstr(scr, y, x, s, attr=0):
        try:
            scr.addstr(y, x, s, attr)
        except curses.error:
            pass

    def pick_form(scr, forms, title):
        idx = 0
        while True:
            scr.erase()
            h, w = scr.getmaxyx()
            _addstr(scr, 0, 0, f" {title} ", curses.A_REVERSE)
            _addstr(scr, 1, 0, "Select a command to build:", _cp(1))
            for i, f in enumerate(forms):
                marker = ">" if i == idx else " "
                attr = curses.A_BOLD if i == idx else curses.A_NORMAL
                _addstr(scr, 3 + i, 0, f"{marker} {f['label']}  [{f['tool']}]", attr)
            _addstr(scr, h - 1, 0, "Up/Down - Enter select - q quit", _cp(3))
            scr.refresh()
            key = scr.getch()
            if key in (ord("q"),):
                return None
            elif key in (curses.KEY_UP, ord("k")):
                idx = (idx - 1) % len(forms)
            elif key in (curses.KEY_DOWN, ord("j")):
                idx = (idx + 1) % len(forms)
            elif key in (curses.KEY_ENTER, 10, 13, ord(" ")):
                return idx

    def pick_option(scr, field, current):
        opts = field["options"]
        idx = opts.index(current) if current in opts else 0
        while True:
            scr.erase()
            _addstr(scr, 0, 0, f" Select: {field['label']} ", curses.A_REVERSE)
            for i, o in enumerate(opts):
                marker = ">" if i == idx else " "
                attr = curses.A_BOLD if i == idx else curses.A_NORMAL
                _addstr(scr, 2 + i, 0, f"{marker} {o}", attr)
            scr.refresh()
            key = scr.getch()
            if key in (curses.KEY_UP, ord("k")):
                idx = (idx - 1) % len(opts)
            elif key in (curses.KEY_DOWN, ord("j")):
                idx = (idx + 1) % len(opts)
            elif key in (curses.KEY_ENTER, 10, 13, ord(" ")):
                return opts[idx]
            elif key in (27,):
                return current

    def edit_text(scr, field, current):
        curses.curs_set(1)
        curses.echo()
        buf = current
        while True:
            scr.erase()
            _addstr(scr, 0, 0, f" Edit: {field['label']} ", curses.A_REVERSE)
            _addstr(scr, 2, 0, "Value (Enter=accept, ESC=cancel):")
            _addstr(scr, 3, 0, buf)
            scr.move(3, len(buf))
            scr.refresh()
            key = scr.getch()
            if key in (27,):
                buf = current
                break
            elif key in (curses.KEY_ENTER, 10, 13):
                break
            elif key in (curses.KEY_BACKSPACE, 127, 8):
                buf = buf[:-1]
            elif 32 <= key <= 126:
                buf += chr(key)
        curses.noecho()
        curses.curs_set(0)
        return buf

    def run_command_curses(scr, cmd):
        curses.endwin()
        print("\n" + "=" * 60)
        print("About to run:")
        print("  " + cmd)
        print("=" * 60)
        ans = input("Run this command? [y/N] ").strip().lower()
        if ans == "y":
            subprocess.run(cmd, shell=True)
        input("\nPress Enter to return to the form...")

    curses.wrapper(_main)


# --------------------------------------------------------------------------- #
# Plain-text fallback (no curses; works over any pipe / minimal terminal)
# --------------------------------------------------------------------------- #
def run_plain(config):
    forms = config["forms"]
    print(config.get("title", "CmdForge"))
    while True:
        print("\nSelect a command to build:")
        for i, f in enumerate(forms):
            print(f"  {i+1}. {f['label']}  [{f['tool']}]")
        print("  q. quit")
        choice = input("> ").strip().lower()
        if choice == "q":
            return
        if not choice.isdigit() or not (1 <= int(choice) <= len(forms)):
            print("Invalid choice.")
            continue
        form = forms[int(choice) - 1]
        values = default_values(form)

        for f in form["fields"]:
            label = f["label"] + ("*" if f.get("required") else "")
            if f["type"] == "bool":
                d = "y" if values[f["name"]] else "n"
                ans = input(f"{label} [y/n] ({d}): ").strip().lower()
                if ans:
                    values[f["name"]] = ans.startswith("y")
            elif f["type"] == "select":
                print(f"{label} options: {', '.join(f['options'])}")
                while True:
                    ans = input(f"  ({values[f['name']]}): ").strip()
                    if not ans:
                        break
                    if ans in f["options"]:
                        values[f["name"]] = ans
                        break
                    print(f"  Invalid; choose one of: {', '.join(f['options'])}")
            else:
                ans = input(f"{label} ({values[f['name']]}): ").strip()
                if ans:
                    values[f["name"]] = ans

        cmd, errs = generate_command(form, values)
        if errs:
            print("\nERRORS:")
            for e in errs:
                print("  - " + e)
            continue
        print("\nGenerated command:\n")
        print("  " + cmd + "\n")
        action = input("[r]un, [w]rite to file, [Enter] menu: ").strip().lower()
        if action == "r":
            if input("Confirm run? [y/N] ").strip().lower() == "y":
                subprocess.run(cmd, shell=True)
        elif action == "w":
            path = input("File path (command.sh): ").strip() or "command.sh"
            with open(path, "w") as fh:
                fh.write("#!/bin/sh\n" + cmd + "\n")
            os.chmod(path, 0o755)
            print(f"Saved to {path}")


# --------------------------------------------------------------------------- #
# Entry point
# --------------------------------------------------------------------------- #
def load_config(path):
    if path and os.path.exists(path):
        with open(path) as fh:
            return json.load(fh)
    if path:
        # Path given but missing: write the default there for the user to edit.
        with open(path, "w") as fh:
            json.dump(DEFAULT_CONFIG, fh, indent=2)
        print(f"Config not found; wrote default to {path}")
    return DEFAULT_CONFIG


def main():
    ap = argparse.ArgumentParser(description="Config-driven AWS/kubectl command form.")
    ap.add_argument("--config", help="Path to JSON config (created if missing).")
    ap.add_argument("--no-curses", action="store_true", help="Use plain text mode.")
    ap.add_argument("--dump-config", action="store_true", help="Print default config and exit.")
    args = ap.parse_args()

    if args.dump_config:
        print(json.dumps(DEFAULT_CONFIG, indent=2))
        return

    config = load_config(args.config)

    use_curses = not args.no_curses and sys.stdin.isatty() and sys.stdout.isatty()
    if use_curses:
        try:
            run_curses(config)
            return
        except Exception as e:  # fall back gracefully on any curses issue
            print(f"(curses unavailable: {e}; falling back to plain mode)")
    run_plain(config)


if __name__ == "__main__":
    main()
