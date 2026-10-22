"""Porthole Anywhere's rules: only a StoreKit-signed transaction for this app passes (checked against a chain
minted here, with its root's fingerprint patched in for Apple's), refusals say why (invalid, revoked, expired),
the App Store environment must fit the push environment, one subscription serves at most 5 devices, the
waitlist takes an email once and 5 an hour from one address, bad Content-Lengths get 400, a full server 503,
and a failed push logs no token. python3.12 -m unittest discover -s tests -t ."""
import base64, contextlib, datetime, hashlib, http.client, io, json, os, socket, sys, tempfile, threading, time
import unittest, urllib.request, urllib.error
from unittest import mock
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ["ANYWHERE_DATA"] = tempfile.mkdtemp()
import app  # noqa: E402
import httpx  # noqa: E402
from cryptography import x509  # noqa: E402
from cryptography.x509.oid import NameOID  # noqa: E402
from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature  # noqa: E402

LEAF_OID, WWDR_OID = "1.2.840.113635.100.6.11.1", "1.2.840.113635.100.6.2.1"
APPLE_PAY_OID = "1.2.840.113635.100.6.32"       # what an Apple Pay processing leaf carries instead
DAY = 86400


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def certificate(subject, issuer, key, issuer_key, ca, oids=(), days=(-1, 365)):
    now = datetime.datetime.now(datetime.timezone.utc)
    name = lambda cn: x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
    b = (x509.CertificateBuilder().subject_name(name(subject)).issuer_name(name(issuer))
         .public_key(key.public_key()).serial_number(x509.random_serial_number())
         .not_valid_before(now + datetime.timedelta(days=days[0])).not_valid_after(now + datetime.timedelta(days=days[1]))
         .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True))
    for oid in oids:     # Apple's markers hold an ASN.1 NULL
        b = b.add_extension(x509.UnrecognizedExtension(x509.ObjectIdentifier(oid), b"\x05\x00"), critical=False)
    return b.sign(issuer_key, hashes.SHA256())


class Chain:
    """A local stand-in for Apple's root, WWDR intermediate and StoreKit leaf, with the markers each test picks."""

    def __init__(self, leaf_oids=(LEAF_OID,), intermediate_oids=(WWDR_OID,), intermediate_ca=True, leaf_days=(-1, 365)):
        root_key, mid_key, self.key = (ec.generate_private_key(ec.SECP256R1()) for _ in range(3))
        self.root = certificate("Test Root CA - G3", "Test Root CA - G3", root_key, root_key, True)
        self.intermediate = certificate("Test WWDR", "Test Root CA - G3", mid_key, root_key, intermediate_ca, intermediate_oids)
        self.leaf = certificate("Test StoreKit", "Test WWDR", self.key, mid_key, False, leaf_oids, leaf_days)

    @property
    def fingerprint(self) -> str:
        return hashlib.sha256(self.root.public_bytes(serialization.Encoding.DER)).hexdigest()

    def sign(self, payload: dict) -> str:
        x5c = [base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode() for c in (self.leaf, self.intermediate, self.root)]
        head, body = b64u(json.dumps({"alg": "ES256", "x5c": x5c}).encode()), b64u(json.dumps(payload).encode())
        r, s = decode_dss_signature(self.key.sign(f"{head}.{body}".encode(), ec.ECDSA(hashes.SHA256())))
        return f"{head}.{body}.{b64u(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


def transaction(**changes) -> dict:
    now = time.time()
    payload = {"bundleId": app.BUNDLE_ID, "productId": "io.hammant.porthole.anywhere.monthly",
               "environment": "Production", "originalTransactionId": "2000000123456789",
               "transactionId": "2000000987654321", "signedDate": int(now * 1000),
               "purchaseDate": int((now - DAY) * 1000), "expiresDate": int((now + 29 * DAY) * 1000)}
    payload.update(changes)
    return {k: v for k, v in payload.items() if v is not None}


def post(port, path, body, headers=None):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=5) as r: return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read())


class FakeAPNs:
    ready = True

    def __init__(self, answer=(200, ""), fail=None):
        self.answer, self.fail, self.sent = answer, fail, []

    def send(self, device, env, title, body, session=""):
        self.sent.append(device)
        if self.fail:
            raise self.fail
        return self.answer


CHAIN = Chain()


