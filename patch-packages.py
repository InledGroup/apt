#!/usr/bin/python3
import os
import re
import sys
import tempfile

def generate_redirects_from_packages(base_dir, release_url):
    redirects = []

    print(f"Scanning for Packages files in {base_dir}/dists...")
    for root, dirs, files in os.walk(os.path.join(base_dir, "dists")):
        if "Packages" in files:
            pkg_path = os.path.join(root, "Packages")
            print(f"  Processing {pkg_path}")
            with open(pkg_path, "r", encoding="utf-8") as f:
                content = f.read()

            matches = re.findall(r'^Filename: (.*)$', content, re.MULTILINE)
            for local_path in matches:
                filename = os.path.basename(local_path)
                # Replace '+' with '%2b' in the source path to match URL-encoded requests from apt
                cf_source = local_path.replace("+", "%2b")
                redirects.append(f"/{cf_source} {release_url}/{filename} 302")
                print(f"    + Found package: {filename}")

    if not redirects:
        print("No packages found in Packages files. Redirects might be empty.")
        return []

    unique = sorted(list(set(redirects)))
    print(f"Generated {len(unique)} unique redirects")
    return unique

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 patch-packages.py <base_dir> <release_url>")
        sys.exit(1)

    base_dir = sys.argv[1]
    release_url = sys.argv[2].rstrip('/')

    print("--- Starting redirect generation (Metadata-based) ---")
    redirects = generate_redirects_from_packages(base_dir, release_url)

    redirects_path = os.path.join(base_dir, "_redirects")
    tmp_path = redirects_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write("# Cloudflare Pages Redirects for Inled Repo\n")
        f.write("# Generated automatically from Packages metadata\n\n")
        for redir in redirects:
            f.write(redir + "\n")
    os.replace(tmp_path, redirects_path)
    print(f"Written {len(redirects)} redirects to {redirects_path}")
    print("--- Redirect generation completed ---")
