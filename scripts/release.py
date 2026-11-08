#!/usr/bin/env python3
"""Build packages locally and publish a signed GitHub/Sparkle release."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from email.utils import format_datetime

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = 'liquorice-head/forma-app'
KEY_ACCOUNT = 'app.forma.updates'
SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'

def run(*args, capture=False, **kwargs):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None, **kwargs)
    return result.stdout.strip() if capture else None

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def archive(app, output):
    output.unlink(missing_ok=True)
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, output)

def notarize(path, profile):
    response = json.loads(run('xcrun', 'notarytool', 'submit', path, '--keychain-profile', profile,
                             '--wait', '--timeout', '20m', '--output-format', 'json', capture=True))
    if response.get('status') != 'Accepted':
        raise RuntimeError(f"Notarization was not accepted. Review submission {response.get('id', '(unknown)')}.")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preview', action='store_true', help='Explicitly create a development-signed, non-notarized preview')
    parser.add_argument('--publish', action='store_true', help='Upload packages and signed appcast to a GitHub Release')
    parser.add_argument('--notary-profile', default=os.environ.get('FORMA_NOTARY_PROFILE'))
    parser.add_argument('--notes', type=Path, help='Release notes Markdown file')
    options = parser.parse_args()
    if not options.preview and not options.notary_profile:
        parser.error('A notarization profile is required, or explicitly use --preview for personal testing.')
    if options.publish and run('git', 'status', '--porcelain', '--untracked-files=normal', capture=True):
        parser.error('Commit the intended source changes before publishing. Ignored working files are allowed.')
    existing = None
    if options.publish:
        version = plistlib.loads((ROOT / 'scripts/Info.plist').read_bytes())['CFBundleShortVersionString']
        releases = json.loads(run('gh', 'api', f'repos/{REPOSITORY}/releases?per_page=100', capture=True))
        existing = next((release for release in releases if release['tag_name'] == 'v' + version), None)
        if existing and not existing['draft']:
            parser.error('This version is already published. Increase the version and build number before releasing.')
        if existing and existing['target_commitish'] != run('git', 'rev-parse', 'HEAD', capture=True):
            parser.error('The existing draft targets another commit. Review that draft before retrying.')
    env = os.environ.copy()
    env['FORMA_DISTRIBUTION'] = '0' if options.preview else '1'
    run('zsh', 'scripts/build-app.sh', 'release', env=env)
    app = ROOT / 'dist/Forma.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    tag = 'v' + version
    tools = ROOT / '.build/artifacts/sparkle/Sparkle/bin'
    public_key = run(tools / 'generate_keys', '--account', KEY_ACCOUNT, '-p', capture=True)
    if public_key != info['SUPublicEDKey']:
        raise RuntimeError('The local update signing key does not match SUPublicEDKey. Refusing to publish.')
    signature = subprocess.run(['codesign', '-dv', '--verbose=2', str(app)], capture_output=True, text=True, check=True).stderr
    if 'Signature=adhoc' in signature:
        raise RuntimeError('An ad-hoc signed app cannot be released.')
    if not options.preview and 'Developer ID Application:' not in signature:
        raise RuntimeError('A normal release must use a Developer ID Application certificate.')
    output = ROOT / 'dist' / tag
    output.mkdir(parents=True, exist_ok=True)
    zip_file = output / f'Forma-{version}-Apple-Silicon.zip'
    dmg_file = output / f'Forma-{version}-Apple-Silicon.dmg'
    archive(app, zip_file)
    if not options.preview:
        notarize(zip_file, options.notary_profile)
        run('xcrun', 'stapler', 'staple', app)
        archive(app, zip_file)
    with tempfile.TemporaryDirectory(prefix='forma-dmg-') as directory:
        staging = Path(directory)
        run('ditto', app, staging / 'Forma.app')
        (staging / 'Applications').symlink_to('/Applications')
        instructions = 'Drag Forma to Applications. Requires Apple Silicon and macOS 26+.\n'
        if options.preview:
            instructions += 'Developer preview: signed for development, not notarized by Apple. macOS may require manual approval of the first launch.\n'
        (staging / 'Read Me.txt').write_text(instructions)
        dmg_file.unlink(missing_ok=True)
        run('hdiutil', 'create', '-volname', 'Forma', '-srcfolder', staging, '-format', 'UDZO', dmg_file)
    if not options.preview:
        identity = os.environ.get('FORMA_SIGN_IDENTITY') or (ROOT / '.forma-signing-identity').read_text().strip()
        run('codesign', '--force', '--timestamp', '--sign', identity, dmg_file)
        notarize(dmg_file, options.notary_profile)
        run('xcrun', 'stapler', 'staple', dmg_file)
        run('spctl', '--assess', '--type', 'execute', app)
    checksum_file = output / 'SHA256SUMS.txt'
    checksum_file.write_text(''.join(f'{sha(file)}  {file.name}\n' for file in [zip_file, dmg_file]))
    commit = run('git', 'rev-parse', 'HEAD', capture=True)
    manifest = output / 'release-manifest.json'
    manifest.write_text(json.dumps({'version': version, 'build': build, 'commit': commit,
        'architecture': 'arm64', 'minimumMacOS': '26.0', 'notarized': not options.preview,
        'sha256': {file.name: sha(file) for file in [zip_file, dmg_file]}}, indent=2) + '\n')
    signature = run(tools / 'sign_update', '--account', KEY_ACCOUNT, '-p', zip_file, capture=True)
    run(tools / 'sign_update', '--account', KEY_ACCOUNT, '--verify', zip_file, signature)
    if not options.publish:
        print(f'Prepared {output}. Run again with --publish after committing and pushing the source.')
        return
    # Validate that the target is already reachable in the intended remote repository.
    run('gh', 'api', f'repos/{REPOSITORY}/commits/{commit}', '--silent')
    notes = options.notes or output / 'release-notes.md'
    if not options.notes:
        notes.write_text(f'Forma {version} for Apple Silicon, macOS 26+.\n\n'
            + ('**Developer preview:** development-signed and not notarized. Intended for personal testing. macOS may require manual approval on first launch.\n\n' if options.preview else '')
            + 'Install using the DMG. The ZIP and signed appcast are used by the built-in updater.\n\n'
            + 'Public automatic updates do not require a GitHub token. ChatGPT sign-in and Accessibility are configured separately on each Mac.\n')
    args = ['gh', 'release', 'create', tag, '--repo', REPOSITORY, '--target', commit,
            '--title', f'Forma {version}', '--draft', '--notes-file', str(notes)]
    if options.preview: args.append('--prerelease')
    if not existing: run(*args)
    run('gh', 'release', 'upload', tag, zip_file, dmg_file, checksum_file, manifest, '--clobber', '--repo', REPOSITORY)
    release_id = run('gh', 'release', 'view', tag, '--repo', REPOSITORY, '--json', 'databaseId', '--jq', '.databaseId', capture=True)
    release = json.loads(run('gh', 'api', f'repos/{REPOSITORY}/releases/{release_id}', capture=True))
    asset = next(a for a in release['assets'] if a['name'] == zip_file.name)
    ET.register_namespace('sparkle', SPARKLE_NS)
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'Forma updates'
    ET.SubElement(channel, 'link').text = f'https://github.com/{REPOSITORY}/releases'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'Forma {version}'
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.datetime.now(datetime.timezone.utc), usegmt=True)
    ET.SubElement(item, f'{{{SPARKLE_NS}}}version').text = build
    ET.SubElement(item, f'{{{SPARKLE_NS}}}shortVersionString').text = version
    ET.SubElement(item, f'{{{SPARKLE_NS}}}minimumSystemVersion').text = '26.0'
    if options.preview: ET.SubElement(item, f'{{{SPARKLE_NS}}}channel').text = 'preview'
    ET.SubElement(item, 'description').text = f'Forma {version}. Native translation and writing tools for macOS.'
    ET.SubElement(item, 'enclosure', attrib={
        'url': f'https://api.github.com/repos/{REPOSITORY}/releases/assets/{asset["id"]}',
        'length': str(zip_file.stat().st_size), 'type': 'application/octet-stream',
        f'{{{SPARKLE_NS}}}edSignature': signature})
    feed = output / 'appcast.xml'
    ET.ElementTree(rss).write(feed, encoding='utf-8', xml_declaration=True)
    run(tools / 'sign_update', '--account', KEY_ACCOUNT, feed)
    run(tools / 'sign_update', '--account', KEY_ACCOUNT, '--verify', feed)
    run('gh', 'release', 'upload', tag, feed, '--clobber', '--repo', REPOSITORY)
    # Nothing is published until all archives and the signed feed exist.
    run('gh', 'release', 'edit', tag, '--draft=false', '--repo', REPOSITORY)
    print(f'Published https://github.com/{REPOSITORY}/releases/tag/{tag}')

if __name__ == '__main__':
    main()
