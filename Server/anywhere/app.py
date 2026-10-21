"""Porthole Anywhere (anywhere.hammantlabs.com): "a Claude session needs you" as a push notification, for
devices with a Porthole Anywhere subscription, and the launch waitlist.

    POST /v1/notify    {"device": token, "env": "production"|"sandbox", "jws": transaction,
                        "title", "body", "session"}           from Porthole for Mac, when a session needs you
    POST /v1/test      {"device", "env", "jws"}                from the iPad or iPhone: a test notification
    POST /v1/waitlist  {"email"}                               from the website
    GET  /health

A push goes out only for a device whose App Store transaction (StoreKit 2's JWS, signed by Apple: the chain
is checked to Apple Root CA - G3 by fingerprint) is a live Porthole Anywhere subscription for this app. No
accounts: the server keeps nothing about a device, only a rate count in memory and the waitlist in SQLite.
Python 3.12, `cryptography` and `httpx[http2]` (APNs speaks HTTP/2 only).

Secrets (environment): ANYWHERE_APNS_KEY (the .p8's text), ANYWHERE_APNS_KEY_ID, ANYWHERE_TEAM_ID. Without
them /v1/notify and /v1/test answer 503 and the rest works.
"""
import base64
import hashlib
import json
import os
import re
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import httpx
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature, decode_dss_signature

BUNDLE_ID = "io.hammant.porthole"
PRODUCTS = {"io.hammant.porthole.anywhere.monthly", "io.hammant.porthole.anywhere.yearly"}
APPLE_ROOT_G3_SHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179"
DATA = os.environ.get("ANYWHERE_DATA", "/data")
ORIGINS = {"https://jhammant.github.io", "https://porthole.hammantlabs.com", "https://anywhere.hammantlabs.com"}
RATE_PER_HOUR = 60
EMAIL = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,190}\.[A-Za-z]{2,24}$")


def b64url(data: str) -> bytes:
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


def verify_transaction(jws: str, now: float | None = None) -> dict:
    """The transaction's payload, if Apple signed it and it is a live Anywhere subscription for this app;
    raises ValueError with the reason otherwise."""
    try:
        head_b64, body_b64, sig_b64 = jws.split(".")
        header = json.loads(b64url(head_b64))
    except Exception:
        raise ValueError("not a JWS")
    if header.get("alg") != "ES256":
        raise ValueError("unexpected algorithm")
    chain = [x509.load_der_x509_certificate(base64.b64decode(c)) for c in header.get("x5c", [])]
    if len(chain) != 3:
        raise ValueError("unexpected certificate chain")
    if hashlib.sha256(chain[-1].public_bytes(serialization.Encoding.DER)).hexdigest() != APPLE_ROOT_G3_SHA256:
        raise ValueError("not Apple's root")
    for child, parent in zip(chain, chain[1:]):
        child.verify_directly_issued_by(parent)
    when = time.time() if now is None else now
    for cert in chain[:-1]:
        if not (cert.not_valid_before_utc.timestamp() <= when <= cert.not_valid_after_utc.timestamp()):
            raise ValueError("certificate outside its dates")
    raw = b64url(sig_b64)
    if len(raw) != 64:
        raise ValueError("bad signature length")
    sig = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    chain[0].public_key().verify(sig, f"{head_b64}.{body_b64}".encode(), ec.ECDSA(hashes.SHA256()))
    payload = json.loads(b64url(body_b64))
    if payload.get("bundleId") != BUNDLE_ID:
        raise ValueError("another app's transaction")
    if payload.get("productId") not in PRODUCTS:
        raise ValueError("not an Anywhere subscription")
    if payload.get("revocationDate"):
        raise ValueError("refunded or revoked")
    if (payload.get("expiresDate") or 0) / 1000 < when:
        raise ValueError("subscription expired")
    return payload


