#!/usr/bin/env python3
"""Nagios/Naemon check for the SeaweedFS cluster.

The old check called ``Topology.Free`` "storage capacity".  That number is
free *volume-file slots* (``Max - Volumes``), not free bytes: a 300 GiB volume
server with 1 GiB volumes can have only 9 free slots while 90 GiB of disk is
still free.  This check reports both, and also the conditions that were
invisible during the 2026-10-30 incident:

  * read-only volumes (4.51 marks a volume read-only when .idx/.dat disagree)
  * under-replicated volumes (fewer copies than ReplicaPlacement requires)
  * component readiness (masters, volumes, filers, admin)
  * Seaweed.status.ready
  * VolumeClaimTemplates drift between the Seaweed CR and the live StatefulSet

Exit codes follow Nagios: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN.
"""

import argparse
import json
import shlex
import subprocess
import sys
from collections import defaultdict

OK, WARNING, CRITICAL, UNKNOWN = 0, 1, 2, 3
STATUS_NAME = {OK: "OK", WARNING: "WARNING", CRITICAL: "CRITICAL", UNKNOWN: "UNKNOWN"}
SEVERITY = {CRITICAL: 2, WARNING: 1, UNKNOWN: 0, OK: 0}


def run_command(cmd, timeout):
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def kubectl_json(args, timeout):
    """Run `kubectl ARGS -o json` and return the parsed object."""
    cmd = ["kubectl"] + args + ["-o", "json", "--request-timeout=10s"]
    res = run_command(cmd, timeout)
    if res.returncode != 0:
        message = (res.stderr or res.stdout or "").strip().splitlines()
        raise RuntimeError(message[-1] if message else f"kubectl exited {res.returncode}")
    try:
        return json.loads(res.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"kubectl returned invalid JSON: {exc}") from exc


def kubectl_exec_json(pod, namespace, url, timeout):
    """Curl a URL from inside a master pod and parse the JSON response."""
    command = f"curl -sS --max-time 8 {shlex.quote(url)}"
    cmd = ["kubectl", "exec", "-n", namespace, pod, "--", "sh", "-c", command]
    res = run_command(cmd, timeout)
    if res.returncode != 0:
        message = (res.stderr or res.stdout or "").strip().splitlines()
        raise RuntimeError(message[-1] if message else f"kubectl exec exited {res.returncode}")
    try:
        return json.loads(res.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid JSON from {url}: {exc}") from exc


def summarize_pods(pods_json):
    """Return component -> {total, ready, names:[ready names]}."""
    components = {}
    for item in pods_json.get("items", []):
        labels = item.get("metadata", {}).get("labels", {}) or {}
        component = labels.get("app.kubernetes.io/component", "")
        if not component:
            continue
        name = item.get("metadata", {}).get("name", "")
        conditions = item.get("status", {}).get("conditions", []) or []
        ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions)
        entry = components.setdefault(component, {"total": 0, "ready": 0, "names": []})
        entry["total"] += 1
        if ready:
            entry["ready"] += 1
            entry["names"].append(name)
    return components


