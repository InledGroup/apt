import os
import re
import sys

def generate_redirects_from_packages(base_dir, release_url):
    """
    Scans Packages files in dists/ to generate Cloudflare redirects.
    Escanea los archivos Packages en dists/ para generar las redirecciones de Cloudflare.
    """
    redirects = []
    
    print(f"Scanning for Packages files in {base_dir}/dists...")
    for root, dirs, files in os.walk(os.path.join(base_dir, "dists")):
        if "Packages" in files:
            pkg_path = os.path.join(root, "Packages")
            print(f"  Processing {pkg_path}")
            with open(pkg_path, "r", encoding="utf-8") as f:
                content = f.read()
            
            # Find all Filename entries
            # Encontrar todas las entradas Filename
            matches = re.findall(r'^Filename: (.*)$', content, re.MULTILINE)
            for local_path in matches:
                filename = os.path.basename(local_path)
                # Source path is the local path (e.g. pool/main/a/appinstall/...)
                # Target path is the GitHub Release URL
                redirects.append(f"/{local_path} {release_url}/{filename} 302")
                print(f"    + Found package: {filename}")

    if not redirects:
        print("No packages found in Packages files. Redirects might be empty.")
        return

    redirects_path = os.path.join(base_dir, "_redirects")
    with open(redirects_path, "w", encoding="utf-8") as f:
        f.write("# Cloudflare Pages Redirects for Inled Repo\n")
        f.write("# Generated automatically from Packages metadata\n\n")
        # Sort and unique redirects
        for redir in sorted(list(set(redirects))):
            f.write(redir + "\n")
    
    print(f"Successfully generated {len(redirects)} unique redirects in {redirects_path}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 patch-packages.py <base_dir> <release_url>")
        sys.exit(1)
        
    base_dir = sys.argv[1]
    release_url = sys.argv[2].rstrip('/')
    
    print(f"--- Starting redirect generation (Metadata-based) ---")
    generate_redirects_from_packages(base_dir, release_url)
    print("--- Redirect generation completed ---")
