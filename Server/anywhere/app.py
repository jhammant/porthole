"""Porthole Anywhere (anywhere.hammantlabs.com): "a Claude session needs you" as a push notification, for
devices with a Porthole Anywhere subscription, and the launch waitlist.

    POST /v1/notify    {"device": token, "env": "production"|"sandbox", "jws": transaction,
                        "title", "body", "session"}           from Porthole for Mac, when a session needs you
    POST /v1/test      {"device", "env", "jws"}                from the iPad or iPhone: a test notification
    POST /v1/waitlist  {"email"}                               from the website
    GET  /health

A push goes out only for a device whose App Store transaction (StoreKit 2's JWS) is a live Porthole Anywhere
subscription for this app. It is checked as Apple's app-store-server-library (SignedDataVerifier) checks it,
less the online OCSP step: three certificates ending in Apple Root CA - G3 (by fingerprint), each issued by
the next, the intermediate a CA with Apple's WWDR marker and the leaf with StoreKit's receipt-signing marker,
all within their dates, the ES256 signature by the leaf; then this app, an Anywhere product, an App Store
environment that fits the push environment, not revoked, not expired.

Refusals carry a machine-readable "reason":
    402 "invalid"   not Apple's StoreKit, another app or product, the wrong environment, forged
    402 "revoked"   refunded or revoked
    402 "expired"   the subscription period (or Apple's signing certificate) is over: the device should send
                    a newer transaction. The Mac drops a device only on invalid or revoked, and pauses on expired.
    429 "devices"   one subscription serves at most 5 devices in any 30 days
    429 "rate"      60 notifications an hour for one device, or 5 waitlist sign-ups an hour from one address
A fault on this side answers 500 or 502 with no reason, so nothing is dropped for it; 503 means push is not
set up, or 32 requests are already being handled.

No accounts, and nothing on disk about devices: memory holds only hashes, keyed by a random key made at each
start, of device tokens and subscriptions (originalTransactionId), for the hourly counts and the device cap,
and a restart forgets them. The waitlist is in SQLite. Python 3.12, `cryptography` and `httpx[http2]` (APNs
speaks HTTP/2 only). Tests: python3.12 -m unittest discover -s tests -t .

Secrets (environment): ANYWHERE_APNS_KEY (the .p8's text), ANYWHERE_APNS_KEY_ID, ANYWHERE_TEAM_ID. Without
them /v1/notify and /v1/test answer 503 and the rest works.
"""
import base64
import hashlib
import hmac
import ipaddress
import json
import os
import re
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import httpx
from cryptography import x509
from cryptography.exceptions import InvalidSignature, UnsupportedAlgorithm
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature, decode_dss_signature

BUNDLE_ID = "io.hammant.porthole"
PRODUCTS = {"io.hammant.porthole.anywhere.monthly", "io.hammant.porthole.anywhere.yearly"}
APPLE_ROOT_G3_SHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179"
# Apple's marker extensions, which app-store-server-library requires: the leaf must be a StoreKit
# receipt-signing certificate and the intermediate an Apple Worldwide Developer Relations CA (WWDR G6 today).
# The root alone proves little: Apple Root CA - G3 also issues the Apple Pay intermediate (WWDR G2, which has
# no WWDR marker), whose leaves are made from a developer's own key, so anyone with a developer account could
# otherwise sign "subscriptions".
STOREKIT_LEAF_OID = x509.ObjectIdentifier("1.2.840.113635.100.6.11.1")
WWDR_INTERMEDIATE_OID = x509.ObjectIdentifier("1.2.840.113635.100.6.2.1")
# Which App Store environments a transaction may come from, for each push environment the device asks for.
# The device asks for "sandbox" only from a development (DEBUG) build: its pushes come from APNs's sandbox and
# its purchases are Sandbox ones. TestFlight builds get production pushes but their purchases are Sandbox
# (free for testers), and App Store builds are Production on both sides. So production push takes Production
# or Sandbox, sandbox push takes Sandbox only, and Xcode or LocalTesting transactions never pass (nor would
# their chains). A Sandbox transaction can only be made by a sandbox or TestFlight tester of this app, its
# period is short (a day or less), and like any transaction it serves at most DEVICES_PER_SUBSCRIPTION devices.
ENVIRONMENTS = {"production": {"Production", "Sandbox"}, "sandbox": {"Sandbox"}}
DATA = os.environ.get("ANYWHERE_DATA", "/data")
ORIGINS = {"https://jhammant.github.io", "https://porthole.hammantlabs.com", "https://anywhere.hammantlabs.com"}
RATE_PER_HOUR = 60                  # notifications an hour for one device
DEVICES_PER_SUBSCRIPTION = 5        # distinct devices one subscription may notify ...
DEVICE_WINDOW = 30 * 24 * 3600      # ... in any 30 days (a device not heard from for 30 days frees its place)
WAITLIST_PER_HOUR = 5               # sign-ups an hour from one address
WAITLIST_SHARED_PER_HOUR = 60       # sign-ups an hour, together, from requests whose address the edge didn't pass on
MAX_REQUESTS = 32                   # handled at once; the next is answered 503 straight away
EMAIL = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,190}\.[A-Za-z]{2,24}$")


