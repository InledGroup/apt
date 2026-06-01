#!/usr/bin/python3
import os
import html
from datetime import datetime

# Estilo CSS para el listado de directorios
CSS = """
body { font-family: monospace; padding: 20px; }
h1 { border-bottom: 1px solid #ccc; padding-bottom: 10px; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: 5px 10px; }
tr:hover { background-color: #f5f5f5; }
.back-link { margin-bottom: 20px; display: block; }
"""

def generate_index(path, relative_url):
    items = sorted(os.listdir(path))
    
    # Filtrar archivos ocultos e index.html
    items = [i for i in items if not i.startswith('.') and i != 'index.html']
    
    html_content = f"""<!DOCTYPE html>
<html>
<head>
    <title>Index of {relative_url}</title>
    <style>{CSS}</style>
</head>
<body>
    <h1>Index of {relative_url}</h1>
    {f'<a class="back-link" href="..">Parent Directory</a>' if relative_url != "/" else ""}
    <table>
        <thead>
            <tr>
                <th>Name</th>
                <th>Last Modified</th>
                <th>Size</th>
            </tr>
        </thead>
        <tbody>
"""
    
    for item in items:
        full_path = os.path.join(path, item)
        is_dir = os.path.isdir(full_path)
        display_name = item + ('/' if is_dir else '')
        
        stat = os.stat(full_path)
        last_mod = datetime.fromtimestamp(stat.st_mtime).strftime('%Y-%m-%d %H:%M:%S')
        size = f"{stat.st_size:,} B" if not is_dir else "-"
        
        html_content += f"""
            <tr>
                <td><a href="{item}{'/' if is_dir else ''}">{display_name}</a></td>
                <td>{last_mod}</td>
                <td>{size}</td>
            </tr>"""
            
    html_content += """
        </tbody>
    </table>
</body>
</html>
"""
    with open(os.path.join(path, "index.html"), "w") as f:
        f.write(html_content)

def walk_and_index(base_dir):
    for root, dirs, files in os.walk(base_dir):
        relative_url = root.replace(base_dir, "")
        if not relative_url: relative_url = "/"
        print(f"Generando índice para {relative_url}...")
        generate_index(root, relative_url)

if __name__ == "__main__":
    import sys
    target = sys.argv[1] if len(sys.argv) > 1 else "public"
    if os.path.exists(target):
        walk_and_index(target)
    else:
        print(f"Error: El directorio {target} no existe.")
