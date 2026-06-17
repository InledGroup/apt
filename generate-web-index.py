#!/usr/bin/python3
import os
import re
import subprocess

def get_apt_packages(repo_name):
    packages = []
    try:
        output = subprocess.check_output(["aptly", "-config=aptly.conf", "repo", "show", "-with-packages", repo_name], text=True)
        # Buscar la sección de paquetes
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
                # Formato: name_version_arch
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
        print(f"Error obteniendo paquetes APT: {e}")
    return packages

def get_rpm_packages(rpm_dir):
    packages = []
    if not os.path.exists(rpm_dir): return packages
    for f in os.listdir(rpm_dir):
        if f.endswith(".rpm"):
            # Intento simple de extraer nombre y versión
            # Formato común: name-version-release.arch.rpm
            match = re.match(r"^(.+)-([^-]+)-([^-]+)\.([^.]+)\.rpm$", f)
            if match:
                packages.append({
                    "name": match.group(1),
                    "version": match.group(2),
                    "arch": match.group(4),
                    "type": "rpm",
                    "file": f
                })
            else:
                # Fallback
                packages.append({
                    "name": f.split("-")[0],
                    "version": "unknown",
                    "arch": "unknown",
                    "type": "rpm",
                    "file": f
                })
    return packages

def get_arch_packages(arch_dir):
    packages = []
    if not os.path.exists(arch_dir): return packages
    for f in os.listdir(arch_dir):
        if f.endswith(".pkg.tar.zst") or f.endswith(".pkg.tar.xz"):
            # Formato común: name-version-release-arch.pkg.tar.zst
            match = re.match(r"^(.+)-([^-]+)-([^-]+)-([^.]+)\.pkg\.tar\..+$", f)
            if match:
                packages.append({
                    "name": match.group(1),
                    "version": match.group(2),
                    "arch": match.group(4),
                    "type": "arch",
                    "file": f
                })
            else:
                packages.append({
                    "name": f.split("-")[0],
                    "version": "unknown",
                    "arch": "unknown",
                    "type": "arch",
                    "file": f
                })
    return packages

def generate_html(release_url):
    apt_pkgs = get_apt_packages("inled-repo")
    rpm_pkgs = get_rpm_packages("public/rpm")
    arch_pkgs = get_arch_packages("public/arch")
    
    all_pkgs = apt_pkgs + rpm_pkgs + arch_pkgs
    
    # Agrupar por nombre
    grouped = {}
    for pkg in all_pkgs:
        name = pkg["name"]
        if name not in grouped:
            grouped[name] = {"versions": {}}
        
        version = pkg["version"]
        if version not in grouped[name]["versions"]:
            grouped[name]["versions"][version] = []
        
        grouped[name]["versions"][version].append(pkg)
    
    packages_html = ""
    
    if not grouped:
        packages_html = '<p style="grid-column: 1/-1; text-align: center; color: var(--text-muted);">No hay paquetes disponibles en este momento.</p>'
    else:
        for name in sorted(grouped.keys()):
            # Usar la versión más reciente (simplificado)
            versions = sorted(grouped[name]["versions"].keys(), reverse=True)
            latest_ver = versions[0]
            pkgs = grouped[name]["versions"][latest_ver]
            
            desc = f"Paquete para {name}"
            if name == "appinstall": desc = "Gestor de aplicaciones multiplataforma"
            if name == "seafari": desc = "Navegador web optimizado"
            
            item_html = f'<li class="package-item">'
            item_html += f'<div class="package-header">'
            item_html += f'<span class="package-name">{name}</span>'
            item_html += f'<span class="package-version">v{latest_ver}</span>'
            item_html += f'</div>'
            item_html += f'<p class="package-desc">{desc}</p>'
            item_html += f'<div class="package-footer">'
            
            # Botones para cada tipo disponible
            for pkg in sorted(pkgs, key=lambda x: (x["type"], x["arch"])):
                label = ""
                css_class = ""
                arch_label = f' ({pkg["arch"]})' if pkg["arch"] != "unknown" else ""
                
                if pkg["type"] == "deb":
                    label = f"deb{arch_label}"
                    css_class = "btn-deb"
                elif pkg["type"] == "rpm":
                    label = f"rpm{arch_label}"
                    css_class = "btn-rpm"
                elif pkg["type"] == "arch":
                    label = f"arch{arch_label}"
                    css_class = "btn-arch"
                
                download_url = f"{release_url}/{pkg['file']}"
                item_html += f'<a href="{download_url}" class="btn btn-sm {css_class}">⬇️ {label}</a>'
            
            item_html += f'</div></li>'
            packages_html += item_html

    # Leer plantilla y reemplazar
    with open("index.html.template", "r") as f:
        template = f.read()
    
    final_html = template.replace("<!-- PACKAGES_LIST_PLACEHOLDER -->", packages_html)
    final_html = final_html.replace("<KEY_ID>", "repo@inled.es")
    
    with open("public/index.html", "w") as f:
        f.write(final_html)

if __name__ == "__main__":
    import sys
    release_url = sys.argv[1] if len(sys.argv) > 1 else "https://github.com/inled-es/aptrepo/releases/download/packages"
    generate_html(release_url)