def b64url(data: str) -> bytes:
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


class Refused(Exception):
    """Why a transaction gets no push. reason is "invalid", "revoked" or "expired" (see the module's top)."""

    def __init__(self, reason: str, detail: str):
        super().__init__(detail)
        self.reason = reason


def has_extension(cert: x509.Certificate, oid: x509.ObjectIdentifier) -> bool:
    try:
        cert.extensions.get_extension_for_oid(oid)
        return True
    except x509.ExtensionNotFound:
        return False


def is_ca(cert: x509.Certificate) -> bool:
    try:
        return cert.extensions.get_extension_for_class(x509.BasicConstraints).value.ca
    except x509.ExtensionNotFound:
        return False


def signed_payload(jws: str) -> tuple[dict, list[x509.Certificate]]:
    """The JWS's payload and its certificates, if Apple's StoreKit signed it; raises Refused("invalid")
    otherwise. Says nothing yet about dates or what the transaction is for."""
    try:
        head_b64, body_b64, sig_b64 = jws.split(".")
        header = json.loads(b64url(head_b64))
        payload = json.loads(b64url(body_b64))
        raw = b64url(sig_b64)
    except ValueError:
        raise Refused("invalid", "not a JWS") from None
    if not isinstance(header, dict) or not isinstance(payload, dict):
        raise Refused("invalid", "not a JWS")
    if header.get("alg") != "ES256":
        raise Refused("invalid", "unexpected algorithm")
    x5c = header.get("x5c")
    if not isinstance(x5c, list) or len(x5c) != 3 or not all(isinstance(c, str) for c in x5c):
        raise Refused("invalid", "unexpected certificate chain")
    try:
        chain = [x509.load_der_x509_certificate(base64.b64decode(c, validate=True)) for c in x5c]
        leaf, intermediate, root = chain
        if hashlib.sha256(root.public_bytes(serialization.Encoding.DER)).hexdigest() != APPLE_ROOT_G3_SHA256:
            raise Refused("invalid", "not Apple's root")
        leaf.verify_directly_issued_by(intermediate)
        intermediate.verify_directly_issued_by(root)
        if not is_ca(intermediate):
            raise Refused("invalid", "the intermediate is not a CA")
        if not has_extension(intermediate, WWDR_INTERMEDIATE_OID):
            raise Refused("invalid", "not Apple's WWDR intermediate")
        if not has_extension(leaf, STOREKIT_LEAF_OID):
            raise Refused("invalid", "not a StoreKit signing certificate")
        key = leaf.public_key()
        if not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(key.curve, ec.SECP256R1) or len(raw) != 64:
            raise Refused("invalid", "bad signature")
        sig = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
        key.verify(sig, f"{head_b64}.{body_b64}".encode(), ec.ECDSA(hashes.SHA256()))
    except (ValueError, TypeError, InvalidSignature, UnsupportedAlgorithm):
        raise Refused("invalid", "not signed by Apple's StoreKit") from None
    return payload, chain


def verify_transaction(jws: str, env: str = "production", now: float | None = None) -> dict:
    """The transaction's payload, if Apple signed it and it is a live Anywhere subscription for this app that
    may use the push environment env ("production" or "sandbox"); raises Refused with the reason otherwise."""
    payload, chain = signed_payload(jws)
    when = time.time() if now is None else now
    if payload.get("bundleId") != BUNDLE_ID:
        raise Refused("invalid", "another app's transaction")
    product = payload.get("productId")
    if not isinstance(product, str) or product not in PRODUCTS:
        raise Refused("invalid", "not an Anywhere subscription")
    environment = payload.get("environment")
    if not isinstance(environment, str) or environment not in ENVIRONMENTS.get(env, ()):
        raise Refused("invalid", f"a transaction from {environment or 'no environment'} can't use {env} push")
    original = payload.get("originalTransactionId")
    if not isinstance(original, str) or not original:
        raise Refused("invalid", "no original transaction")
    if payload.get("revocationDate"):
        raise Refused("revoked", "refunded or revoked")
    expires = payload.get("expiresDate")
    if not isinstance(expires, (int, float)) or isinstance(expires, bool):
        raise Refused("invalid", "no expiry date")
    # The chain is Apple's by now, so a certificate past its dates means an old transaction, not a forgery:
    # "expired", and the device's newer transaction (signed by Apple's current certificate) will pass.
    for cert in chain:
        if not (cert.not_valid_before_utc.timestamp() <= when <= cert.not_valid_after_utc.timestamp()):
            raise Refused("expired", "Apple's certificate is outside its dates")
    if expires / 1000 < when:
        raise Refused("expired", "subscription expired")
    return payload


