#!/bin/bash

set -euo pipefail

APP_NAME="Markdown Viewer.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_APP="$SCRIPT_DIR/dist/$APP_NAME"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
TARGET_APP="$INSTALL_DIR/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
LAUNCH_SERVICES_PLIST="$HOME/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    fi
}

main() {
    require_command ditto
    require_command plutil
    require_command python3

    "$SCRIPT_DIR/build.sh"

    if [ ! -d "$DIST_APP" ]; then
        printf 'Built app not found at %s\n' "$DIST_APP" >&2
        exit 1
    fi

    mkdir -p "$INSTALL_DIR"
    # A stale bundle merged over breaks the code-signature seal; replace cleanly.
    rm -rf "$TARGET_APP"
    ditto "$DIST_APP" "$TARGET_APP"
    "$LSREGISTER" -f "$TARGET_APP" >/dev/null

    local bundle_id
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET_APP/Contents/Info.plist")"

    python3 - "$bundle_id" "$LAUNCH_SERVICES_PLIST" <<'PY'
import ctypes
import os
import plistlib
import sys
from contextlib import contextmanager

bundle_id = sys.argv[1]
plist_path = os.path.expanduser(sys.argv[2])

EXTENSIONS = ["md", "markdown", "mdown", "mkd"]
CONTENT_TYPES = {"net.daringfireball.markdown"}
UTF8 = 0x08000100
LS_ROLES_ALL = 0xFFFFFFFF

CF = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
CS = ctypes.CDLL("/System/Library/Frameworks/CoreServices.framework/CoreServices")

CF.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
CF.CFStringCreateWithCString.restype = ctypes.c_void_p
CF.CFRelease.argtypes = [ctypes.c_void_p]
CF.CFRelease.restype = None
CF.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
CF.CFStringGetCString.restype = ctypes.c_bool

CS.UTTypeCreatePreferredIdentifierForTag.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
CS.UTTypeCreatePreferredIdentifierForTag.restype = ctypes.c_void_p
CS.LSSetDefaultRoleHandlerForContentType.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p]
CS.LSSetDefaultRoleHandlerForContentType.restype = ctypes.c_int32
CS.LSCopyDefaultRoleHandlerForContentType.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
CS.LSCopyDefaultRoleHandlerForContentType.restype = ctypes.c_void_p


@contextmanager
def cfstr(value):
    ref = CF.CFStringCreateWithCString(None, value.encode("utf-8"), UTF8)
    try:
        yield ref
    finally:
        CF.CFRelease(ref)


def cfstr_to_python(ref):
    buf = ctypes.create_string_buffer(4096)
    if not CF.CFStringGetCString(ref, buf, len(buf), UTF8):
        raise RuntimeError("Could not convert CFString")
    return buf.value.decode("utf-8")


# --- Resolve extensions to UTIs and register as default handler ---

with cfstr(bundle_id) as bundle_cf, cfstr("public.filename-extension") as tag_class_cf:
    for ext in EXTENSIONS:
        with cfstr(ext) as ext_cf:
            uti_cf = CS.UTTypeCreatePreferredIdentifierForTag(tag_class_cf, ext_cf, None)
            if uti_cf:
                CONTENT_TYPES.add(cfstr_to_python(uti_cf))
                CF.CFRelease(uti_cf)

    for ct in sorted(CONTENT_TYPES):
        with cfstr(ct) as ct_cf:
            status = CS.LSSetDefaultRoleHandlerForContentType(ct_cf, LS_ROLES_ALL, bundle_cf)
            if status != 0:
                raise RuntimeError(f"LSSetDefaultRoleHandlerForContentType failed for {ct}: {status}")

            current_cf = CS.LSCopyDefaultRoleHandlerForContentType(ct_cf, LS_ROLES_ALL)
            if not current_cf:
                raise RuntimeError(f"Could not verify default handler for {ct}")

            current = cfstr_to_python(current_cf)
            CF.CFRelease(current_cf)

            if current != bundle_id:
                raise RuntimeError(f"Handler mismatch for {ct}: expected {bundle_id}, got {current}")

            print(f"default handler set: {ct} -> {current}")


# --- Update LaunchServices plist ---

def is_markdown_handler(h):
    if h.get("LSHandlerContentType") in CONTENT_TYPES:
        return True
    if (h.get("LSHandlerContentTagClass") == "public.filename-extension"
            and h.get("LSHandlerContentTag") in EXTENSIONS):
        return True
    return False


payload = {}
if os.path.exists(plist_path):
    with open(plist_path, "rb") as f:
        payload = plistlib.load(f)

version_pref = {"LSHandlerRoleAll": "-"}
handlers = [h for h in payload.get("LSHandlers", []) if not is_markdown_handler(h)]

for ct in sorted(CONTENT_TYPES):
    handlers.append({"LSHandlerContentType": ct, "LSHandlerRoleAll": bundle_id,
                      "LSHandlerPreferredVersions": version_pref})

for ext in EXTENSIONS:
    handlers.append({"LSHandlerContentTag": ext, "LSHandlerContentTagClass": "public.filename-extension",
                      "LSHandlerRoleAll": bundle_id, "LSHandlerPreferredVersions": version_pref})

payload["LSHandlers"] = handlers
os.makedirs(os.path.dirname(plist_path), exist_ok=True)

with open(plist_path, "wb") as f:
    plistlib.dump(payload, f, fmt=plistlib.FMT_BINARY)
PY

    "$LSREGISTER" -kill -seed -r -domain local -domain system -domain user >/dev/null 2>&1 || true
    "$LSREGISTER" -f "$TARGET_APP" >/dev/null

    killall cfprefsd Finder >/dev/null 2>&1 || true

    echo "Installed -> $TARGET_APP"
}

main "$@"
