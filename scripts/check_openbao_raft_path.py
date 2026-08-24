#!/usr/bin/env python3
"""Assert the OpenBao Raft storage path stays in lock-step with the PVC mount.

The OpenBao Helm chart mounts server.dataStorage at /openbao/data by default
and renders server.ha.raft.config (NOT server.ha.config) when
server.ha.raft.enabled=true. This check fails if the values file drifts the
Raft path away from the PVC mount, or if someone re-introduces the dead
server.ha.config block (which the chart ignores in Raft mode).

When helm is on PATH and the chart repo is reachable, the check performs a
real chart render against the chart version/URL pinned in the repo and
asserts the rendered StatefulSet data-volume mount path equals the rendered
configmap Raft path. Without helm it falls back to validating the values file
directly (stdlib only), so CI with just Python still catches drift.

Optional argv[1]: repository root (defaults to repo root of this file).
"""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

MOUNT_PATH = "/openbao/data"
CHART_VER_RE = re.compile(r"version:\s*[\"']?([0-9][^\"'\s]*)[\"']?")
CHART_URL_RE = re.compile(r"url:\s*([^\s]+)")
VALUES_REL = pathlib.Path("kubernetes/clusters/homelab/platform/openbao/release/values.yaml")


def repo_root(argv):
    root = pathlib.Path(argv[1]) if len(argv) > 1 else pathlib.Path(__file__).resolve().parent.parent
    values = root / VALUES_REL
    if not values.is_file():
        raise SystemExit("FAIL: %s not found; run from repo root or pass root as argv[1]" % values)
    return root, values


def block_value(lines, start_idx, indent):
    """Return the literal-block value (config: |) lines starting at start_idx.

    The value lines are those more indented than the key line, stripped of
    their common indentation. Blank lines and comment lines within the block
    are preserved (comments only count as block content when indented deeper
    than the key). Returns (list_of_lines, end_idx).
    """
    out = []
    i = start_idx
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            out.append("")
            i += 1
            continue
        cur_indent = len(line) - len(line.lstrip())
        if cur_indent <= indent:
            break
        out.append(line[indent + 1:] if len(line) > indent else "")
        i += 1
    return out, i


def find_block(lines, key_re, from_idx=0):
    """Find first line matching key_re at any indentation; return (idx, indent)."""
    for i in range(from_idx, len(lines)):
        m = key_re.match(lines[i])
        if m:
            return i, len(lines[i]) - len(lines[i].lstrip())
    return None, None


def parse_values(text):
    """Return (raft_path, has_raft_config, has_dead_ha_config, mount_path)."""
    lines = text.splitlines()
    raft_path = None
    has_raft_config = False
    has_dead_ha_config = False
    mount_path = MOUNT_PATH  # chart default

    # 1) server.ha.raft.config (the block the chart renders for Raft).
    ha_idx, ha_indent = find_block(lines, re.compile(r"\s*ha:"))
    if ha_idx is not None:
        raft_idx, _ = find_block(lines, re.compile(r"\s*raft:"), ha_idx + 1)
        if raft_idx is not None:
            cfg_idx, _ = find_block(
                lines, re.compile(r"\s*config:\s*\|"), raft_idx + 1)
            if cfg_idx is not None:
                has_raft_config = True
                val_lines, _ = block_value(lines, cfg_idx + 1,
                                           len(lines[cfg_idx]) - len(lines[cfg_idx].lstrip()))
                for vl in val_lines:
                    pm = re.match(r"\s*path\s*=\s*\"([^\"]+)\"", vl)
                    if pm:
                        raft_path = pm.group(1)
                        break
            # A dead server.ha.config sits at the ha: children level (indent
            # ha_indent+2) but NOT nested under raft: (which is itself at
            # ha_indent+2). The chart ignores server.ha.config entirely when
            # server.ha.raft.enabled=true, so its presence is drift.
            raft_end = len(lines)
            for i in range(raft_idx + 1, len(lines)):
                line = lines[i]
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                cur_indent = len(line) - len(line.lstrip())
                if cur_indent <= len(lines[raft_idx]) - len(lines[raft_idx].lstrip()):
                    raft_end = i
                    break
            for i in range(ha_idx + 1, raft_end):
                line = lines[i]
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                cur_indent = len(line) - len(line.lstrip())
                if (re.match(r"\s*config:\s*\|", line)
                        and cur_indent == ha_indent + 2):
                    has_dead_ha_config = True
                    break

    # 2) dataStorage.mountPath override (chart default is /openbao/data).
    ds_idx, _ = find_block(lines, re.compile(r"\s*dataStorage:"))
    if ds_idx is not None:
        ds_indent = len(lines[ds_idx]) - len(lines[ds_idx].lstrip())
        for i in range(ds_idx + 1, len(lines)):
            line = lines[i]
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cur_indent = len(line) - len(line.lstrip())
            if cur_indent <= ds_indent:
                break
            m = re.match(r"\s*mountPath:\s*(.+)", line)
            if m:
                mount_path = m.group(1).strip().strip("\"'")
                break

    return raft_path, has_raft_config, has_dead_ha_config, mount_path


