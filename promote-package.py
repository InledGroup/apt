#!/usr/bin/env python3
"""
Pulsar OS / Inled Repository - Package Promotion Tool
Promotes a package from unstable to stable distribution.
"""

import sys
import os
import json
import subprocess
import argparse

def promote_package(pkg_name, repo="InledGroup/apt"):
    print(f"📦 Promoting '{pkg_name}' from unstable to stable in {repo}...")
    
    db_file = "packages.json"
    if not os.path.exists(db_file):
        print(f"❌ Error: {db_file} not found.")
        sys.exit(1)
        
    with open(db_file, "r", encoding="utf-8") as f:
        data = json.load(f)
        
    targets = [name for name in data if pkg_name == "all" or name == pkg_name]
    if not targets:
        print(f"❌ Error: Package '{pkg_name}' not found in database.")
        sys.exit(1)
        
    promoted_files = []
    
    for t in targets:
        versions = data[t].get("versions", {})
        for ver, pkgs in versions.items():
            for p in pkgs:
                filename = p.get("file")
                branch = p.get("branch")
                if branch in ("unstable", "rolling", "forky") or "unstable" in filename:
                    promoted_files.append((p, filename))
                    
    print(f"Found {len(promoted_files)} package file(s) to evaluate for promotion.")
    for p, fn in promoted_files:
        print(f"  - {fn} (Type: {p.get('type')}, Current branch: {p.get('branch')})")

    for p, fn in promoted_files:
        if p.get("type") == "deb":
            local_path = os.path.join("incoming", fn)
            if os.path.exists(local_path):
                print(f"Adding {fn} to stable aptly repo...")
                subprocess.run(["aptly", "-config=aptly.conf", "repo", "add", "-force-replace", "inled-repo", local_path], check=False)

    print("✅ Package promotion complete. Run update-repo.sh to rebuild repository indexes and deploy.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Promote package(s) from unstable to stable")
    parser.add_argument("package_name", nargs="?", default="all", help="Name of the package or 'all'")
    args = parser.parse_args()
    promote_package(args.package_name)