class APNs:
    """Apple's push service: a token (ES256, 50 minutes) and HTTP/2 to the production or sandbox host."""

    def __init__(self):
        self.key_text = os.environ.get("ANYWHERE_APNS_KEY", "").replace("\\n", "\n")
        self.key_id = os.environ.get("ANYWHERE_APNS_KEY_ID", "")
        self.team = os.environ.get("ANYWHERE_TEAM_ID", "")
        self.token, self.made = "", 0.0
        self.lock = threading.Lock()
        self.client = httpx.Client(http2=True, timeout=10)

    @property
    def ready(self) -> bool:
        return bool(self.key_text and self.key_id and self.team)

    def bearer(self) -> str:
        with self.lock:
            if time.time() - self.made > 50 * 60:
                key = serialization.load_pem_private_key(self.key_text.encode(), None)
                head = base64.urlsafe_b64encode(json.dumps({"alg": "ES256", "kid": self.key_id}).encode()).rstrip(b"=")
                claims = base64.urlsafe_b64encode(json.dumps({"iss": self.team, "iat": int(time.time())}).encode()).rstrip(b"=")
                r, s = decode_dss_signature(key.sign(head + b"." + claims, ec.ECDSA(hashes.SHA256())))
                sig = base64.urlsafe_b64encode(r.to_bytes(32, "big") + s.to_bytes(32, "big")).rstrip(b"=")
                self.token, self.made = (head + b"." + claims + b"." + sig).decode(), time.time()
            return self.token

    def send(self, device: str, env: str, title: str, body: str, session: str = "") -> tuple[int, str]:
        host = "api.sandbox.push.apple.com" if env == "sandbox" else "api.push.apple.com"
        payload = {"aps": {"alert": {"title": title[:120], "body": body[:400]}, "sound": "default",
                           "thread-id": session or "porthole"}, "session": session}
        r = self.client.post(f"https://{host}/3/device/{device}", json=payload, headers={
            "authorization": "bearer " + self.bearer(), "apns-topic": BUNDLE_ID,
            "apns-push-type": "alert", "apns-priority": "10"})
        return r.status_code, r.text


class Store:
    def __init__(self, path: str):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.execute("CREATE TABLE IF NOT EXISTS waitlist (email TEXT PRIMARY KEY, at REAL)")
        self.lock = threading.Lock()

    def join(self, email: str) -> None:
        with self.lock, self.db:
            self.db.execute("INSERT OR IGNORE INTO waitlist VALUES (?, ?)", (email.lower(), time.time()))


apns = APNs()
store = Store(os.path.join(DATA, "anywhere.db"))
recent: dict[str, list[float]] = {}


def allowed(device: str) -> bool:
    now = time.time()
    times = [t for t in recent.get(device, []) if now - t < 3600]
    if len(times) >= RATE_PER_HOUR:
        return False
    recent[device] = times + [now]
    return True


class Handler(BaseHTTPRequestHandler):
    server_version = "PortholeAnywhere/1"

    def log_message(self, fmt, *args):      # paths only: no bodies, no tokens
        print(f"{self.command} {self.path.split('?')[0]} {args[1] if len(args) > 1 else ''}", flush=True)

    def cors(self):
        origin = self.headers.get("Origin", "")
        if origin in ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Headers", "content-type")
            self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")

    def reply(self, code: int, body: dict):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.cors()
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(204)
        self.cors()
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            return self.reply(200, {"ok": True, "push": apns.ready})
        if self.path == "/robots.txt":
            self.send_response(200); self.end_headers(); return self.wfile.write(b"User-agent: *\nDisallow: /\n")
        self.reply(404, {"error": "not found"})

    def body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        if n > 64_000:
            raise ValueError("too large")
        return json.loads(self.rfile.read(n) or b"{}")

    def do_POST(self):
        try:
            b = self.body()
        except Exception:
            return self.reply(400, {"error": "bad request"})
        if self.path == "/v1/waitlist":
            email = str(b.get("email", "")).strip()
            if not EMAIL.match(email):
                return self.reply(400, {"error": "that doesn't look like an email address"})
            store.join(email)
            return self.reply(200, {"ok": True})
        if self.path in ("/v1/notify", "/v1/test"):
            device, env = str(b.get("device", "")), str(b.get("env", "production"))
            if not re.fullmatch(r"[0-9a-fA-F]{64,200}", device) or env not in ("production", "sandbox"):
                return self.reply(400, {"error": "bad device"})
            try:
                verify_transaction(str(b.get("jws", "")))
            except Exception as e:
                return self.reply(402, {"error": f"no active Porthole Anywhere subscription ({e})"})
            if not apns.ready:
                return self.reply(503, {"error": "push is not set up on this server yet"})
            if not allowed(device):
                return self.reply(429, {"error": "too many notifications this hour"})
            if self.path == "/v1/test":
                title, body, session = "Porthole Anywhere is on", "You'll hear here when a Claude session needs you.", ""
            else:
                title, body, session = str(b.get("title", "A session needs you")), str(b.get("body", "")), str(b.get("session", ""))
            code, text = apns.send(device, env, title, body, session)
            return self.reply(200 if code == 200 else 502, {"ok": code == 200, "apns": code, "detail": text[:200]})
        self.reply(404, {"error": "not found"})


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    print(f"porthole-anywhere: listening on 0.0.0.0:{port} (push {'ready' if apns.ready else 'not set up'})", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