def collect(args, kubectl_json_fn=kubectl_json, kubectl_exec_fn=kubectl_exec_json):
    """Collect the live state. Raises on a fatal collection error."""
    data = {
        "errors": [],
        "pods": {},
        "volume_statuses": [],
        "cluster": None,
        "dir": None,
        "seaweed": None,
        "volume_sts": None,
        "filer_sts": None,
        "master_pod_used": None,
    }

    try:
        pods = kubectl_json_fn(
            ["get", "pods", "-n", args.namespace, "-l", "app.kubernetes.io/name=seaweedfs"],
            args.timeout,
        )
        data["pods"] = summarize_pods(pods)
    except Exception as exc:  # noqa: BLE001 - surfaced in the check output
        data["errors"].append(f"pod status: {exc}")

    master_candidates = list(data["pods"].get("master", {}).get("names", []))
    for name in args.master_pod.split(","):
        name = name.strip()
        if name and name not in master_candidates:
            master_candidates.append(name)

    last_error = None
    for pod in master_candidates:
        try:
            data["cluster"] = kubectl_exec_fn(
                pod, args.namespace, "http://localhost:9333/cluster/status", args.timeout
            )
            data["dir"] = kubectl_exec_fn(
                pod, args.namespace, "http://localhost:9333/dir/status", args.timeout
            )
            data["master_pod_used"] = pod
            break
        except Exception as exc:  # noqa: BLE001 - try the next master
            last_error = exc
    if data["dir"] is None:
        raise RuntimeError(f"cannot query the SeaweedFS master: {last_error}")

    urls = []
    for dc in data["dir"].get("Topology", {}).get("DataCenters", []) or []:
        for rack in dc.get("Racks", []) or []:
            for node in rack.get("DataNodes", []) or []:
                url = node.get("Url")
                if url and url not in urls:
                    urls.append(url)

    for url in urls:
        try:
            status = kubectl_exec_fn(
                data["master_pod_used"], args.namespace, f"http://{url}/status", args.timeout
            )
            data["volume_statuses"].append({"url": url, "status": status})
        except Exception as exc:  # noqa: BLE001 - one dead volume server is critical
            data["errors"].append(f"volume server {url}: {exc}")

    try:
        data["seaweed"] = kubectl_json_fn(
            ["get", "seaweed.seaweed.seaweedfs.com", args.seaweed_name, "-n", args.namespace],
            args.timeout,
        )
    except Exception as exc:  # noqa: BLE001 - optional context
        data["errors"].append(f"Seaweed CR: {exc}")

    for comp in ("volume", "filer"):
        try:
            data[f"{comp}_sts"] = kubectl_json_fn(
                ["get", "statefulset", f"{args.seaweed_name}-{comp}", "-n", args.namespace],
                args.timeout,
            )
        except Exception as exc:  # noqa: BLE001 - optional context
            data["errors"].append(f"{comp} StatefulSet: {exc}")

    return data


def _replica_expected(replica_placement):
    rp = replica_placement or {}
    return 1 + sum(int(rp.get(key, 0) or 0) for key in ("dataCenter", "rack", "node"))


def _free_percent(free_slots, max_slots):
    if not max_slots:
        return 0.0
    return free_slots / max_slots * 100.0


def _pct(count, total):
    return (count / total * 100.0) if total else 0.0


def _vct_differences(data):
    """Return human-readable VolumeClaimTemplates drift messages."""
    diffs = []
    seaweed = data.get("seaweed") or {}
    spec = seaweed.get("spec", {}) or {}

    volume_sts = data.get("volume_sts") or {}
    desired_volume = spec.get("volume", {}) or {}
    desired_storage = (desired_volume.get("requests") or {}).get("storage")
    desired_sc = desired_volume.get("storageClassName")
    vcts = (volume_sts.get("spec", {}) or {}).get("volumeClaimTemplates", []) or []
    if vcts:
        live = vcts[0].get("spec", {}) or {}
        live_storage = (live.get("resources", {}).get("requests") or {}).get("storage")
        live_sc = live.get("storageClassName")
        if desired_storage and live_storage and live_storage != desired_storage:
            diffs.append(
                f"volume StatefulSet storage {live_storage} != Seaweed CR {desired_storage}"
            )
        if desired_sc and live_sc and live_sc != desired_sc:
            diffs.append(
                f"volume StatefulSet storageClassName {live_sc} != Seaweed CR {desired_sc}"
            )

    filer_sts = data.get("filer_sts") or {}
    desired_filer_persistence = bool(
        ((spec.get("filer", {}) or {}).get("persistence", {}) or {}).get("enabled", False)
    )
    filer_vcts = (filer_sts.get("spec", {}) or {}).get("volumeClaimTemplates", []) or []
    if not desired_filer_persistence and filer_vcts:
        diffs.append(
            f"filer StatefulSet has {len(filer_vcts)} PVC template(s) but Seaweed CR has persistence disabled"
        )
    if desired_filer_persistence and not filer_vcts:
        diffs.append(
            "filer StatefulSet has no PVC template but Seaweed CR has persistence enabled"
        )
    return diffs