KEY = os.urandom(32)    # made at each start and never kept: memory holds only hashes keyed by it


def tag(value: str) -> str:
    """A device token or subscription as memory keeps it: a keyed hash, of no use without this process's KEY."""
    return hmac.new(KEY, value.encode(), hashlib.sha256).hexdigest()


class Window:
    """How often each key was seen in the last `seconds`, in memory and under a lock. take() counts one,
    unless the key is at its limit. Keys with nothing left in the window are swept out every minute, so the
    dict holds only what is still counting."""

    def __init__(self, limit: int, seconds: float):
        self.limit, self.seconds = limit, seconds
        self.times: dict[str, list[float]] = {}
        self.lock = threading.Lock()
        self.swept = 0.0

    def take(self, key: str, now: float | None = None) -> bool:
        now = time.time() if now is None else now
        with self.lock:
            if now - self.swept > 60:
                self.times = {k: v for k, v in self.times.items() if now - v[-1] < self.seconds}
                self.swept = now
            times = [t for t in self.times.get(key, ()) if now - t < self.seconds]
            if len(times) >= self.limit:
                self.times[key] = times
                return False
            self.times[key] = times + [now]
            return True


class DeviceCap:
    """The devices each subscription has notified in a sliding window (keyed hashes, in memory), so one
    subscriber's transaction, posted online or built into a fork, can't serve any number of devices."""

    def __init__(self, limit: int, seconds: float):
        self.limit, self.seconds = limit, seconds
        self.seen: dict[str, dict[str, float]] = {}     # subscription → {device: last notified}
        self.lock = threading.Lock()
        self.swept = 0.0

    def admit(self, subscription: str, device: str, now: float | None = None) -> str:
        """ "seen" for a device already counted, "new" when it takes a free place, "full" when there is none."""
        now = time.time() if now is None else now
        with self.lock:
            if now - self.swept > 3600:
                live = {s: {d: t for d, t in ds.items() if now - t < self.seconds} for s, ds in self.seen.items()}
                self.seen = {s: ds for s, ds in live.items() if ds}
                self.swept = now
            devices = {d: t for d, t in self.seen.get(subscription, {}).items() if now - t < self.seconds}
            if device not in devices and len(devices) >= self.limit:
                self.seen[subscription] = devices
                return "full"
            answer = "seen" if device in devices else "new"
            devices[device] = now
            self.seen[subscription] = devices
            return answer

    def forget(self, subscription: str, device: str) -> None:
        """Gives a place back, for a new device whose push didn't go (so made-up tokens can't use places up)."""
        with self.lock:
            devices = self.seen.get(subscription, {})
            devices.pop(device, None)
            if not devices:
                self.seen.pop(subscription, None)


def client_ip(peer: str, forwarded: str | None) -> str | None:
    """The asker's public address, or None when there is none to tell askers apart by. A request from a private
    or loopback address came through the Traefik edge, so the address is X-Forwarded-For's first entry
    (Traefik replaces a client's own X-Forwarded-For unless told to trust it, so the first entry is what the
    outermost edge saw). Anything else is taken from the connection, never from the header."""
    try:
        address = ipaddress.ip_address(peer)
    except ValueError:
        return None
    if (address.is_private or address.is_loopback) and forwarded:
        try:
            address = ipaddress.ip_address(forwarded.split(",")[0].strip())
        except ValueError:
            return None
    return str(address) if address.is_global else None


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
recent = Window(RATE_PER_HOUR, 3600)                        # device → notifications this hour
devices = DeviceCap(DEVICES_PER_SUBSCRIPTION, DEVICE_WINDOW)
signups = Window(WAITLIST_PER_HOUR, 3600)                   # address → waitlist sign-ups this hour
signups_shared = Window(WAITLIST_SHARED_PER_HOUR, 3600)     # every sign-up without an address, together


