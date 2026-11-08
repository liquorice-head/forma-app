#!/usr/bin/env python3
"""Validate a local Developer ID profile and derive minimal CloudKit entitlements."""
import argparse
import datetime
import hashlib
import plistlib
import re
import subprocess
from pathlib import Path


def derive(profile, bundle, identity, container):
    data = plistlib.loads(subprocess.run(['security', 'cms', '-D', '-i', str(profile)], check=True, capture_output=True).stdout)
    entitlements = data['Entitlements']
    team = data['TeamIdentifier'][0]
    prefix = data['ApplicationIdentifierPrefix'][0]
    application = entitlements.get('com.apple.application-identifier', entitlements.get('application-identifier'))
    if application != prefix + '.' + bundle:
        raise ValueError('The CloudKit profile does not authorize this exact bundle identifier.')
    if entitlements.get('get-task-allow') or entitlements.get('com.apple.security.get-task-allow'):
        raise ValueError('Use a Developer ID distribution profile, not a development profile.')
    if data['ExpirationDate'].replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError('The CloudKit profile has expired.')
    if container not in entitlements.get('com.apple.developer.icloud-container-identifiers', []):
        raise ValueError('The CloudKit container is not authorized by this profile.')
    services = entitlements.get('com.apple.developer.icloud-services', [])
    if isinstance(services, str):
        services = [services]
    if not any(service in services for service in ['CloudKit', '*']):
        raise ValueError('CloudKit is not authorized by this profile.')
    environment = entitlements.get('com.apple.developer.icloud-container-environment', [])
    if isinstance(environment, str):
        environment = [environment]
    if 'Production' not in environment:
        raise ValueError('The CloudKit profile does not authorize the production environment.')
    identities = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], check=True, capture_output=True, text=True).stdout
    available = re.findall(r'([0-9A-Fa-f]{40}) "([^"]+)"', identities)
    matching = [(fingerprint.upper(), name) for fingerprint, name in available if fingerprint.upper() == identity.upper() or name == identity]
    if len(matching) != 1 or not matching[0][1].startswith('Developer ID Application:'):
        raise ValueError('A valid local Developer ID Application identity is required for CloudKit distribution.')
    certificates = {hashlib.sha1(cert).hexdigest().upper() for cert in data['DeveloperCertificates']}
    if matching[0][0] not in certificates:
        raise ValueError('The selected signing certificate is not included in the CloudKit profile.')
    return {
        'com.apple.application-identifier': prefix + '.' + bundle,
        'com.apple.developer.team-identifier': team,
        'com.apple.developer.icloud-container-identifiers': [container],
        'com.apple.developer.icloud-services': ['CloudKit'],
        'com.apple.developer.icloud-container-environment': 'Production',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', required=True, type=Path)
    parser.add_argument('--bundle-id', required=True)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--container-id', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    entitlements = derive(args.profile, args.bundle_id, args.identity, args.container_id)
    args.output.write_bytes(plistlib.dumps(entitlements))
    args.output.chmod(0o600)
    print('Validated Developer ID profile and production CloudKit entitlements.')


if __name__ == '__main__':
    main()
