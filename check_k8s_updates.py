#!/usr/bin/env python3
import json
import subprocess
import sys
import os
import urllib.request
import re
import time
from concurrent.futures import ThreadPoolExecutor

CACHE_FILE = '/tmp/check_k8s_updates_cache.json'
CACHE_TTL = 43200 # 12 hours in seconds

# Ensure KUBECONFIG is set for subprocesses on K3s nodes
if 'KUBECONFIG' not in os.environ and os.path.exists('/etc/rancher/k3s/k3s.yaml'):
    os.environ['KUBECONFIG'] = '/etc/rancher/k3s/k3s.yaml'

def get_dynamic_chart_repos():
    repos = {}
    
    # 1. Query K3s HelmCharts
    try:
        res = subprocess.run(
            ['kubectl', 'get', 'helmcharts.helm.cattle.io', '-A', '-o', 'json'],
            capture_output=True, text=True, check=True
        )
        charts_data = json.loads(res.stdout)
        for item in charts_data.get('items', []):
            spec = item.get('spec', {})
            chart_name = spec.get('chart')
            repo_url = spec.get('repo')
            if chart_name and repo_url:
                if repo_url.startswith('http'):
                    repos[chart_name] = repo_url
    except Exception:
        pass

    # 2. Query Flux HelmRepositories
    repo_map = {}
    try:
        res = subprocess.run(
            ['kubectl', 'get', 'helmrepositories.source.toolkit.fluxcd.io', '-A', '-o', 'json'],
            capture_output=True, text=True, check=True
        )
        repos_data = json.loads(res.stdout)
        for item in repos_data.get('items', []):
            ns = item['metadata']['namespace']
            name = item['metadata']['name']
            url = item.get('spec', {}).get('url')
            if url:
                repo_map[f"{ns}/{name}"] = url
    except Exception:
        pass

    # 3. Query Flux HelmReleases
    try:
        res = subprocess.run(
            ['kubectl', 'get', 'helmreleases.helm.toolkit.fluxcd.io', '-A', '-o', 'json'],
            capture_output=True, text=True, check=True
        )
        releases_data = json.loads(res.stdout)
        for item in releases_data.get('items', []):
            spec = item.get('spec', {})
            chart_spec = spec.get('chart', {}).get('spec', {})
            chart_name = chart_spec.get('chart')
            source_ref = chart_spec.get('sourceRef', {})
            
            if chart_name and source_ref.get('kind') == 'HelmRepository':
                ref_name = source_ref.get('name')
                ref_ns = source_ref.get('namespace', item['metadata']['namespace'])
                repo_url = repo_map.get(f"{ref_ns}/{ref_name}")
                if repo_url and repo_url.startswith('http'):
                    repos[chart_name] = repo_url
    except Exception:
        pass

    return repos

def get_local_helm_repos():
    repos = {}
    try:
        res = subprocess.run(
            ['helm', 'repo', 'list', '-o', 'json'],
            capture_output=True, text=True, check=True
        )
        local_repos = json.loads(res.stdout)
        for r in local_repos:
            name = r.get('name')
            url = r.get('url')
            if name and url:
                repos[name] = url
    except Exception:
        pass
    return repos

