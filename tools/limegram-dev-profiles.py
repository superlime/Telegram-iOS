#!/usr/bin/env python3
"""
Create iOS Development provisioning profiles for every Limegram bundle id and
drop them where Make.py's --codesigningInformationPath expects them.

The repo's build-system/fake-codesigning/profiles holds App Store *distribution*
profiles (get-task-allow=false, no provisioned devices) which cannot be installed
directly onto a device. This mints the development counterparts into a sibling
directory so both paths stay available:

    build-system/fake-codesigning      -> App Store / TestFlight
    build-system/fake-codesigning-dev  -> direct device install (this script)

Usage:
    ~/.sg-asc-venv/bin/python tools/limegram-dev-profiles.py            # auto-detect tethered device
    ~/.sg-asc-venv/bin/python tools/limegram-dev-profiles.py --udid <40-char-udid>
    ~/.sg-asc-venv/bin/python tools/limegram-dev-profiles.py --list     # show current state, change nothing

Requires pyjwt + cryptography + requests (see ~/.sg-asc-venv).
"""

import argparse
import base64
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time

import jwt
import requests

KEY_ID = "343KK3A33G"
ISSUER_ID = "0a5f93a2-0d79-41d3-9904-aee08a76ed32"
PRIVATE_KEY_PATH = "build-system/AuthKey_343KK3A33G.p8"
BUNDLE_PREFIX = "org.ccc38e857449d6e8.Limegram"
PROFILE_PREFIX = "Limegram Development"
SOURCE_DIR = "build-system/fake-codesigning"
DEST_DIR = "build-system/fake-codesigning-dev"
BASE_URL = "https://api.appstoreconnect.apple.com/v1"

# Make.py matches a profile to a target by bundle id, but the filenames follow
# the upstream Telegram convention, so map suffix -> expected filename.
FILENAME_BY_SUFFIX = {
    "": "Telegram.mobileprovision",
    ".Share": "Share.mobileprovision",
    ".Widget": "Widget.mobileprovision",
    ".SiriIntents": "Intents.mobileprovision",
    ".Intents": "Intents.mobileprovision",
    ".NotificationService": "NotificationService.mobileprovision",
    ".NotificationContent": "NotificationContent.mobileprovision",
    ".BroadcastUpload": "BroadcastUpload.mobileprovision",
    ".watchkitapp": "WatchApp.mobileprovision",
    ".watchkitapp.watchkitextension": "WatchExtension.mobileprovision",
}


def auth_headers():
    with open(PRIVATE_KEY_PATH) as handle:
        private_key = handle.read()
    token = jwt.encode(
        {"iss": ISSUER_ID, "exp": int(time.time()) + 1200, "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"alg": "ES256", "kid": KEY_ID, "typ": "JWT"},
    )
    return {"Authorization": "Bearer %s" % token, "Content-Type": "application/json"}


def api_get(headers, path):
    response = requests.get(BASE_URL + path, headers=headers)
    response.raise_for_status()
    return response.json()


def detect_udid():
    """Read the UDID of a tethered device via devicectl."""
    try:
        raw = subprocess.check_output(
            ["xcrun", "devicectl", "list", "devices", "--json-output", "-"],
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, OSError):
        return None, None
    try:
        payload = json.loads(raw.decode("utf-8"))
    except ValueError:
        return None, None
    for device in payload.get("result", {}).get("devices", []):
        properties = device.get("hardwareProperties", {})
        identifier = properties.get("udid")
        name = device.get("deviceProperties", {}).get("name", "device")
        if identifier:
            return identifier, name
    return None, None


def ensure_device(headers, udid, name):
    existing = api_get(headers, "/devices?limit=200")["data"]
    for device in existing:
        if device["attributes"].get("udid", "").lower() == udid.lower():
            print("device already registered: %s (%s)" % (device["attributes"].get("name"), device["id"]))
            return device["id"]
    payload = {
        "data": {
            "type": "devices",
            "attributes": {"name": name or "Limegram test device", "platform": "IOS", "udid": udid},
        }
    }
    response = requests.post(BASE_URL + "/devices", headers=headers, json=payload)
    if response.status_code not in (200, 201):
        raise SystemExit("failed to register device: HTTP %d %s" % (response.status_code, response.text[:400]))
    device_id = response.json()["data"]["id"]
    print("registered device %s -> %s" % (udid, device_id))
    return device_id


def development_certificate(headers):
    for certificate in api_get(headers, "/certificates?limit=200")["data"]:
        if certificate["attributes"].get("certificateType") == "DEVELOPMENT":
            print("development certificate: %s (%s)" % (certificate["attributes"].get("displayName"), certificate["id"]))
            return certificate["id"]
    raise SystemExit("no DEVELOPMENT certificate in this account - create one in Xcode or the developer portal first")


def limegram_bundle_ids(headers):
    found = []
    for entry in api_get(headers, "/bundleIds?limit=200")["data"]:
        identifier = entry["attributes"].get("identifier", "")
        if identifier == BUNDLE_PREFIX or identifier.startswith(BUNDLE_PREFIX + "."):
            found.append((entry["id"], identifier))
    found.sort(key=lambda pair: len(pair[1]))
    return found


def delete_stale_profile(headers, name):
    for profile in api_get(headers, "/profiles?limit=200")["data"]:
        if profile["attributes"].get("name") == name:
            requests.delete(BASE_URL + "/profiles/" + profile["id"], headers=headers)
            print("  removed previous profile %s" % name)


def create_profile(headers, name, bundle_id_ref, certificate_id, device_id):
    delete_stale_profile(headers, name)
    payload = {
        "data": {
            "type": "profiles",
            "attributes": {"name": name, "profileType": "IOS_APP_DEVELOPMENT"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_id_ref}},
                "certificates": {"data": [{"type": "certificates", "id": certificate_id}]},
                "devices": {"data": [{"type": "devices", "id": device_id}]},
            },
        }
    }
    response = requests.post(BASE_URL + "/profiles", headers=headers, json=payload)
    if response.status_code not in (200, 201):
        raise SystemExit("failed to create %s: HTTP %d %s" % (name, response.status_code, response.text[:400]))
    return base64.b64decode(response.json()["data"]["attributes"]["profileContent"])


