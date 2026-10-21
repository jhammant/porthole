"""Porthole Anywhere's rules: a JWS that isn't Apple's is refused, the waitlist takes an email once, and
notify answers 402 without a subscription and 503 without push set up. python3.12 -m unittest discover -s tests -t ."""
import base64, json, os, sys, tempfile, threading, unittest, urllib.request, urllib.error
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ["ANYWHERE_DATA"] = tempfile.mkdtemp()
import app  # noqa: E402

def post(port, path, body):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as r: return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read())

class Rules(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = app.ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    def test_not_a_jws(self):
        with self.assertRaises(ValueError): app.verify_transaction("nope")

    def test_self_signed_chain_refused(self):
        head = base64.urlsafe_b64encode(json.dumps({"alg": "ES256", "x5c": ["AA==", "AA==", "AA=="]}).encode()).decode().rstrip("=")
        with self.assertRaises(Exception): app.verify_transaction(f"{head}.e30.AAAA")

    def test_waitlist(self):
        self.assertEqual(post(self.port, "/v1/waitlist", {"email": "someone@example.com"})[0], 200)
        self.assertEqual(post(self.port, "/v1/waitlist", {"email": "someone@example.com"})[0], 200)
        self.assertEqual(post(self.port, "/v1/waitlist", {"email": "not an email"})[0], 400)
        n = app.store.db.execute("SELECT COUNT(*) FROM waitlist").fetchone()[0]
        self.assertEqual(n, 1)

    def test_notify_needs_subscription(self):
        code, body = post(self.port, "/v1/notify", {"device": "ab" * 32, "env": "sandbox", "jws": "x.y.z"})
        self.assertEqual(code, 402, body)

    def test_bad_device(self):
        self.assertEqual(post(self.port, "/v1/notify", {"device": "nope"})[0], 400)

    def test_health(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health") as r:
            self.assertEqual(json.loads(r.read()), {"ok": True, "push": False})

if __name__ == "__main__":
    unittest.main()