class Verification(unittest.TestCase):
    """verify_transaction against a chain minted here, its root standing in for Apple Root CA - G3."""

    def setUp(self):
        patch = mock.patch.object(app, "APPLE_ROOT_G3_SHA256", CHAIN.fingerprint)
        patch.start()
        self.addCleanup(patch.stop)

    def refused(self, jws, env="production", now=None) -> str:
        with self.assertRaises(app.Refused) as caught:
            app.verify_transaction(jws, env, now)
        return caught.exception.reason

    def test_storekit_chain_accepted(self):
        payload = app.verify_transaction(CHAIN.sign(transaction()))
        self.assertEqual(payload["originalTransactionId"], "2000000123456789")

    def test_leaf_without_storekit_marker_refused(self):
        for oids in [(), (APPLE_PAY_OID,)]:     # e.g. an Apple Pay processing certificate under WWDR G2
            chain = Chain(leaf_oids=oids)
            with mock.patch.object(app, "APPLE_ROOT_G3_SHA256", chain.fingerprint):
                self.assertEqual(self.refused(chain.sign(transaction())), "invalid")

    def test_intermediate_without_wwdr_marker_refused(self):
        chain = Chain(intermediate_oids=())
        with mock.patch.object(app, "APPLE_ROOT_G3_SHA256", chain.fingerprint):
            self.assertEqual(self.refused(chain.sign(transaction())), "invalid")

    def test_intermediate_must_be_a_ca(self):
        chain = Chain(intermediate_ca=False)
        with mock.patch.object(app, "APPLE_ROOT_G3_SHA256", chain.fingerprint):
            self.assertEqual(self.refused(chain.sign(transaction())), "invalid")

    def test_other_root_refused(self):
        self.assertEqual(self.refused(Chain().sign(transaction())), "invalid")

    def test_tampered_payload_refused(self):
        head, _, sig = CHAIN.sign(transaction()).split(".")
        forged = b64u(json.dumps(transaction(expiresDate=4102444800000)).encode())
        self.assertEqual(self.refused(f"{head}.{forged}.{sig}"), "invalid")

    def test_another_app_or_product_refused(self):
        self.assertEqual(self.refused(CHAIN.sign(transaction(bundleId="com.example.fork"))), "invalid")
        self.assertEqual(self.refused(CHAIN.sign(transaction(productId="io.hammant.porthole.pro"))), "invalid")
        self.assertEqual(self.refused(CHAIN.sign(transaction(originalTransactionId=None))), "invalid")

    def test_environment_rule(self):
        # App Store: Production with production push. TestFlight: Sandbox with production push. Debug: both sandbox.
        for env, environment in [("production", "Production"), ("production", "Sandbox"), ("sandbox", "Sandbox")]:
            app.verify_transaction(CHAIN.sign(transaction(environment=environment)), env)
        for env, environment in [("sandbox", "Production"), ("production", "Xcode"), ("production", "LocalTesting"),
                                 ("production", None), ("sandbox", None)]:
            self.assertEqual(self.refused(CHAIN.sign(transaction(environment=environment)), env), "invalid", (env, environment))

    def test_expired(self):
        self.assertEqual(self.refused(CHAIN.sign(transaction(expiresDate=int((time.time() - 60) * 1000)))), "expired")
        self.assertEqual(self.refused(CHAIN.sign(transaction()), now=time.time() + 30 * DAY), "expired")

    def test_old_signing_certificate_is_expired_not_invalid(self):
        chain = Chain(leaf_days=(-400, -1))
        with mock.patch.object(app, "APPLE_ROOT_G3_SHA256", chain.fingerprint):
            self.assertEqual(self.refused(chain.sign(transaction())), "expired")

    def test_revoked(self):
        self.assertEqual(self.refused(CHAIN.sign(transaction(revocationDate=int(time.time() * 1000)))), "revoked")

    def test_not_a_jws(self):
        for jws in ["nope", "x.y.z", "", "a.b.c.d", "é.é.é"]:
            self.assertEqual(self.refused(jws), "invalid")

    def test_self_signed_chain_refused(self):
        head = b64u(json.dumps({"alg": "ES256", "x5c": ["AA==", "AA==", "AA=="]}).encode())
        self.assertEqual(self.refused(f"{head}.e30.AAAA"), "invalid")