def evaluate(data, args):
    """Evaluate collected data. Returns (exit_code, summary, details, perfdata)."""
    critical = []
    warning = []
    details = []

    if data.get("dir") is None:
        return (
            CRITICAL,
            "CRITICAL: cannot query the SeaweedFS master",
            [str(e) for e in data.get("errors", [])],
            "",
        )

    cluster = data.get("cluster") or {}
    topology = data.get("dir", {}).get("Topology", {}) or {}
    free_slots = int(topology.get("Free", 0) or 0)
    max_slots = int(topology.get("Max", 0) or 0)
    free_pct = _free_percent(free_slots, max_slots)
    leader = cluster.get("Leader") or ""

    pods = data.get("pods", {}) or {}
    expected = {
        "master": args.masters_expected,
        "volume": args.volumes_expected,
        "filer": args.filers_expected,
        "admin": args.admin_expected,
    }
    pod_summary = {}
    for component, want in expected.items():
        got = pods.get(component, {"total": 0, "ready": 0})
        pod_summary[component] = got
        if want <= 0:
            continue
        if got["ready"] < want:
            reason = f"{component} {got['ready']}/{want} ready"
            if component in ("master", "volume") and got["ready"] < 2:
                critical.append(reason)
            else:
                warning.append(reason)

    if not leader:
        critical.append("no Raft leader")

    if data.get("errors"):
        for err in data["errors"]:
            # A dead volume server is a data-availability problem; optional
            # context failures are warnings.
            if err.startswith("volume server"):
                critical.append(err)
            else:
                warning.append(err)

    if data.get("volume_statuses"):
        replicas = defaultdict(set)
        expected_copies = {}
        read_only_ids = set()
        read_only_copies = 0
        for idx, entry in enumerate(data["volume_statuses"]):
            for volume in entry.get("status", {}).get("Volumes", []) or []:
                vid = volume.get("Id")
                if vid is None:
                    continue
                replicas[vid].add(idx)
                expected_copies[vid] = max(
                    expected_copies.get(vid, 1),
                    _replica_expected(volume.get("ReplicaPlacement")),
                )
                if volume.get("ReadOnly"):
                    read_only_ids.add(vid)
                    read_only_copies += 1
        under_replicated = sorted(
            vid for vid, servers in replicas.items() if len(servers) < expected_copies.get(vid, 3)
        )
    else:
        read_only_ids = set()
        read_only_copies = 0
        under_replicated = []
        critical.append("no volume server status available")

    disk_max = 0.0
    disk_max_url = ""
    for entry in data.get("volume_statuses", []):
        for disk in entry.get("status", {}).get("DiskStatuses", []) or []:
            all_bytes = int(disk.get("all", 0) or 0)
            used_bytes = int(disk.get("used", 0) or 0)
            if all_bytes <= 0:
                continue
            pct = used_bytes / all_bytes * 100.0
            if pct > disk_max:
                disk_max = pct
                disk_max_url = entry.get("url", "")

    total_volumes = sum(
        len(entry.get("status", {}).get("Volumes", []) or [])
        for entry in data.get("volume_statuses", [])
    )
    read_only_pct = _pct(len(read_only_ids), total_volumes)
    under_rep_pct = _pct(len(under_replicated), max(total_volumes, 1))

    if max_slots <= 0:
        critical.append("master reports no volume slots")
    elif free_slots <= 0:
        critical.append(f"no free volume slots (0/{max_slots})")
    elif free_pct <= args.crit_free_pct:
        critical.append(f"free volume slots {free_slots}/{max_slots} ({free_pct:.1f}%)")
    elif free_pct <= args.warn_free_pct:
        warning.append(f"free volume slots {free_slots}/{max_slots} ({free_pct:.1f}%)")

    if disk_max >= args.crit_disk_pct:
        critical.append(f"disk {disk_max:.1f}% used on {disk_max_url}")
    elif disk_max >= args.warn_disk_pct:
        warning.append(f"disk {disk_max:.1f}% used on {disk_max_url}")

    if read_only_ids:
        reason = f"{len(read_only_ids)} read-only volume(s) ({read_only_copies} copy/copies)"
        if read_only_pct >= args.crit_read_only_pct:
            critical.append(reason)
        else:
            warning.append(reason)

    if under_replicated:
        reason = f"{len(under_replicated)} under-replicated volume(s)"
        if under_rep_pct >= args.crit_underrep_pct:
            critical.append(reason)
        else:
            warning.append(reason)

    seaweed = data.get("seaweed") or {}
    operator_ready = (seaweed.get("status", {}) or {}).get("ready")
    if operator_ready is False:
        warning.append("Seaweed.status.ready is false")
    elif operator_ready is None and seaweed:
        warning.append("Seaweed.status.ready is missing")

    vct_diffs = _vct_differences(data)
    warning.extend(vct_diffs)

    code = OK
    for reason in critical:
        code = CRITICAL
        details.append(f"CRITICAL: {reason}")
    for reason in warning:
        if code == OK:
            code = WARNING
        details.append(f"WARNING: {reason}")

    parts = [
        f"{pod_summary.get('master', {}).get('ready', 0)}/{expected['master']} masters",
        f"{pod_summary.get('volume', {}).get('ready', 0)}/{expected['volume']} volumes",
        f"{pod_summary.get('filer', {}).get('ready', 0)}/{expected['filer']} filers",
    ]
    if expected["admin"] > 0:
        parts.append(f"{pod_summary.get('admin', {}).get('ready', 0)}/{expected['admin']} admin")
    parts.extend(
        [
            f"free slots {free_slots}/{max_slots} ({free_pct:.1f}%)",
            f"disk max {disk_max:.1f}%",
            f"read-only {len(read_only_ids)}",
            f"under-replicated {len(under_replicated)}",
        ]
    )
    if operator_ready is not None:
        parts.append(f"operator {'ready' if operator_ready else 'NOT ready'}")

    summary = f"{STATUS_NAME[code]}: SeaweedFS " + "; ".join(parts)
    if code != OK and critical:
        summary += " - " + critical[0]
    elif code != OK and warning:
        summary += " - " + warning[0]

    warn_slots = int(max_slots * args.warn_free_pct / 100.0) if max_slots else 0
    crit_slots = int(max_slots * args.crit_free_pct / 100.0) if max_slots else 0
    perfdata = " ".join(
        [
            f"free_slots={free_slots};{warn_slots};{crit_slots};0;{max_slots}",
            f"free_pct={free_pct:.1f}%;{args.warn_free_pct:g};{args.crit_free_pct:g};0;100",
            f"disk_max_pct={disk_max:.1f}%;{args.warn_disk_pct:g};{args.crit_disk_pct:g};0;100",
            f"read_only={len(read_only_ids)}",
            f"under_replicated={len(under_replicated)}",
            f"masters_ready={pod_summary.get('master', {}).get('ready', 0)};{expected['master']}",
            f"volumes_ready={pod_summary.get('volume', {}).get('ready', 0)};{expected['volume']}",
            f"filers_ready={pod_summary.get('filer', {}).get('ready', 0)};{expected['filer']}",
            f"admin_ready={pod_summary.get('admin', {}).get('ready', 0)};{expected['admin']}",
            f"operator_ready={1 if operator_ready else 0}",
        ]
    )
    details.append(
        f"master pod: {data.get('master_pod_used', '?')}; leader: {leader or '?'}; "
        f"volume servers: {len(data.get('volume_statuses', []))}"
    )
    return code, summary, details, perfdata


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Check SeaweedFS health and volume-slot capacity.")
    parser.add_argument("--namespace", default="localghost")
    parser.add_argument("--seaweed-name", default="localghost-storage")
    parser.add_argument("--master-pod", default="localghost-storage-master-0",
                        help="Comma-separated fallback master pods if none are Ready")
    parser.add_argument("--masters-expected", type=int, default=3)
    parser.add_argument("--volumes-expected", type=int, default=3)
    parser.add_argument("--filers-expected", type=int, default=3)
    parser.add_argument("--admin-expected", type=int, default=1)
    parser.add_argument("--warn-free-pct", type=float, default=10.0)
    parser.add_argument("--crit-free-pct", type=float, default=2.0)
    parser.add_argument("--warn-disk-pct", type=float, default=85.0)
    parser.add_argument("--crit-disk-pct", type=float, default=92.0)
    parser.add_argument("--crit-read-only-pct", type=float, default=10.0)
    parser.add_argument("--crit-underrep-pct", type=float, default=5.0)
    parser.add_argument("--timeout", type=float, default=20.0)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        data = collect(args)
        code, summary, details, perfdata = evaluate(data, args)
    except Exception as exc:  # noqa: BLE001 - any failure is an UNKNOWN result
        print(f"UNKNOWN: SeaweedFS check failed: {exc}")
        return UNKNOWN
    print(summary + (f" | {perfdata}" if perfdata else ""))
    for line in details:
        print(line)
    return code


if __name__ == "__main__":
    sys.exit(main())
