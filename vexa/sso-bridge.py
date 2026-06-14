#!/usr/bin/env python3
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ALLOWED_DOMAIN = os.environ.get("AUTHENTIK_ALLOWED_EMAIL_DOMAIN", "180dc.org").lstrip("@").lower()
PLATFORM_ADMIN_EMAIL = os.environ.get("PLATFORM_ADMIN_EMAIL", "escp@180dc.org").strip().lower()
ADMIN_API_URL = os.environ.get("VEXA_ADMIN_API_URL", "http://vexa-lite:8056").rstrip("/")
ADMIN_TOKEN = os.environ["VEXA_ADMIN_API_KEY"]
TOKEN_SCOPES = os.environ.get("VEXA_SSO_TOKEN_SCOPES", "bot,tx,browser")
MAX_CONCURRENT_BOTS = int(os.environ.get("VEXA_SSO_MAX_CONCURRENT_BOTS", "1"))
AUTH_COOKIE = os.environ.get("VEXA_AUTH_COOKIE_NAME", "vexa-token-lite")
USER_COOKIE = os.environ.get("VEXA_USER_INFO_COOKIE_NAME", "vexa-user-info-lite")
COOKIE_MAX_AGE = int(os.environ.get("VEXA_SSO_COOKIE_MAX_AGE", str(30 * 24 * 60 * 60)))


def allowed_email(email):
    return email == PLATFORM_ADMIN_EMAIL or email.endswith(f"@{ALLOWED_DOMAIN}")


def api_request(method, path, payload=None):
    body = None
    headers = {"X-Admin-API-Key": ADMIN_TOKEN}
    if payload is not None:
        body = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(f"{ADMIN_API_URL}{path}", data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=20) as response:
        return json.loads(response.read().decode() or "{}")


def get_or_create_user(email, name):
    encoded_email = urllib.parse.quote(email, safe="")
    try:
        return api_request("GET", f"/admin/users/email/{encoded_email}")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    return api_request(
        "POST",
        "/admin/users",
        {
            "email": email,
            "name": name or email,
            "max_concurrent_bots": MAX_CONCURRENT_BOTS,
        },
    )


def create_user_token(user_id):
    query = urllib.parse.urlencode({"scopes": TOKEN_SCOPES, "name": "authentik-sso"})
    return api_request("POST", f"/admin/users/{user_id}/tokens?{query}")


def cookie_header(name, value, http_only=True):
    parts = [
        f"{name}={value}",
        "Path=/",
        f"Max-Age={COOKIE_MAX_AGE}",
        "SameSite=Lax",
        "Secure",
    ]
    if http_only:
        parts.append("HttpOnly")
    return "; ".join(parts)


class Handler(BaseHTTPRequestHandler):
    server_version = "vexa-authentik-sso/1.0"

    def do_GET(self):
        if self.path not in {"/login", "/auth/sso"}:
            self.send_error(404)
            return
        try:
            email = (self.headers.get("X-Authentik-Email") or "").strip().lower()
            name = (self.headers.get("X-Authentik-Name") or "").strip() or email
            if not email or not allowed_email(email):
                self.send_error(403, "Authentik identity is missing or not allowed")
                return

            user = get_or_create_user(email, name)
            user_id = user.get("id")
            if not user_id:
                raise RuntimeError(f"Vexa user response did not include id: {user}")
            token = create_user_token(user_id).get("token")
            if not token:
                raise RuntimeError("Vexa token response did not include token")

            user_info = urllib.parse.quote(json.dumps({"email": email, "name": name}, separators=(",", ":")))
            self.send_response(302)
            self.send_header("Set-Cookie", cookie_header(AUTH_COOKIE, token))
            self.send_header("Set-Cookie", cookie_header(USER_COOKIE, user_info))
            self.send_header("Location", "/")
            self.end_headers()
        except Exception as error:
            self.send_error(500, f"SSO login failed: {error}")

    def do_POST(self):
        if self.path != "/api/auth/logout":
            self.send_error(404)
            return
        expired = "Path=/; Max-Age=0; SameSite=Lax; Secure; HttpOnly"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Set-Cookie", f"{AUTH_COOKIE}=; {expired}")
        self.send_header("Set-Cookie", f"{USER_COOKIE}=; {expired}")
        self.end_headers()
        self.wfile.write(b'{"success":true}')

    def log_message(self, fmt, *args):
        print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {self.address_string()} {fmt % args}", flush=True)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