def resolve_chart_repo(chart_name, dynamic_repos, local_repos):
    url = None
    
    # Map of chart names to known repo name aliases (for local/dynamic lookup mismatches)
    ALIASES = {
        "cert-manager": "jetstack",
        "kube-prometheus-stack": "prometheus-community"
    }
    
    lookup_name = ALIASES.get(chart_name, chart_name)
    
    if lookup_name in dynamic_repos:
        url = dynamic_repos[lookup_name]
    else:
        for rname, rurl in local_repos.items():
            if lookup_name == rname or lookup_name.startswith(f"{rname}-"):
                url = rurl
                break
                
    if not url:
        FALLBACKS = {
            "cert-manager": "https://charts.jetstack.io",
            "cert-manager-webhook-hetzner": "https://hetznercloud.github.io/helm-charts",
            "external-secrets": "https://charts.external-secrets.io",
            "openbao": "https://openbao.github.io/openbao-helm",
            "redis-operator": "https://ot-container-kit.github.io/helm-charts",
            "sealed-secrets": "https://bitnami.github.io/sealed-secrets",
            "seaweedfs-operator": "https://seaweedfs.github.io/seaweedfs-operator",
            "traefik": "https://traefik.github.io/charts",
            "trivy-operator": "https://aquasecurity.github.io/helm-charts",
            "gitlab-agent": "https://charts.gitlab.io",
            "gitlab-operator": "https://charts.gitlab.io",
            "kube-prometheus-stack": "https://prometheus-community.github.io/helm-charts",
            "opentelemetry-operator": "https://open-telemetry.github.io/opentelemetry-helm-charts"
        }
        url = FALLBACKS.get(chart_name)
        
    if url:
        # Normalize and upgrade deprecated URLs
        url = url.replace("bitnami-labs.github.io", "bitnami.github.io")
        url = url.replace("syself.github.io/charts", "hetznercloud.github.io/helm-charts")
        
    return url

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
    },
    {
        "name": "GitLab Runner",
        "type": "deployment",
        "namespace": "gitlab",
        "resource_name": "gitlab-runner",
        "repo": "gitlab-org/gitlab-runner",
        "version_pattern": r'(\d+\.\d+\.\d+)'
    },
    {
        "name": "Registry Mirror",
        "type": "deployment",
        "namespace": "gitlab",
        "resource_name": "registry-mirror",
        "repo": "distribution/distribution",
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
        cmd = ['kubectl', 'get', comp['type'], comp['resource_name'], '-n', comp['namespace'], '-o', 'jsonpath={.spec.template.spec.containers[0].image}']
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        img = res.stdout.strip()
        # Extract version from image tag (e.g. image:tag)
        if ':' in img:
            return img.split(':')[-1]
        return img
    except Exception as e:
        return f"Error: {e}"

def fetch_latest_github_release(repo):
    if repo.startswith("gitlab-org/"):
        gl_repo = repo.replace("/", "%2F")
        url = f"https://gitlab.com/api/v4/projects/{gl_repo}/repository/tags?per_page=10"
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (Kubernetes monitoring check)'})
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                tags_data = json.loads(response.read().decode())
                for t in tags_data:
                    name = t.get('name', '')
                    if re.match(r'^v?\d+\.\d+\.\d+$', name):
                        return name
        except Exception:
            pass

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

def check_gitlab_runner_helper_sync():
    try:
        res_dep = subprocess.run(
            ['kubectl', 'get', 'deployment', 'gitlab-runner', '-n', 'gitlab', '-o', 'jsonpath={.spec.template.spec.containers[0].image}'],
            capture_output=True, text=True, check=True
        )
        runner_img = res_dep.stdout.strip()
        runner_match = re.search(r'v?(\d+\.\d+\.\d+)', runner_img)

        res_cm = subprocess.run(
            ['kubectl', 'get', 'configmap', 'gitlab-runner-config', '-n', 'gitlab', '-o', 'jsonpath={.data.config\\.toml}'],
            capture_output=True, text=True, check=True
        )
        config_toml = res_cm.stdout.strip()
        helper_match = re.search(r'helper_image\s*=\s*["\'](.*?)["\']', config_toml)

        if runner_match and helper_match:
            runner_ver = runner_match.group(1)
            helper_img = helper_match.group(1)
            helper_match_ver = re.search(r'v?(\d+\.\d+\.\d+)', helper_img)
            if helper_match_ver:
                helper_ver = helper_match_ver.group(1)
                if runner_ver != helper_ver:
                    return f"GitLab Runner Mismatch: core runner is v{runner_ver} but helper_image in ConfigMap is v{helper_ver}"
    except Exception as e:
        return f"Could not check gitlab-runner helper sync: {e}"
    return None

def main():
    cache = load_cache()
    updates_available = []
    errors = []

    # Check gitlab-runner helper version sync
    runner_sync_err = check_gitlab_runner_helper_sync()
    if runner_sync_err:
        updates_available.append(runner_sync_err)

    # 1. Check components in parallel
    def check_component(comp):
        curr_ver = get_current_version(comp)
        if curr_ver.startswith("Error"):
            return None, f"Could not query {comp['name']}: {curr_ver}"
            
        repo = comp['repo']
        cache_key = f"comp/{comp['name']}"
        latest_ver = cache.get(cache_key)
        
        if not latest_ver:
            latest_ver = fetch_latest_github_release(repo)
            if latest_ver and not latest_ver.startswith("Error"):
                latest_ver = re.sub(r'^[vV]', '', latest_ver)
                cache[cache_key] = latest_ver
                
        if latest_ver and not latest_ver.startswith("Error"):
            match = re.search(comp['version_pattern'], latest_ver)
            if match:
                latest_ver = match.group(1)
            
            curr_ver_clean = re.sub(r'^[vV]', '', curr_ver)
            curr_parsed = parse_version(curr_ver_clean)
            latest_parsed = parse_version(latest_ver)
            
            if latest_parsed > curr_parsed:
                return f"{comp['name']}: current {curr_ver} < latest {latest_ver}", None
        else:
            return None, f"Could not fetch latest version for {comp['name']}"
        return None, None

    try:
        with ThreadPoolExecutor(max_workers=4) as executor:
            comp_results = list(executor.map(check_component, COMPONENTS))
            for upd, err in comp_results:
                if upd:
                    updates_available.append(upd)
                if err:
                    errors.append(err)
        save_cache(cache)
    except Exception as e:
        errors.append(f"Could not check components: {e}")

    # 2. Check prometheus-operator HelmRelease
    try:
        res = subprocess.run(
            ['kubectl', 'get', 'helmrelease', 'prometheus-operator', '-n', 'monitoring', '-o', 'jsonpath={.spec.chart.spec.version}'],
            capture_output=True, text=True, check=True
        )
        prom_curr = res.stdout.strip()
        
        chart_repo = "prometheus-community/helm-charts"
        prom_latest = cache.get(chart_repo)
        if not prom_latest:
            try:
                req = urllib.request.Request(
                    "https://prometheus-community.github.io/helm-charts/index.yaml",
                    headers={
                        'User-Agent': 'Mozilla/5.0 (Kubernetes monitoring check)'
                    }
                )
                with urllib.request.urlopen(req, timeout=30) as response:
                    index_data = response.read().decode('utf-8', errors='ignore')
                    idx = index_data.find('kube-prometheus-stack:')
                    if idx != -1:
                        match = re.search(r'/kube-prometheus-stack-([\d\.]+)\.tgz', index_data[idx:idx+10000])
                        if match:
                            prom_latest = match.group(1).strip()
                            cache[chart_repo] = prom_latest
                            save_cache(cache)
            except Exception as e:
                errors.append(f"Failed to fetch kube-prometheus-stack: {e}")

        if prom_latest and prom_curr:
            curr_parsed = parse_version(prom_curr)
            latest_parsed = parse_version(prom_latest)
            if latest_parsed > curr_parsed:
                updates_available.append(f"kube-prometheus-stack: current {prom_curr} < latest {prom_latest}")
        elif not prom_latest:
            errors.append("Could not fetch latest version for kube-prometheus-stack")
    except Exception as e:
        errors.append(f"Could not query prometheus-operator helmrelease: {e}")

    # 3. Check Helm releases dynamically in parallel
    try:
        dynamic_repos = get_dynamic_chart_repos()
        local_repos = get_local_helm_repos()
        
        res = subprocess.run(
            ['helm', 'list', '-A', '-o', 'json'],
            capture_output=True, text=True, check=True
        )
        releases = json.loads(res.stdout)
        
        to_check = []
        for rel in releases:
            chart_str = rel.get('chart', '')
            match = re.search(r'^(.*?)-v?(\d+\.\d+\.\d+.*)$', chart_str)
            if not match:
                continue
            chart_name = match.group(1)
            curr_ver = match.group(2)
            
            repo_url = resolve_chart_repo(chart_name, dynamic_repos, local_repos)
            if repo_url:
                to_check.append({
                    'chart_name': chart_name,
                    'curr_ver': curr_ver,
                    'repo_url': repo_url,
                    'rel': rel
                })

        unique_charts = {}
        for item in to_check:
            cname = item['chart_name']
            rurl = item['repo_url']
            cache_key = f"helm-chart/{cname}"
            if cname not in unique_charts and not cache.get(cache_key):
                unique_charts[cname] = rurl

        def fetch_chart_latest_version(cname, rurl):
            try:
                req = urllib.request.Request(
                    f"{rurl.rstrip('/')}/index.yaml",
                    headers={
                        'User-Agent': 'Mozilla/5.0 (Kubernetes monitoring check)'
                    }
                )
                with urllib.request.urlopen(req, timeout=30) as response:
                    index_data = response.read().decode('utf-8', errors='ignore')
                    match_entry = re.search(rf'^\s*{re.escape(cname)}:\s*$', index_data, re.MULTILINE)
                    if match_entry:
                        idx = match_entry.start()
                        match_ver = re.search(r'version:\s*["\']?[vV]?(\d+\.\d+\.\d+)["\']?\s*(?:\r?\n|$)', index_data[idx:idx+3000])
                        if match_ver:
                            return cname, match_ver.group(1).strip('"\''), None
                    return cname, None, "Chart key not found in index"
            except Exception as e:
                return cname, None, str(e)

        if unique_charts:
            with ThreadPoolExecutor(max_workers=5) as executor:
                futures = [
                    executor.submit(fetch_chart_latest_version, cname, rurl)
                    for cname, rurl in unique_charts.items()
                ]
                for fut in futures:
                    cname, latest_ver, err = fut.result()
                    if latest_ver:
                        cache[f"helm-chart/{cname}"] = latest_ver
                    elif err:
                        errors.append(f"Failed to fetch {cname} from {unique_charts[cname]}: {err}")
            save_cache(cache)

        for item in to_check:
            chart_name = item['chart_name']
            curr_ver = item['curr_ver']
            repo_url = item['repo_url']
            rel = item['rel']
            
            cache_key = f"helm-chart/{chart_name}"
            latest_ver = cache.get(cache_key)
            
            if latest_ver:
                curr_ver_clean = re.sub(r'^[vV]', '', curr_ver)
                latest_ver_clean = re.sub(r'^[vV]', '', latest_ver)
                curr_parsed = parse_version(curr_ver_clean)
                latest_parsed = parse_version(latest_ver_clean)
                
                if latest_parsed > curr_parsed:
                    updates_available.append(
                        f"Helm Chart {chart_name} ({rel['name']} in {rel['namespace']}): current {curr_ver} < latest {latest_ver}"
                    )
            else:
                if not any(f"Failed to fetch {chart_name}" in err for err in errors):
                    errors.append(f"Could not fetch latest version for Helm chart {chart_name}")

    except Exception as e:
        errors.append(f"Could not check Helm releases: {e}")

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
