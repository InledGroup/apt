#!/usr/bin/python3
import os
import re
import subprocess
import json
import sys
import tempfile

DEB_RE = re.compile(r"^(?P<name>[^_]+)_(?P<version>[^_]+)_(?P<arch>[^_]+)\.deb$")
RPM_RE = re.compile(r"^(?P<name>.+?)-(?P<version>\d.*?)\.(?P<arch>x86_64|aarch64|arm64|noarch|i386|i686|armv7hl)\.rpm$")
ARCH_RE = re.compile(r"^(?P<name>.+?)-(?P<version>\d[^-]*)-(?P<pkgrel>\d+)-(?P<arch>[^.]+)\.pkg\.tar\..+$")

def get_deb_dist(version):
    if "deb14" in version:
        return "forky"
    elif "rolling" in version:
        return "rolling"
    return "stable"

def get_apt_packages(repo_name):
    packages = []
    try:
        output = subprocess.check_output(["aptly", "-config=aptly.conf", "repo", "show", "-with-packages", repo_name], text=True)
        lines = output.splitlines()
        start_index = -1
        for i, line in enumerate(lines):
            if "Packages:" in line:
                start_index = i + 1
                break

        if start_index != -1:
            branch = "stable"
            if "forky" in repo_name:
                branch = "forky"
            elif "rolling" in repo_name:
                branch = "rolling"

            for line in lines[start_index:]:
                line = line.strip()
                if not line: continue
                parts = line.split("_")
                if len(parts) >= 3:
                    packages.append({
                        "name": parts[0],
                        "version": parts[1],
                        "arch": parts[2],
                        "type": "deb",
                        "branch": branch,
                        "file": f"{parts[0]}_{parts[1]}_{parts[2]}.deb"
                    })
    except Exception as e:
        pass
    return packages

def get_packages_from_assets(assets_file):
    packages = []
    if not os.path.exists(assets_file):
        return packages
    with open(assets_file, "r", encoding="utf-8") as f:
        for line in f:
            filename = line.strip()
            if not filename or filename.endswith(".sig") or filename == "packages.json":
                continue
            if m := RPM_RE.match(filename):
                packages.append({
                    "name": m.group("name"),
                    "version": m.group("version"),
                    "arch": m.group("arch"),
                    "type": "rpm",
                    "file": filename
                })
            elif m := ARCH_RE.match(filename):
                packages.append({
                    "name": m.group("name"),
                    "version": m.group("version"),
                    "arch": m.group("arch"),
                    "type": "arch",
                    "file": filename
                })
            elif m := DEB_RE.match(filename):
                ver = m.group("version")
                packages.append({
                    "name": m.group("name"),
                    "version": ver,
                    "arch": m.group("arch"),
                    "type": "deb",
                    "branch": get_deb_dist(ver),
                    "file": filename
                })
    return packages

def version_key(version_str):
    try:
        chunks = re.split(r"([0-9]+)", version_str)
        res = []
        for c in chunks:
            if not c: continue
            if c.isdigit():
                res.append((0, int(c)))
            else:
                res.append((1, c))
        return tuple(res)
    except:
        return ((0, 0),)

LUCIDE_DOWNLOAD_SVG = (
    '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" '
    'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" '
    'stroke-linejoin="round" aria-hidden="true">'
    '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>'
    '<polyline points="7 10 12 15 17 10"/><line x1="12" x2="12" y1="15" y2="3"/></svg>'
)

