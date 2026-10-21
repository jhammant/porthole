#!/usr/bin/env python3
"""Porthole's TestFlight builds as App Store Connect sees them (docs/porthole-plan.md, phase 5).

usage: uv run --with pyjwt,cryptography Scripts/porthole-build-status.py KEY_ID ISSUER_ID APP_ID [--wait MINUTES] [--build N]

Signs a short-lived token with ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 (read here, never
printed or sent anywhere but Apple's API) and lists the app's builds: version, build number, processing
state. With --wait it asks every minute until the newest build is no longer PROCESSING; with --build N
too, until build N is listed and no longer PROCESSING (a fresh upload is listed only some minutes later,
so the newest listed build can be an older, finished one).
"""
import json, os, sys, time, urllib.request
import jwt

key_id, issuer, app_id = sys.argv[1:4]
wait = int(sys.argv[sys.argv.index("--wait") + 1]) if "--wait" in sys.argv else 0
want = sys.argv[sys.argv.index("--build") + 1] if "--build" in sys.argv else None
key = open(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")).read()


def builds():
    now = int(time.time())
    token = jwt.encode({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}, key,
                       algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})
    url = f"https://api.appstoreconnect.apple.com/v1/builds?filter[app]={app_id}&sort=-uploadedDate&limit=5&include=preReleaseVersion"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    versions = {i["id"]: i["attributes"].get("version") for i in data.get("included", []) if i["type"] == "preReleaseVersions"}
    out = []
    for b in data.get("data", []):
        a = b["attributes"]
        pre = (b.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}).get("id")
        out.append((versions.get(pre, "?"), a.get("version"), a.get("processingState"), a.get("uploadedDate")))
    return out


deadline = time.time() + wait * 60
while True:
    rows = builds()
    for v, n, state, up in rows:
        print(f"{time.strftime('%H:%M:%S')}  version {v} build {n}: {state} (uploaded {up})", flush=True)
    if not rows:
        print(f"{time.strftime('%H:%M:%S')}  no builds listed yet", flush=True)
    if want:
        mine = [state for _, n, state, _ in rows if n == want]
        done = bool(mine) and mine[0] != "PROCESSING"
    else:
        done = bool(rows) and rows[0][2] != "PROCESSING"
    if not wait or time.time() > deadline or done:
        break
    time.sleep(60)