class Limits(unittest.TestCase):
    def test_device_cap_slides(self):
        cap = app.DeviceCap(2, 30 * DAY)
        self.assertEqual(cap.admit("s", "a", now=0), "new")
        self.assertEqual(cap.admit("s", "b", now=DAY), "new")
        self.assertEqual(cap.admit("s", "c", now=2 * DAY), "full")
        self.assertEqual(cap.admit("s", "a", now=3 * DAY), "seen")
        self.assertEqual(cap.admit("t", "c", now=3 * DAY), "new")       # another subscription has its own places
        self.assertEqual(cap.admit("s", "c", now=32 * DAY), "new")      # b not heard from for 30 days: its place is free
        self.assertEqual(cap.admit("s", "b", now=32 * DAY), "full")

    def test_device_cap_sweeps(self):
        cap = app.DeviceCap(5, 30 * DAY)
        cap.admit("s", "a", now=0)
        cap.admit("t", "b", now=40 * DAY)
        self.assertEqual(list(cap.seen), ["t"])

    def test_window_counts_and_sweeps(self):
        window = app.Window(2, 3600)
        self.assertTrue(window.take("a", now=1000))
        self.assertTrue(window.take("a", now=1001))
        self.assertFalse(window.take("a", now=1002))
        self.assertTrue(window.take("a", now=4601))
        window.take("b", now=9000)
        self.assertEqual(list(window.times), ["b"])

    def test_client_ip(self):
        self.assertEqual(app.client_ip("9.9.9.9", "1.1.1.1"), "9.9.9.9")       # public peer: header ignored
        self.assertEqual(app.client_ip("127.0.0.1", "1.1.1.1, 10.0.0.1"), "1.1.1.1")
        self.assertEqual(app.client_ip("172.18.0.3", "2001:4860:4860::8888"), "2001:4860:4860::8888")
        self.assertIsNone(app.client_ip("10.0.0.2", "garbage"))
        self.assertIsNone(app.client_ip("10.0.0.2", None))
        self.assertIsNone(app.client_ip("127.0.0.1", "10.0.0.7"))