def filename_for(identifier):
    suffix = identifier[len(BUNDLE_PREFIX):]
    if suffix in FILENAME_BY_SUFFIX:
        return FILENAME_BY_SUFFIX[suffix]
    # Unknown extension: derive a filename from the last path component.
    return re.sub(r"[^A-Za-z0-9]", "", suffix.split(".")[-1] or "Extra") + ".mobileprovision"


def describe(path):
    try:
        raw = subprocess.check_output(["security", "cms", "-D", "-i", path], stderr=subprocess.DEVNULL)
        data = plistlib.loads(raw)
    except Exception:
        return "(unreadable)"
    return "%s | devices=%d | get-task-allow=%s" % (
        data.get("Entitlements", {}).get("application-identifier"),
        len(data.get("ProvisionedDevices") or []),
        data.get("Entitlements", {}).get("get-task-allow"),
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", help="Device UDID. Omit to auto-detect a tethered device.")
    parser.add_argument("--name", help="Device name to register it under.")
    parser.add_argument("--list", action="store_true", help="Print current account state and exit.")
    args = parser.parse_args()

    if not os.path.exists(PRIVATE_KEY_PATH):
        raise SystemExit("run this from the repo root - %s not found" % PRIVATE_KEY_PATH)

    headers = auth_headers()

    if args.list:
        for path in ("devices", "certificates", "profiles"):
            print("--- %s" % path)
            for entry in api_get(headers, "/%s?limit=200" % path)["data"]:
                attributes = entry["attributes"]
                print("   ", attributes.get("name") or attributes.get("displayName"),
                      "|", attributes.get("udid") or attributes.get("certificateType") or attributes.get("profileType"))
        return

    udid, detected_name = (args.udid, args.name) if args.udid else detect_udid()
    if not udid:
        raise SystemExit(
            "no device UDID.\n"
            "Plug the iPhone into this Mac, unlock it, tap Trust, then re-run.\n"
            "Or pass it explicitly: --udid <40-char-udid> --name 'My iPhone'"
        )
    print("target device: %s (%s)" % (udid, detected_name or "unnamed"))

    device_id = ensure_device(headers, udid, args.name or detected_name)
    certificate_id = development_certificate(headers)
    bundle_ids = limegram_bundle_ids(headers)
    if not bundle_ids:
        raise SystemExit("no bundle ids matching %s - run build-system/register_app.py first" % BUNDLE_PREFIX)

    os.makedirs(DEST_DIR + "/profiles", exist_ok=True)
    if os.path.isdir(SOURCE_DIR + "/certs"):
        shutil.rmtree(DEST_DIR + "/certs", ignore_errors=True)
        shutil.copytree(SOURCE_DIR + "/certs", DEST_DIR + "/certs")
        print("copied certs/ from %s" % SOURCE_DIR)

    print("creating %d development profiles..." % len(bundle_ids))
    for bundle_ref, identifier in bundle_ids:
        suffix = identifier[len(BUNDLE_PREFIX):] or " - Main"
        name = "%s%s" % (PROFILE_PREFIX, suffix if suffix.startswith(" ") else " - " + suffix.lstrip("."))
        content = create_profile(headers, name, bundle_ref, certificate_id, device_id)
        target = os.path.join(DEST_DIR, "profiles", filename_for(identifier))
        with open(target, "wb") as handle:
            handle.write(content)
        print("  %-34s -> %s" % (identifier, os.path.basename(target)))

    print("\nwrote %s/profiles:" % DEST_DIR)
    for entry in sorted(os.listdir(DEST_DIR + "/profiles")):
        print("  %-32s %s" % (entry, describe(os.path.join(DEST_DIR, "profiles", entry))))
    print("\nNext: build with --codesigningInformationPath %s --configuration=debug_arm64" % DEST_DIR)


if __name__ == "__main__":
    main()
