import os
import re
import sys
import hashlib

def get_file_stats(path):
    """Calcula el tamaño y hashes (MD5, SHA1, SHA256, SHA512) de un archivo."""
    with open(path, 'rb') as f:
        data = f.read()
    return {
        'size': len(data),
        'md5': hashlib.md5(data).hexdigest(),
        'sha1': hashlib.sha1(data).hexdigest(),
        'sha256': hashlib.sha256(data).hexdigest(),
        'sha512': hashlib.sha512(data).hexdigest()
    }

def patch_packages_file(packages_path, release_url_base):
    """Parchea el archivo Packages para que Filename apunte a una URL absoluta."""
    if not os.path.exists(packages_path):
        return None

    with open(packages_path, 'r') as f:
        content = f.read()

    blocks = content.split('\n\n')
    new_blocks = []

    for block in blocks:
        if not block.strip(): continue
        # Buscar el campo Filename y reemplazarlo por la URL absoluta
        match = re.search(r'^Filename: (.*)$', block, re.MULTILINE)
        if match:
            old_filename = match.group(1)
            # Solo tomamos el nombre del archivo (ej: appinstall_1.0_all.deb)
            basename = os.path.basename(old_filename)
            new_filename = f"{release_url_base}/{basename}"
            block = re.sub(r'^Filename: .*$', f"Filename: {new_filename}", block, flags=re.MULTILINE)
        new_blocks.append(block)

    patched_content = '\n\n'.join(new_blocks).strip() + '\n\n'
    with open(packages_path, 'w') as f:
        f.write(patched_content)
    
    print(f"  - Parcheado {packages_path}")
    return True

def update_release_file(release_path):
    """Actualiza el archivo Release recalculando hashes y eliminando archivos inexistentes."""
    if not os.path.exists(release_path): return
    
    with open(release_path, 'r') as f:
        lines = f.readlines()
    
    release_dir = os.path.dirname(release_path)
    new_lines = []
    current_section = None
    
    # Mapeo de cabeceras de sección a claves de stats
    sections = {
        'MD5Sum:': 'md5',
        'SHA1:': 'sha1',
        'SHA256:': 'sha256',
        'SHA512:': 'sha512'
    }
    
    for line in lines:
        stripped = line.strip()
        
        # Detectar si entramos en una sección de hashes
        found_section = False
        for s_header, s_key in sections.items():
            if line.startswith(s_header):
                current_section = s_key
                new_lines.append(line)
                found_section = True
                break
        if found_section: continue
        
        # Si la línea no empieza con espacio, salimos de la sección de hashes
        if not line.startswith(' '):
            current_section = None
            new_lines.append(line)
            continue
            
        # Si estamos en una sección de hashes, procesar la línea
        if current_section and line.startswith(' '):
            parts = stripped.split()
            if len(parts) == 3:
                # El formato es: <hash> <size> <path_relativo_a_Release>
                file_rel_path = parts[2]
                full_path = os.path.join(release_dir, file_rel_path)
                
                if os.path.exists(full_path):
                    # El archivo existe, recalculamos sus stats
                    stats = get_file_stats(full_path)
                    new_lines.append(f" {stats[current_section]} {stats['size']} {file_rel_path}\n")
                else:
                    # El archivo NO existe (ej: Packages.gz borrado), lo omitimos
                    print(f"  - Eliminando referencia a archivo inexistente en Release: {file_rel_path}")
                    continue
            else:
                new_lines.append(line)
        else:
            new_lines.append(line)
            
    with open(release_path, 'w') as f:
        f.writelines(new_lines)
    print(f"  - Actualizado {release_path}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Uso: python3 patch-packages.py <base_dir> <release_url>")
        sys.exit(1)
        
    base_dir = sys.argv[1]
    release_url = sys.argv[2]
    
    print(f"Iniciando parcheo de metadatos en {base_dir}...")
    
    # 1. Parchear todos los archivos Packages y borrar versiones comprimidas
    for root, dirs, files in os.walk(base_dir):
        if "Packages" in files:
            pkg_path = os.path.join(root, "Packages")
            patch_packages_file(pkg_path, release_url)
            
            # Borrar versiones comprimidas que no hemos parcheado
            # (Si no se borran, APT intentará usarlas y fallará por desincronización)
            for ext in [".gz", ".bz2", ".lzma", ".xz"]:
                comp_path = pkg_path + ext
                if os.path.exists(comp_path):
                    print(f"  - Borrando {comp_path}...")
                    os.remove(comp_path)

    # 2. Actualizar todos los archivos Release
    for root, dirs, files in os.walk(base_dir):
        if "Release" in files:
            release_path = os.path.join(root, "Release")
            update_release_file(release_path)

    print("Proceso de parcheo completado.")
