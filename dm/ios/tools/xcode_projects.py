"""Per-game Xcode signing settings and a workspace containing prepared games."""
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET


def signing_settings(project):
    """Read only the app's Release signing settings, including changes made in Xcode."""
    pbx = Path(project) / 'project.pbxproj'
    if not pbx.is_file(): return {}
    result = subprocess.run(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(pbx)], capture_output=True, text=True)
    if result.returncode: raise ValueError(f'cannot read Xcode project: {pbx}')
    objects = json.loads(result.stdout)['objects']
    target = next((v for v in objects.values() if v.get('isa') == 'PBXNativeTarget' and v.get('name') == 'DmIOS'), None)
    if not target: return {}
    configs = objects[target['buildConfigurationList']]['buildConfigurations']
    settings = next((objects[c]['buildSettings'] for c in configs if objects[c]['name'] == 'Release'), {})
    return {k: settings[k] for k in ('PRODUCT_BUNDLE_IDENTIFIER', 'DEVELOPMENT_TEAM') if isinstance(settings.get(k), str)}


def workspace_tree(workspace):
    path = Path(workspace) / 'contents.xcworkspacedata'
    try:
        return ET.parse(path) if path.exists() else ET.ElementTree(ET.Element('Workspace', version='1.0'))
    except ET.ParseError as e:
        raise ValueError(f'cannot read workspace {path}: {e}') from e


def workspace_projects(workspace):
    for ref in workspace_tree(workspace).iter('FileRef'):
        kind, _, path = ref.get('location', '').partition(':')
        if kind == 'absolute': yield Path(path).resolve()


def prune_unreadable(workspace):
    """Remove workspace entries the current user cannot access, and save the file.

    The workspace records absolute paths, and the launcher's saved state crosses accounts on a
    shared Mac: a new user's build inherits the first user's entries and dies with PermissionError
    when it stats them. A project this user cannot read is not this user's project — removing the
    entry is the fix, not a message telling them to edit XML."""
    path = Path(workspace) / 'contents.xcworkspacedata'
    if not path.exists(): return 0
    tree = workspace_tree(workspace)
    removed = 0
    for group in tree.iter('Group'):
        for ref in list(group.findall('FileRef')):
            kind, _, loc = ref.get('location', '').partition(':')
            if kind != 'absolute': continue
            try:
                Path(loc).exists()
                continue   # the current user can read it: a real project, not a stale entry
            except (PermissionError, OSError):
                pass
            group.remove(ref)
            removed += 1
    if removed:
        tree.write(str(path), xml_declaration=True, encoding='unicode')
        print(f'[NOTE] removed {removed} workspace entr{"y" if removed == 1 else "ies"} the current user cannot read (registered by another macOS user)')
    return removed


def check_bundle_id(workspace, project, bundle_id):
    prune_unreadable(workspace)
    for other in workspace_projects(workspace):
        if other == Path(project).resolve() or not other.exists(): continue
        try:
            used = signing_settings(other).get('PRODUCT_BUNDLE_IDENTIFIER', '')
        except (PermissionError, OSError):
            continue
        if used.lower() == bundle_id.lower():
            raise ValueError(f'bundle ID {bundle_id} is already used by {other}; choose a different --bundle-id for this game')


def register_project(workspace, project, name, derived):
    """Add/update one project without replacing the other games or workspace settings."""
    from gen_resources import workspace_settings
    workspace, project = Path(workspace), Path(project).resolve()
    tree = workspace_tree(workspace)
    location = f'absolute:{project}'
    group = next((g for g in tree.getroot().findall('Group') if any(r.get('location') == location for r in g.findall('FileRef'))), None)
    if group is None:
        group = ET.SubElement(tree.getroot(), 'Group', location='container:')
        ET.SubElement(group, 'FileRef', location=location)
    group.set('name', name)
    workspace.mkdir(parents=True, exist_ok=True)
    ET.indent(tree, space='   ')
    path = workspace / 'contents.xcworkspacedata'
    temp = path.with_suffix('.tmp')
    tree.write(temp, encoding='utf-8', xml_declaration=True)
    temp.replace(path)
    workspace_settings(workspace, derived)
