#!/usr/bin/env python3
import os
import re
import sys
import json
import urllib.request
import urllib.error
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

DEB_RE = re.compile(r"^(?P<name>[^_]+)_(?P<version>[^_]+)_(?P<arch>[^_]+)\.deb$")
RPM_RE = re.compile(r"^(?P<name>.+?)-(?P<version>\d.*?)\.(?P<arch>x86_64|aarch64|arm64|noarch|i386|i686|armv7hl)\.rpm$")
ARCH_RE = re.compile(r"^(?P<name>.+?)-(?P<version>\d[^-]*)-(?P<pkgrel>\d+)-(?P<arch>[^.]+)\.pkg\.tar\..+$")

def parse_version_key(v):
    chunks = re.split(r"([0-9]+)", v)
    res = []
    for c in chunks:
        if not c:
            continue
        if c.isdigit():
            res.append((0, int(c)))
        else:
            res.append((1, c))
    return res

def get_deb_dist(version):
    if "deb14" in version:
        return "forky"
    elif "rolling" in version:
        return "rolling"
    return "stable"

def parse_package_filename(filename):
    if filename == "packages.json" or filename.endswith(".sig"):
        return None
    if m := DEB_RE.match(filename):
        ver = m.group("version")
        return {
            "type": "deb",
            "name": m.group("name"),
            "version": ver,
            "arch": m.group("arch"),
            "dist": get_deb_dist(ver),
            "file": filename
        }
    elif m := RPM_RE.match(filename):
        return {
            "type": "rpm",
            "name": m.group("name"),
            "version": m.group("version"),
            "arch": m.group("arch"),
            "dist": "rpm",
            "file": filename
        }
    elif m := ARCH_RE.match(filename):
        return {
            "type": "arch",
            "name": m.group("name"),
            "version": m.group("version"),
            "arch": m.group("arch"),
            "dist": "arch",
            "file": filename
        }
    return {"type": "junk", "name": filename, "version": "0", "arch": "unknown", "dist": "junk", "file": filename}

def get_release_assets(repo, tag, token):
    url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/vnd.github.v3+json")
    req.add_header("User-Agent", "inled-apt-pruner")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data.get("assets", [])
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return []
        raise

def delete_asset(repo, asset_id, asset_name, token):
    url = f"https://api.github.com/repos/{repo}/releases/assets/{asset_id}"
    req = urllib.request.Request(url, method="DELETE")
    req.add_header("Accept", "application/vnd.github.v3+json")
    req.add_header("User-Agent", "inled-apt-pruner")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req) as resp:
            if resp.status in (204, 200):
                print(f"  🗑️ Deleted obsolete asset: {asset_name} (ID: {asset_id})")
                return True
    except Exception as e:
        print(f"  ⚠️ Failed to delete asset {asset_name} (ID: {asset_id}): {e}")
        return False

def prune(repo, tag="packages", token=None, incoming_dir="incoming", dry_run=False):
    print(f"Fetching release assets for {repo} tag '{tag}'...")
    assets = get_release_assets(repo, tag, token)
    if not assets:
        print("No assets found in release.")
        with open("current_assets.txt", "w") as f:
            pass
        return

    assets_by_name = {a["name"]: a for a in assets}
    groups = defaultdict(list)
    junk_assets = []

    # Also inspect incoming_dir to know what is being uploaded in this run
    incoming_files = []
    if os.path.isdir(incoming_dir):
        incoming_files = [f for f in os.listdir(incoming_dir) if os.path.isfile(os.path.join(incoming_dir, f))]

    for f in incoming_files:
        parsed = parse_package_filename(f)
        if parsed and parsed["type"] != "junk":
            key = (parsed["type"], parsed["name"], parsed["dist"], parsed["arch"])
            # Artificial asset for incoming file so it takes precedence over older release assets
            groups[key].append((parsed["version"], {"name": f, "id": None, "incoming": True}))

    for a in assets:
        name = a["name"]
        if name == "packages.json" or name.endswith(".sig"):
            continue
        parsed = parse_package_filename(name)
        if not parsed or parsed["type"] == "junk":
            junk_assets.append(a)
            continue
        key = (parsed["type"], parsed["name"], parsed["dist"], parsed["arch"])
        groups[key].append((parsed["version"], a))

    to_keep = set(["packages.json"])
    to_delete = []

    for key, pkg_list in groups.items():
        pkg_list.sort(key=lambda x: parse_version_key(x[0]), reverse=True)
        latest_ver, latest_asset = pkg_list[0]
        if not latest_asset.get("incoming"):
            to_keep.add(latest_asset["name"])
            if latest_asset["name"] + ".sig" in assets_by_name:
                to_keep.add(latest_asset["name"] + ".sig")

        # Older versions in the release are marked for deletion
        for old_ver, old_asset in pkg_list[1:]:
            if old_asset.get("id"):
                to_delete.append(old_asset)
                sig_name = old_asset["name"] + ".sig"
                if sig_name in assets_by_name:
                    to_delete.append(assets_by_name[sig_name])

    for j in junk_assets:
        to_delete.append(j)

    # Check for orphan .sig files (sig files whose package is neither kept nor incoming)
    for a in assets:
        name = a["name"]
        if name.endswith(".sig"):
            pkg_name = name[:-4]
            if pkg_name not in to_keep and pkg_name not in incoming_files:
                if a not in to_delete:
                    to_delete.append(a)

    print(f"Total release assets on GitHub: {len(assets)}")
    print(f"Active assets to keep: {len(to_keep)}")
    print(f"Obsolete/junk assets to delete: {len(to_delete)}")

    if to_delete:
        if dry_run:
            print("\n[DRY-RUN] Assets that would be deleted:")
            for a in to_delete:
                print(f"  - {a['name']}")
        else:
            print(f"\nDeleting {len(to_delete)} obsolete assets in parallel...")
            with ThreadPoolExecutor(max_workers=10) as executor:
                futures = [
                    executor.submit(delete_asset, repo, a["id"], a["name"], token)
                    for a in to_delete if a.get("id")
                ]
                for f in futures:
                    f.result()

    # Write current_assets.txt (kept assets + incoming files)
    all_current_assets = sorted(list(to_keep.union(set(incoming_files))))
    with open("current_assets.txt", "w", encoding="utf-8") as f:
        for name in all_current_assets:
            if name:
                f.write(name + "\n")
    print(f"Updated current_assets.txt with {len(all_current_assets)} assets.")

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Clean up old package versions from GitHub Release")
    parser.add_argument("--repo", default=os.getenv("GITHUB_REPOSITORY", "InledGroup/apt"), help="GitHub repository")
    parser.add_argument("--tag", default="packages", help="Release tag name")
    parser.add_argument("--incoming", default="incoming", help="Incoming packages directory")
    parser.add_argument("--dry-run", action="store_true", help="Do not delete assets, only print")
    args = parser.parse_args()

    token = os.getenv("GH_TOKEN") or os.getenv("GITHUB_TOKEN")
    if not token:
        try:
            import subprocess
            token = subprocess.check_output(["gh", "auth", "token"], text=True).strip()
        except Exception:
            token = None

    prune(args.repo, args.tag, token, args.incoming, args.dry_run)