def generate_html(release_url, key_id=None):
    # Load packages from aptly and current_assets.txt
    current_pkgs = []
    current_pkgs += get_apt_packages("inled-repo")
    current_pkgs += get_apt_packages("inled-repo-forky")
    current_pkgs += get_apt_packages("inled-repo-rolling")

    assets_pkgs = get_packages_from_assets("current_assets.txt")
    # Merge, deduplicating by filename
    seen_files = {p["file"] for p in current_pkgs}
    for p in assets_pkgs:
        if p["file"] not in seen_files:
            current_pkgs.append(p)
            seen_files.add(p["file"])

    db_file = "packages.json"
    history = {}
    if os.path.exists(db_file):
        try:
            with open(db_file, "r", encoding="utf-8") as f:
                history = json.load(f)
        except:
            history = {}

    active_assets = set()
    if os.path.exists("current_assets.txt"):
        with open("current_assets.txt", "r", encoding="utf-8") as f:
            for line in f:
                val = line.strip()
                if val:
                    active_assets.add(val)
    for pkg in current_pkgs:
        active_assets.add(pkg["file"])

    # Clean up history: remove versions and individual files no longer present in active_assets
    for name in list(history.keys()):
        for version in list(history[name]["versions"].keys()):
            history[name]["versions"][version] = [
                pkg for pkg in history[name]["versions"][version]
                if not active_assets or pkg["file"] in active_assets
            ]
            if not history[name]["versions"][version]:
                del history[name]["versions"][version]
        if not history[name]["versions"]:
            del history[name]

    # Merge current scan into history
    for pkg in current_pkgs:
        name = pkg["name"]
        if name not in history:
            history[name] = {"versions": {}}
        version = pkg["version"]
        if version not in history[name]["versions"]:
            history[name]["versions"][version] = []
        exists = any(p["file"] == pkg["file"] for p in history[name]["versions"][version])
        if not exists:
            history[name]["versions"][version].append(pkg)

    with open(db_file, "w", encoding="utf-8") as f:
        json.dump(history, f, indent=2)

    packages_html = ""
    if not history:
        packages_html = '<p style="grid-column: 1/-1; text-align: center; color: var(--text-muted);">No packages available.</p>'
    else:
        for name in sorted(history.keys()):
            versions = sorted(history[name]["versions"].keys(), key=version_key, reverse=True)
            latest_overall_ver = versions[0]

            # Group by branch/dist and keep only the latest version per branch
            latest_by_branch = {}
            for v in versions:
                for pkg in history[name]["versions"][v]:
                    p_type = pkg["type"]
                    if p_type == "deb":
                        branch = pkg.get("branch", "stable")
                    else:
                        branch = p_type
                    
                    if branch not in latest_by_branch:
                        latest_by_branch[branch] = pkg
                    else:
                        if version_key(pkg["version"]) > version_key(latest_by_branch[branch]["version"]):
                            latest_by_branch[branch] = pkg

            buttons_pkgs = list(latest_by_branch.values())

            item_html = f'<li class="package-item">'
            item_html += f'<div class="package-header"><span class="package-name">{name}</span><span class="package-version">v{latest_overall_ver}</span></div>'
            item_html += f'<p class="package-desc">{name}</p>'
            item_html += f'<div class="package-footer">'

            for pkg in sorted(buttons_pkgs, key=lambda x: (x["type"], x["arch"])):
                arch_info = f' ({pkg["arch"]})' if pkg.get("arch") and pkg["arch"] != "unknown" else ""
                ver_info = f' v{pkg["version"]}' if pkg["version"] != latest_overall_ver else ""
                full_label = f"{pkg['type']}{arch_info}{ver_info}"
                item_html += (
                    f'<a href="{release_url}/{pkg["file"]}" class="btn btn-sm btn-{pkg["type"]}" '
                    f'title="Download {full_label}" aria-label="Download {name} {full_label}">'
                    f'{LUCIDE_DOWNLOAD_SVG}</a>'
                )

            item_html += f'</div></li>'
            packages_html += item_html

    with open("index.html.template", "r", encoding="utf-8") as f:
        template = f.read()

    db_json = json.dumps(history)

    final_html = template.replace("<!-- PACKAGES_LIST_PLACEHOLDER -->", packages_html)
    final_html = final_html.replace("<!-- PACKAGES_DB_PLACEHOLDER -->", db_json)
    final_html = final_html.replace("<!-- RELEASE_URL_PLACEHOLDER -->", release_url)
    if key_id:
        final_html = final_html.replace("<KEY_ID>", key_id)
        final_html = final_html.replace("&lt;KEY_ID&gt;", key_id)

    os.makedirs("public", exist_ok=True)
    tmp = tempfile.NamedTemporaryFile(mode="w", dir="public", delete=False, suffix=".html", encoding="utf-8")
    try:
        tmp.write(final_html)
        tmp.close()
        os.replace(tmp.name, "public/index.html")
    except:
        os.unlink(tmp.name)
        raise

if __name__ == "__main__":
    url = sys.argv[1] if len(sys.argv) > 1 else "https://github.com/InledGroup/apt/releases/download/packages"
    key_id = sys.argv[2] if len(sys.argv) > 2 else None
    generate_html(url, key_id)
