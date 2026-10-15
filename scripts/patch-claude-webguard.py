#!/usr/bin/env python3
"""Stage the authorized app-local environment guard. Never starts or overwrites the installed app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess

MARKER = b'/*claude-notch-webguard-v1*/'
INJECTION = MARKER + b'try{require(process.resourcesPath+"/claude-notch-webguard.cjs")}catch{};'


# These claims require an Apple-issued team identity and cannot survive an ad-hoc re-sign.
RESTRICTED_LOCAL_ENTITLEMENTS = frozenset({
    'application-identifier', 'com.apple.application-identifier',
    'com.apple.developer.team-identifier', 'keychain-access-groups',
    'com.apple.security.application-groups',
})


def local_entitlements(entitlements):
    return {key: value for key, value in entitlements.items() if key not in RESTRICTED_LOCAL_ENTITLEMENTS}


def sign_local_client(app, working_directory):
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)],
                            capture_output=True, check=True)
    original = plistlib.loads(result.stdout) if result.stdout.strip() else {}
    permissions = local_entitlements(original)
    entitlements_path = working_directory / 'claude-local-entitlements.plist'
    entitlements_path.write_bytes(plistlib.dumps(permissions))
    entitlements_path.chmod(0o600)
    subprocess.run(['codesign', '--force', '--sign', '-', '--options', '0',
                    '--entitlements', str(entitlements_path), str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    signed = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)],
                            capture_output=True, check=True)
    actual = plistlib.loads(signed.stdout) if signed.stdout.strip() else {}
    if RESTRICTED_LOCAL_ENTITLEMENTS.intersection(actual):
        raise ValueError('Apple-restricted entitlement remained in local signature')
    return sorted(set(original) - set(permissions))


def header(stream):
    prefix = stream.read(8)
    if len(prefix) != 8:
        raise ValueError('Invalid ASAR size header')
    payload_size, size = struct.unpack('<II', prefix)
    if payload_size != 4 or not 8 <= size <= 32 * 1024 * 1024:
        raise ValueError('Invalid ASAR header size')
    block = stream.read(size)
    if len(block) != size:
        raise ValueError('Truncated ASAR header')
    text_size = struct.unpack('<I', block[4:8])[0]
    raw = block[8:8 + text_size]
    return json.loads(raw), 8 + size, raw


def entry(tree, name):
    node = tree
    for part in name.split('/'):
        if part in ('', '.', '..'):
            raise ValueError('Invalid archive entry path')
        node = node['files'][part]
    return node


def leaves(tree):
    for node in tree.get('files', {}).values():
        if 'files' in node:
            yield from leaves(node)
        elif 'offset' in node and not node.get('unpacked'):
            yield node


def read_entry(stream, base, node, limit):
    size = int(node['size'])
    if size > limit or node.get('unpacked'):
        raise ValueError('Unexpected entry size or unpacked entry')
    stream.seek(base + int(node['offset']))
    result = stream.read(size)
    if len(result) != size:
        raise ValueError('Truncated archive entry')
    return result


def replace_entry(archive, main_name, info):
    with archive.open('rb') as source:
        tree, base, raw = header(source)
        expected = info.get('ElectronAsarIntegrity', {}).get('Resources/app.asar', {}).get('hash')
        if expected and hashlib.sha256(raw).hexdigest() != expected:
            raise ValueError('Original ASAR header integrity does not match; refusing to patch')
        node = entry(tree, main_name)
        original = read_entry(source, base, node, 8 * 1024 * 1024)
        if not original.startswith(b'"use strict";'):
            raise ValueError('Unsupported bootstrap format; no changes made')
        replacement = original if MARKER in original else original[:13] + INJECTION + original[13:]
        old_offset, old_size = int(node['offset']), int(node['size'])
        difference = len(replacement) - old_size
        for item in leaves(tree):
            if item is not node and int(item['offset']) >= old_offset + old_size:
                item['offset'] = str(int(item['offset']) + difference)
        node['size'] = len(replacement)
        block_size = int(node.get('integrity', {}).get('blockSize', 4194304))
        if not 1024 <= block_size <= 16 * 1024 * 1024:
            raise ValueError('Unexpected ASAR integrity block size')
        node['integrity'] = {
            'algorithm': 'SHA256', 'hash': hashlib.sha256(replacement).hexdigest(), 'blockSize': block_size,
            'blocks': [hashlib.sha256(replacement[start:start + block_size]).hexdigest()
                       for start in range(0, len(replacement), block_size)]
        }
        raw_new = json.dumps(tree, ensure_ascii=False, separators=(',', ':')).encode('utf8')
        payload = struct.pack('<I', len(raw_new)) + raw_new
        payload += b'\0' * (-len(payload) % 4)
        packed_header = struct.pack('<I', len(payload)) + payload
        temporary = archive.with_suffix('.asar.guard-new')
        if temporary.exists():
            raise ValueError('Staging temporary already exists; choose a new staging directory')
        with temporary.open('xb') as output:
            output.write(struct.pack('<II', 4, len(packed_header)))
            output.write(packed_header)
            source.seek(base)
            remaining = old_offset
            while remaining:
                chunk = source.read(min(4 * 1024 * 1024, remaining))
                if not chunk:
                    raise ValueError('Truncated archive payload')
                output.write(chunk)
                remaining -= len(chunk)
            output.write(replacement)
            source.seek(base + old_offset + old_size)
            shutil.copyfileobj(source, output, 4 * 1024 * 1024)
        os.replace(temporary, archive)
    info.setdefault('ElectronAsarIntegrity', {})['Resources/app.asar'] = {
        'algorithm': 'SHA256', 'hash': hashlib.sha256(raw_new).hexdigest()
    }
    return info['ElectronAsarIntegrity']['Resources/app.asar']['hash']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--expected-version', required=True)
    parser.add_argument('--stage-dir', type=Path, required=True)
    args = parser.parse_args()
    source = args.app.resolve()
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') not in ('com.anthropic.claudefordesktop', 'com.anthropic.claude'):
        raise ValueError('Not a Claude client')
    if info.get('CFBundleShortVersionString') != args.expected_version:
        raise ValueError('Claude version changed; inspect the new version before adapting it')
    bridge = Path(__file__).resolve().parents[1] / 'Sources/ClaudeNotch/Resources/Guard/claude-notch-webguard.cjs'
    destination = args.stage_dir.resolve() / 'Claude.app'
    if destination.exists():
        raise ValueError('Destination already exists; choose a new staging directory')
    shutil.copytree(source, destination, symlinks=True)
    resources = destination / 'Contents/Resources'
    archive = resources / 'app.asar'
    with archive.open('rb') as stream:
        tree, base, _ = header(stream)
        package = json.loads(read_entry(stream, base, entry(tree, 'package.json'), 1024 * 1024))
    if package.get('type') == 'module':
        raise ValueError('ESM bootstrap requires a separate adapter')
    main_name = package['main']
    digest = replace_entry(archive, main_name, info)
    shutil.copy2(bridge, resources / bridge.name)
    manifest = {'protocol': 1, 'appVersion': args.expected_version,
                'bridgeSHA256': hashlib.sha256(bridge.read_bytes()).hexdigest(),
                'mainEntry': main_name, 'asarHeaderSHA256': digest}
    (resources / 'claude-notch-webguard.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (destination / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    # Keep compatible runtime permissions, not official-team/keychain access claims.
    # Vendor-signed nested frameworks and ASAR checking remain unchanged.
    removed = sign_local_client(destination, args.stage_dir.resolve())
    print(json.dumps({'stage': str(destination), 'version': args.expected_version, 'removedRestrictedEntitlements': removed, **manifest}, indent=2))


if __name__ == '__main__':
    main()
