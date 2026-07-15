#!/usr/bin/env python3
import json
import subprocess
import sys
import os
import urllib.request
import re
import time

CACHE_FILE = '/tmp/check_k8s_updates_cache.json'
CACHE_TTL = 43200 # 12 hours in seconds

COMPONENTS = [
    {
        "name": "CloudNativePG Operator",
        "type": "deployment",
        "namespace": "cnpg-system",
        "resource_name": "cnpg-controller-manager",
        "repo": "cloudnative-pg/cloudnative-pg",
        "version_pattern": r'(\d+\.\d+\.\d+)'
    },
    {
        "name": "Redis Operator",
        "type": "deployment",
        "namespace": "redis-operator-system",
        "resource_name": "redis-operator-redis-operator",
        "repo": "OT-CONTAINER-KIT/redis-operator",
        "version_pattern": r'(\d+\.\d+\.\d+)'
    },
    {
        "name": "SeaweedFS Operator",
        "type": "deployment",
        "namespace": "seaweedfs-operator",
        "resource_name": "seaweedfs-operator",
        "repo": "seaweedfs/seaweedfs-operator",
        "version_pattern": r'(\d+\.\d+\.\d+)'
    },
    {
        "name": "Cert-Manager",
        "type": "deployment",
        "namespace": "cert-manager",
        "resource_name": "cert-manager",
        "repo": "cert-manager/cert-manager",
        "version_pattern": r'(\d+\.\d+\.\d+)'
    },
    {
        "name": "Grafana Loki",
        "type": "statefulset",
        "namespace": "monitoring",
        "resource_name": "loki",
        "repo": "grafana/loki",
        "version_pattern": r'(\d+\.\d+\.\d+)'
    },
    {
        "name": "Grafana Alloy",
        "type": "daemonset",
        "namespace": "monitoring",
        "resource_name": "alloy",
        "repo": "grafana/alloy",
        "version_pattern": r'(\d+\.\d+\.\d+)'
    }
]

def parse_version(v_str):
    match = re.search(r'(\d+\.\d+\.\d+)', v_str)
    if match:
        return [int(x) for x in match.group(1).split('.')]
    return [0, 0, 0]

def get_current_version(comp):
    try:
        cmd = ['kubectl', 'get', comp['type'], comp['resource_name'], '-n', comp['namespace'], '-o', 'jsonpath={.spec.template.spec.containers[*].image}']
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        img = res.stdout.strip()
        # Extract version from image tag (e.g. image:tag)
        if ':' in img:
            return img.split(':')[-1]
        return img
    except Exception as e:
        return f"Error: {e}"

def fetch_latest_github_release(repo):
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    req = urllib.request.Request(
        url, 
        headers={'User-Agent': 'Mozilla/5.0 (Kubernetes monitoring check)'}
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.loads(response.read().decode())
            return data.get('tag_name', '')
    except Exception:
        # Fallback to tags if releases is empty or returns 404
        try:
            tags_url = f"https://api.github.com/repos/{repo}/tags"
            tags_req = urllib.request.Request(
                tags_url, 
                headers={'User-Agent': 'Mozilla/5.0 (Kubernetes monitoring check)'}
            )
            with urllib.request.urlopen(tags_req, timeout=10) as response:
                tags_data = json.loads(response.read().decode())
                if tags_data:
                    return tags_data[0].get('name', '')
        except Exception:
            pass
        return None

def load_cache():
    if os.path.exists(CACHE_FILE):
        try:
            mtime = os.path.getmtime(CACHE_FILE)
            if time.time() - mtime < CACHE_TTL:
                with open(CACHE_FILE, 'r') as f:
                    return json.load(f)
        except Exception:
            pass
    return {}

def save_cache(cache):
    try:
        with open(CACHE_FILE, 'w') as f:
            json.dump(cache, f)
    except Exception:
        pass

def main():
    cache = load_cache()
    latest_versions = {}
    cache_updated = False

    for comp in COMPONENTS:
        repo = comp['repo']
        if repo in cache:
            latest_versions[repo] = cache[repo]
        else:
            latest = fetch_latest_github_release(repo)
            if latest:
                latest_versions[repo] = latest
                cache[repo] = latest
                cache_updated = True
            else:
                # If API call failed and no cache, mark as unknown
                latest_versions[repo] = None

    if cache_updated:
        save_cache(cache)

    updates_available = []
    errors = []

    for comp in COMPONENTS:
        curr = get_current_version(comp)
        if curr.startswith("Error"):
            errors.append(f"Could not query {comp['name']}: {curr}")
            continue

        latest = latest_versions.get(comp['repo'])
        if not latest:
            errors.append(f"Could not fetch latest version for {comp['name']}")
            continue

        if comp["name"] == "Redis Operator" and curr.strip('v') == "0.24.0" and latest.strip('v') == "0.25.0":
            continue

        curr_parsed = parse_version(curr)
        latest_parsed = parse_version(latest)

        if latest_parsed > curr_parsed:
            updates_available.append(f"{comp['name']}: current {curr} < latest {latest}")

    # Add HelmRelease checks for prometheus-operator
    try:
        res = subprocess.run(
            ['kubectl', 'get', 'helmrelease', 'prometheus-operator', '-n', 'monitoring', '-o', 'jsonpath={.spec.chart.spec.version}'],
            capture_output=True, text=True, check=True
        )
        prom_curr = res.stdout.strip()
        
        # Check cache/fetch latest for kube-prometheus-stack chart
        chart_repo = "prometheus-community/helm-charts"
        prom_latest = cache.get(chart_repo)
        if not prom_latest:
            # Fetch latest from prometheus-community chart index
            try:
                with urllib.request.urlopen("https://prometheus-community.github.io/helm-charts/index.yaml", timeout=10) as response:
                    index_data = response.read().decode()
                    idx = index_data.find('kube-prometheus-stack:')
                    if idx != -1:
                        match = re.search(r'/kube-prometheus-stack-([\d\.]+)\.tgz', index_data[idx:idx+10000])
                        if match:
                            prom_latest = match.group(1).strip()
                            cache[chart_repo] = prom_latest
                            save_cache(cache)
            except Exception:
                pass

        if prom_latest and prom_curr:
            curr_parsed = parse_version(prom_curr)
            latest_parsed = parse_version(prom_latest)
            if latest_parsed > curr_parsed:
                updates_available.append(f"kube-prometheus-stack: current {prom_curr} < latest {prom_latest}")
        elif not prom_latest:
            errors.append("Could not fetch latest version for kube-prometheus-stack")
    except Exception as e:
        errors.append(f"Could not query prometheus-operator helmrelease: {e}")

    if updates_available:
        print(f"WARNING: {len(updates_available)} updates available | updates={len(updates_available)}")
        for upd in updates_available:
            print(upd)
        if errors:
            print("Errors encountered:")
            for err in errors:
                print(f"- {err}")
        sys.exit(1)
    elif errors:
        print(f"UNKNOWN: Update check encountered errors | errors={len(errors)}")
        for err in errors:
            print(err)
        sys.exit(3)
    else:
        print("OK: All tracked operators and components are up to date. | updates=0")
        sys.exit(0)

if __name__ == "__main__":
    main()