def helm_render_check(root, values_path):
    helm = shutil.which("helm")
    if not helm:
        return None
    hr = root / "kubernetes/clusters/homelab/platform/openbao/release/helmrelease.yaml"
    rep = root / "kubernetes/clusters/homelab/platform/openbao/release/helmrepository.yaml"
    if not (hr.is_file() and rep.is_file()):
        return None
    hr_text, rep_text = hr.read_text(), rep.read_text()
    vm = CHART_VER_RE.search(hr_text)
    um = CHART_URL_RE.search(rep_text)
    if not (vm and um):
        return None
    version, chart_url = vm.group(1), um.group(1)
    repo_name = "openbao-check"
    with tempfile.TemporaryDirectory(prefix="openbao-raft-check-") as td:
        td = pathlib.Path(td)
        env = dict(os.environ)
        env["HELM_REPOSITORY_CONFIG"] = str(td / "repos.yaml")
        env["HELM_REPOSITORY_CACHE"] = str(td / "cache")
        try:
            subprocess.run(
                [helm, "repo", "add", repo_name, chart_url, "--force-update"],
                check=True, capture_output=True, env=env, timeout=120,
            )
            subprocess.run(
                [helm, "pull", "%s/openbao" % repo_name, "--version", version,
                 "--destination", str(td)],
                check=True, capture_output=True, env=env, timeout=180,
            )
            out = subprocess.run(
                [helm, "template", "openbao", "%s/openbao" % repo_name,
                 "--version", version, "--namespace", "openbao",
                 "--values", str(values_path)],
                check=True, capture_output=True, env=env, timeout=180,
                text=True,
            ).stdout
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            return ("helm-render-error", str(e))
    ss = re.search(r"kind: StatefulSet(.*?)(?=\n---|\Z)", out, re.S)
    cm = re.search(r"kind: ConfigMap(.*?)(?=\n---|\Z)", out, re.S)
    if not (ss and cm):
        return ("helm-render-error", "StatefulSet/ConfigMap not found in render")
    mount = re.search(r"mountPath: (%s)" % re.escape(MOUNT_PATH), ss.group(1))
    raft = re.search(r'storage "raft"\s*\{[^}]*?path\s*=\s*"([^"]+)"', cm.group(1), re.S)
    if not mount:
        return ("mismatch", "data PVC mountPath != %s in rendered StatefulSet" % MOUNT_PATH)
    if not raft or raft.group(1) != MOUNT_PATH:
        got = raft.group(1) if raft else "<none>"
        return ("mismatch", "rendered raft path %s != data mount %s" % (got, MOUNT_PATH))
    return ("ok", "rendered raft path %s == data PVC mount %s" % (MOUNT_PATH, MOUNT_PATH))


def main():
    root, values = repo_root(sys.argv)
    text = values.read_text()
    failures = []

    raft_path, has_raft_config, has_dead_ha_config, mount_path = parse_values(text)
    if not has_raft_config:
        failures.append(
            "server.ha.raft.config block is missing; the chart renders this "
            "block (not server.ha.config) when server.ha.raft.enabled=true")
    elif raft_path != mount_path:
        failures.append(
            "server.ha.raft.config storage path %r != dataStorage.mountPath %r"
            % (raft_path, mount_path))
    if has_dead_ha_config:
        failures.append(
            "server.ha.config is set but ignored by the chart when "
            "server.ha.raft.enabled=true; move the block under raft.config")

    helm = helm_render_check(root, values)
    if helm:
        status, msg = helm
        if status == "mismatch":
            failures.append(msg)
        elif status == "helm-render-error":
            failures.append("helm render check failed: %s" % msg)

    for f in failures:
        print("FAIL:", f)
    if not failures:
        print("OK: OpenBao raft path %s is backed by the data PVC mount" % MOUNT_PATH)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