class Server(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = app.Server(("127.0.0.1", 0), app.Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        for name, value in [("APPLE_ROOT_G3_SHA256", CHAIN.fingerprint),
                            ("recent", app.Window(app.RATE_PER_HOUR, 3600)),
                            ("devices", app.DeviceCap(app.DEVICES_PER_SUBSCRIPTION, app.DEVICE_WINDOW)),
                            ("signups", app.Window(app.WAITLIST_PER_HOUR, 3600)),
                            ("signups_shared", app.Window(app.WAITLIST_SHARED_PER_HOUR, 3600))]:
            patch = mock.patch.object(app, name, value)
            patch.start()
            self.addCleanup(patch.stop)

    def raw(self, headers: list[tuple[str, str]], body: bytes = b"") -> int:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.putrequest("POST", "/v1/waitlist")
        for k, v in headers:
            conn.putheader(k, v)
        conn.endheaders(body or None)
        code = conn.getresponse().status
        conn.close()
        return code

    def test_waitlist(self):
        self.assertEqual(post(self.port, "/v1/waitlist", {"email": "someone@example.com"})[0], 200)
        self.assertEqual(post(self.port, "/v1/waitlist", {"email": "someone@example.com"})[0], 200)
        self.assertEqual(post(self.port, "/v1/waitlist", {"email": "not an email"})[0], 400)
        n = app.store.db.execute("SELECT COUNT(*) FROM waitlist WHERE email = 'someone@example.com'").fetchone()[0]
        self.assertEqual(n, 1)

    def test_waitlist_rate_limit(self):
        here = {"X-Forwarded-For": "8.8.8.8"}      # from loopback, as from the edge, so the header counts
        for i in range(5):
            self.assertEqual(post(self.port, "/v1/waitlist", {"email": f"a{i}@example.com"}, here)[0], 200)
        code, body = post(self.port, "/v1/waitlist", {"email": "a5@example.com"}, here)
        self.assertEqual((code, body.get("reason")), (429, "rate"))
        self.assertEqual(post(self.port, "/v1/waitlist", {"email": "b@example.com"}, {"X-Forwarded-For": "8.8.4.4"})[0], 200)

    def test_bad_content_length(self):
        body = b'{"email": "c@example.com"}'
        self.assertEqual(self.raw([("Content-Length", "-1")], body), 400)
        self.assertEqual(self.raw([("Content-Length", "+26")], body), 400)
        self.assertEqual(self.raw([("Content-Length", "99999999")], body), 400)
        self.assertEqual(self.raw([], body), 400)                                       # missing
        self.assertEqual(self.raw([("Transfer-Encoding", "chunked")], b"1a\r\n" + body + b"\r\n0\r\n\r\n"), 400)
        self.assertEqual(self.raw([("Content-Length", str(len(body)))], body), 200)
        self.assertEqual(post(self.port, "/v1/waitlist", ["not", "an", "object"])[0], 400)

    def test_notify_needs_subscription(self):
        code, body = post(self.port, "/v1/notify", {"device": "ab" * 32, "env": "sandbox", "jws": "x.y.z"})
        self.assertEqual((code, body.get("reason")), (402, "invalid"), body)

    def test_refusal_reasons(self):
        for payload, reason in [(transaction(expiresDate=int((time.time() - 60) * 1000)), "expired"),
                                (transaction(revocationDate=int(time.time() * 1000)), "revoked"),
                                (transaction(bundleId="com.example.fork"), "invalid")]:
            code, body = post(self.port, "/v1/notify", {"device": "ab" * 32, "env": "production", "jws": CHAIN.sign(payload)})
            self.assertEqual((code, body.get("reason")), (402, reason), body)
        forged = Chain(leaf_oids=())
        code, body = post(self.port, "/v1/notify", {"device": "ab" * 32, "jws": forged.sign(transaction())})
        self.assertEqual((code, body.get("reason")), (402, "invalid"), body)

    def test_device_cap(self):
        jws = CHAIN.sign(transaction())
        with mock.patch.object(app, "apns", FakeAPNs()):
            for i in range(5):
                self.assertEqual(post(self.port, "/v1/notify", {"device": f"{i:02x}" * 32, "jws": jws})[0], 200)
            code, body = post(self.port, "/v1/notify", {"device": "ff" * 32, "jws": jws})
            self.assertEqual((code, body.get("reason")), (429, "devices"))
            self.assertEqual(post(self.port, "/v1/notify", {"device": "00" * 32, "jws": jws})[0], 200)     # one of the five
            other = CHAIN.sign(transaction(originalTransactionId="2000000000000042"))
            self.assertEqual(post(self.port, "/v1/notify", {"device": "ff" * 32, "jws": other})[0], 200)

    def test_refused_push_takes_no_place(self):
        jws = CHAIN.sign(transaction())
        with mock.patch.object(app, "apns", FakeAPNs(answer=(400, '{"reason":"BadDeviceToken"}'))):
            for i in range(10):
                self.assertEqual(post(self.port, "/v1/notify", {"device": f"{i:02x}" * 32, "jws": jws})[0], 502)
        with mock.patch.object(app, "apns", FakeAPNs()):
            self.assertEqual(post(self.port, "/v1/notify", {"device": "ee" * 32, "jws": jws})[0], 200)

    def test_rate_per_device(self):
        jws = CHAIN.sign(transaction())
        with mock.patch.object(app, "apns", FakeAPNs()), mock.patch.object(app, "recent", app.Window(2, 3600)):
            for _ in range(2):
                self.assertEqual(post(self.port, "/v1/notify", {"device": "ab" * 32, "jws": jws})[0], 200)
            code, body = post(self.port, "/v1/notify", {"device": "ab" * 32, "jws": jws})
            self.assertEqual((code, body.get("reason")), (429, "rate"))

    def test_failed_push_logs_no_token(self):
        device = "cd" * 32
        failure = httpx.ConnectError(f"cannot reach https://api.push.apple.com/3/device/{device}")
        out = io.StringIO()
        with mock.patch.object(app, "apns", FakeAPNs(fail=failure)), contextlib.redirect_stdout(out):
            code, body = post(self.port, "/v1/notify", {"device": device, "jws": CHAIN.sign(transaction())})
        self.assertEqual(code, 502)
        self.assertNotIn(device, out.getvalue() + json.dumps(body))
        self.assertIn("ConnectError", out.getvalue())

    def test_bad_device(self):
        self.assertEqual(post(self.port, "/v1/notify", {"device": "nope"})[0], 400)
        self.assertEqual(post(self.port, "/v1/notify", {"device": "ab" * 32, "env": "staging"})[0], 400)

    def test_health(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health") as r:
            self.assertEqual(json.loads(r.read()), {"ok": True, "push": False})


class Busy(unittest.TestCase):
    def test_full_server_answers_503(self):
        server = app.Server(("127.0.0.1", 0), app.Handler, limit=1)
        port = server.server_address[1]
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            slow = socket.create_connection(("127.0.0.1", port))
            slow.sendall(b"POST /v1/waitlist HTTP/1.1\r\n")        # holds the one place, headers unfinished
            deadline = time.time() + 5
            while server.slots._value and time.time() < deadline:
                time.sleep(0.01)
            with socket.create_connection(("127.0.0.1", port), timeout=5) as second:
                self.assertTrue(second.recv(100).startswith(b"HTTP/1.1 503"))
            slow.close()
            deadline = time.time() + 5
            while not server.slots._value and time.time() < deadline:
                time.sleep(0.01)
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=5) as r:
                self.assertEqual(r.status, 200)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
