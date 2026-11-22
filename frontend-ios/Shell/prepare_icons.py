#!/usr/bin/env python3
"""Keep unsigned device builds usable without an iOS Simulator runtime."""
import json
from pathlib import Path
import subprocess
import sys


def has_ios_runtime():
    try:
        result = subprocess.run(
            ['xcrun', 'simctl', 'list', 'runtimes', '--json'],
            capture_output=True, text=True, timeout=15, check=False,
        )
        if result.returncode:
            return False
        return any(
            runtime.get('isAvailable') is True
            and runtime.get('identifier', '').startswith('com.apple.CoreSimulator.SimRuntime.iOS-')
            for runtime in json.loads(result.stdout).get('runtimes', [])
        )
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False


def prepare_icons(spec, package):
    """Use the existing Icon Composer document where actool can render it, otherwise ordinary PNG resources."""
    if has_ios_runtime():
        return False
    spec, package = Path(spec), Path(package)
    icons = spec.parent / 'Gen' / 'LegacyIcons'
    icons.mkdir(parents=True, exist_ok=True)
    for name, size in (
        ('AppIcon60x60@2x.png', 120), ('AppIcon60x60@3x.png', 180),
        ('AppIcon76x76@2x.png', 152), ('AppIcon83.5x83.5@2x.png', 167),
    ):
        subprocess.run(
            ['/usr/bin/sips', '-z', str(size), str(size), str(package / 'AppIcon.png'), '--out', str(icons / name)],
            stdout=subprocess.DEVNULL, check=True,
        )
    lines = []
    for line in spec.read_text().splitlines():
        stripped = line.lstrip()
        indent = line[:len(line) - len(stripped)]
        if stripped.startswith('- path: Gen/Assets.xcassets') or stripped.startswith('ASSETCATALOG_COMPILER_APPICON_NAME:'):
            continue
        if stripped.startswith('- path: ${DM_SHELL_PACKAGE}/AppIcon.icon'):
            lines.extend([indent + '- path: Gen/LegacyIcons', indent + '  buildPhase: resources'])
            continue
        lines.append(line)
        if stripped.startswith('CFBundleDisplayName:'):
            lines.extend([
                indent + 'CFBundleIcons:',
                indent + '  CFBundlePrimaryIcon:',
                indent + '    CFBundleIconFiles: [AppIcon60x60]',
                indent + 'CFBundleIcons~ipad:',
                indent + '  CFBundlePrimaryIcon:',
                indent + '    CFBundleIconFiles: [AppIcon60x60, AppIcon76x76, AppIcon83.5x83.5]',
            ])
    spec.write_text('\n'.join(lines) + '\n')
    return True


if __name__ == '__main__':
    if prepare_icons(*sys.argv[1:]):
        print('shell: no iOS Simulator runtime, using the static app icon')