class Handler(BaseHTTPRequestHandler):
    server_version = "PortholeAnywhere/1"
    timeout = 15        # seconds a socket read or write may wait, so a silent client can't hold a thread

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
        """The request's JSON object. It needs a plain Content-Length (no chunked bodies, nothing negative)
        of at most 64 kB; raises ValueError (or OSError on a timeout) otherwise."""
        length = (self.headers.get("Content-Length") or "").strip()
        if not re.fullmatch(r"\d{1,9}", length):
            raise ValueError("no Content-Length")
        n = int(length)
        if n > 64_000:
            raise ValueError("too large")
        data = json.loads(self.rfile.read(n) or b"{}")
        if not isinstance(data, dict):
            raise ValueError("not an object")
        return data

    def do_POST(self):
        try:
            b = self.body()
        except (ValueError, OSError):
            return self.reply(400, {"error": "bad request"})
        if self.path == "/v1/waitlist":
            email = str(b.get("email", "")).strip()
            if not EMAIL.match(email):
                return self.reply(400, {"error": "that doesn't look like an email address"})
            ip = client_ip(self.client_address[0], self.headers.get("X-Forwarded-For"))
            if not (signups.take(tag(ip)) if ip else signups_shared.take("")):
                return self.reply(429, {"error": "too many sign-ups from here; try again in an hour", "reason": "rate"})
            store.join(email)
            return self.reply(200, {"ok": True})
        if self.path in ("/v1/notify", "/v1/test"):
            device, env = str(b.get("device", "")), str(b.get("env", "production"))
            if not re.fullmatch(r"[0-9a-fA-F]{64,200}", device) or env not in ENVIRONMENTS:
                return self.reply(400, {"error": "bad device"})
            try:
                payload = verify_transaction(str(b.get("jws", "")), env)
            except Refused as e:
                return self.reply(402, {"error": f"no active Porthole Anywhere subscription ({e})", "reason": e.reason})
            except Exception as e:      # a fault here, not a verdict: no reason, so the Mac keeps the device
                print(f"verify: {type(e).__name__}", flush=True)
                return self.reply(500, {"error": "server error"})
            if not apns.ready:
                return self.reply(503, {"error": "push is not set up on this server yet"})
            subscription, token = tag(payload["originalTransactionId"]), tag(device)
            place = devices.admit(subscription, token)
            if place == "full":
                return self.reply(429, {"error": f"this subscription already notifies {DEVICES_PER_SUBSCRIPTION} devices",
                                        "reason": "devices"})
            if not recent.take(token):
                if place == "new":
                    devices.forget(subscription, token)
                return self.reply(429, {"error": "too many notifications this hour", "reason": "rate"})
            if self.path == "/v1/test":
                title, body, session = "Porthole Anywhere is on", "You'll hear here when a Claude session needs you.", ""
            else:
                title, body, session = str(b.get("title", "A session needs you")), str(b.get("body", "")), str(b.get("session", ""))
            try:
                code, text = apns.send(device, env, title, body, session)
            except Exception as e:      # the type only: httpx's message holds the URL, and the URL the token
                print(f"apns: send failed ({type(e).__name__})", flush=True)
                code, text = 0, "push service unreachable"
            if code != 200 and place == "new":
                devices.forget(subscription, token)
            return self.reply(200 if code == 200 else 502, {"ok": code == 200, "apns": code, "detail": text[:200]})
        self.reply(404, {"error": "not found"})


class Server(ThreadingHTTPServer):
    """A thread per request, but at most `limit` at once: one more is answered 503 straight away, without a
    thread, so a flood or a crowd of slow clients can't exhaust threads or memory."""
    BUSY = (b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: 17\r\n"
            b"Connection: close\r\n\r\n{\"error\": \"busy\"}")

    def __init__(self, address, handler, limit: int = MAX_REQUESTS):
        super().__init__(address, handler)
        self.slots = threading.BoundedSemaphore(limit)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.settimeout(1)
                request.sendall(self.BUSY)
            except OSError:
                pass
            return self.shutdown_request(request)
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        # One line, no traceback: an exception's text can carry a device token or a URL holding one.
        print(f"error: {sys.exc_info()[0].__name__}", flush=True)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    print(f"porthole-anywhere: listening on 0.0.0.0:{port} (push {'ready' if apns.ready else 'not set up'})", flush=True)
    Server(("0.0.0.0", port), Handler).serve_forever()
