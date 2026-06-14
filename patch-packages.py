import os
import sys

def generate_redirects(base_dir, release_url):
    """
    Generates a Cloudflare Pages _redirects file mapping local pool paths to GitHub Releases.
    Genera un archivo _redirects para Cloudflare Pages mapeando las rutas locales a GitHub Releases.
    """
    redirects_path = os.path.join(base_dir, "_redirects")
    
    # We overwrite the file or create it if it doesn't exist
    # Sobrescribimos el archivo o lo creamos si no existe
    with open(redirects_path, "w", encoding="utf-8") as f:
        f.write("# Cloudflare Pages Redirects for Inled Repo\n")
        f.write("# Forcing APT and DNF to follow GitHub Releases\n\n")
        
        # 1. Process APT pool (Debian/Ubuntu)
        pool_dir = os.path.join(base_dir, "pool")
        if os.path.exists(pool_dir):
            print(f"Scanning APT pool: {pool_dir}")
            for root, dirs, files in os.walk(pool_dir):
                for file in files:
                    if file.endswith(".deb"):
                        full_path = os.path.join(root, file)
                        # Get path relative to the public root (e.g. pool/main/a/...)
                        rel_path = os.path.relpath(full_path, base_dir)
                        # Cloudflare format: /source-path target-url 302
                        f.write(f"/{rel_path} {release_url}/{file} 302\n")
                        print(f"  + Redirect: /{rel_path} -> {file}")

        # 2. Process RPM packages (Fedora/RHEL)
        # Even if we don't delete the RPM dir, redirects ensure they always get the latest from GitHub
        rpm_dir = os.path.join(base_dir, "rpm")
        if os.path.exists(rpm_dir):
            print(f"Scanning RPM directory: {rpm_dir}")
            for file in os.listdir(rpm_dir):
                if file.endswith(".rpm"):
                    f.write(f"/rpm/{file} {release_url}/{file} 302\n")
                    print(f"  + Redirect: /rpm/{file} -> {file}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 patch-packages.py <base_dir> <release_url>")
        sys.exit(1)
        
    base_dir = sys.argv[1]
    # Clean trailing slash from release_url
    release_url = sys.argv[2].rstrip('/')
    
    print(f"--- Starting redirect generation for {base_dir} ---")
    generate_redirects(base_dir, release_url)
    print("--- Redirect generation completed ---")
    
    # Note: We no longer patch the Packages files or delete compressed versions here.
    # The original aptly files are now correct as we serve them via redirects.
    # Nota: Ya no parcheamos los archivos Packages ni borramos las versiones comprimidas aquí.
    # Los archivos originales de aptly ahora son correctos ya que servimos vía redirecciones.
