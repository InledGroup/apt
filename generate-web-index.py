#!/usr/bin/python3
import os
import re
import subprocess
import json
import sys
import tempfile

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
                        "file": f"{parts[0]}_{parts[1]}_{parts[2]}.deb"
                    })
    except Exception as e:
        print(f"Error APT: {e}")
    return packages

def get_rpm_packages(rpm_dir):
    packages = []
    if not os.path.exists(rpm_dir): return packages
    for f in os.listdir(rpm_dir):
        if f.endswith(".rpm"):
            # RPM: name-version-release.arch.rpm
            match = re.match(r"^(.+)-(\d[^-]*)-\d+\.([^.]+)\.rpm$", f)
            if match:
                packages.append({"name": match.group(1), "version": match.group(2), "arch": match.group(3), "type": "rpm", "file": f})
            else:
                packages.append({"name": f.split("-")[0], "version": "unknown", "arch": "unknown", "type": "rpm", "file": f})
    return packages

def get_arch_packages(arch_dir):
    packages = []
    if not os.path.exists(arch_dir): return packages
    for f in os.listdir(arch_dir):
        if f.endswith(".pkg.tar.zst") or f.endswith(".pkg.tar.xz") or f.endswith(".pkg.tar.gz"):
            # Arch: name-version-pkgrel-arch.pkg.tar.zst
            match = re.match(r"^(.+)-(\d[^-]*)-(\d+)-([^.]+)\.pkg\.tar\..+$", f)
            if match:
                packages.append({"name": match.group(1), "version": match.group(2), "arch": match.group(4), "type": "arch", "file": f})
            else:
                packages.append({"name": f.split("-")[0], "version": "unknown", "arch": "unknown", "type": "arch", "file": f})
    return packages

def version_key(version_str):
    try:
        cleaned = re.sub(r'[^\d.]', '.', version_str)
        parts = [int(x) for x in cleaned.split('.') if x]
        return tuple(parts) if parts else (0,)
    except:
        return (0,)

def generate_html(release_url, key_id=None):
    apt_pkgs = get_apt_packages("inled-repo")
    apt_pkgs += get_apt_packages("inled-repo-forky")
    apt_pkgs += get_apt_packages("inled-repo-rolling")
    rpm_pkgs = get_rpm_packages("public/rpm")
    arch_pkgs = get_arch_packages("public/arch")
    current_pkgs = apt_pkgs + rpm_pkgs + arch_pkgs

    print(f"Scan: APT({len(apt_pkgs)}), RPM({len(rpm_pkgs)}), Arch({len(arch_pkgs)})")

    db_file = "packages.json"
    history = {}
    if os.path.exists(db_file):
        try:
            with open(db_file, "r") as f:
                history = json.load(f)
        except:
            history = {}

    # Merge current scan into history
    current_names = set()
    for pkg in current_pkgs:
        name = pkg["name"]
        current_names.add(name)
        if name not in history:
            history[name] = {"versions": {}}

        version = pkg["version"]
        if version not in history[name]["versions"]:
            history[name]["versions"][version] = []

        exists = any(p["file"] == pkg["file"] for p in history[name]["versions"][version])
        if not exists:
            history[name]["versions"][version].append(pkg)

    # Remove packages no longer present in any scan
    for name in list(history.keys()):
        if name not in current_names:
            del history[name]
            print(f"Removed stale package from history: {name}")

    with open(db_file, "w") as f:
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
                        if "+deb13" in pkg["version"]:
                            branch = "stable"
                        elif "+deb14" in pkg["version"]:
                            branch = "forky"
                        elif "+rolling" in pkg["version"]:
                            branch = "rolling"
                        else:
                            branch = "stable" # legacy
                    else:
                        branch = p_type # rpm, arch, etc.
                    
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
                arch_info = f' ({pkg["arch"]})' if pkg["arch"] != "unknown" else ""
                ver_info = f' v{pkg["version"]}' if pkg["version"] != latest_overall_ver else ""
                full_label = f"{pkg['type']}{arch_info}{ver_info}"
                item_html += f'<a href="{release_url}/{pkg["file"]}" class="btn btn-sm btn-{pkg["type"]}">{full_label}</a>'

            item_html += f'</div></li>'
            packages_html += item_html

    with open("index.html.template", "r") as f:
        template = f.read()

    # Dump the history dict to JSON string for client-side rendering
    db_json = json.dumps(history)

    final_html = template.replace("<!-- PACKAGES_LIST_PLACEHOLDER -->", packages_html)
    final_html = final_html.replace("<!-- PACKAGES_DB_PLACEHOLDER -->", db_json)
    final_html = final_html.replace("<!-- RELEASE_URL_PLACEHOLDER -->", release_url)
    if key_id:
        final_html = final_html.replace("<KEY_ID>", key_id)

    os.makedirs("public", exist_ok=True)
    tmp = tempfile.NamedTemporaryFile(mode="w", dir="public", delete=False, suffix=".html")
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
