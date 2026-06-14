import json
import secrets
from urllib import parse, request

from odoo import http
from odoo.exceptions import UserError
from odoo.http import request as odoo_request


class SocietyOAuthController(http.Controller):
    @http.route("/society/oauth/google/connect", type="http", auth="user")
    def google_connect(self, **kwargs):
        params = odoo_request.env["ir.config_parameter"].sudo()
        client_id = params.get_param("student_society.google_client_id")
        if not client_id:
            raise UserError("Google OAuth client ID is not configured.")
        state = self._new_state("google")
        query = {
            "client_id": client_id,
            "redirect_uri": self._callback_url("google"),
            "response_type": "code",
            "scope": " ".join(
                [
                    "openid",
                    "email",
                    "profile",
                    "https://www.googleapis.com/auth/calendar.events",
                ]
            ),
            "access_type": "offline",
            "prompt": "consent",
            "state": state,
        }
        return odoo_request.redirect("https://accounts.google.com/o/oauth2/v2/auth?" + parse.urlencode(query))

    @http.route("/society/oauth/google/callback", type="http", auth="user")
    def google_callback(self, **kwargs):
        self._check_state("google", kwargs.get("state"))
        code = kwargs.get("code")
        if not code:
            return self._plain_response("Google authorization did not return a code.")
        params = odoo_request.env["ir.config_parameter"].sudo()
        token_payload = {
            "code": code,
            "client_id": params.get_param("student_society.google_client_id"),
            "client_secret": params.get_param("student_society.google_client_secret"),
            "redirect_uri": self._callback_url("google"),
            "grant_type": "authorization_code",
        }
        token = self._post_form("https://oauth2.googleapis.com/token", token_payload)
        userinfo = self._get_json(
            "https://openidconnect.googleapis.com/v1/userinfo",
            token.get("access_token"),
        )
        self._upsert_account(
            provider="google",
            external_id=userinfo.get("sub"),
            external_email=userinfo.get("email"),
            scopes=token.get("scope"),
            access_token=token.get("access_token"),
            refresh_token=token.get("refresh_token"),
            expires_in=token.get("expires_in"),
        )
        return odoo_request.redirect("/web#action=student_society.action_society_connected_accounts")

    @http.route("/society/oauth/slack/connect", type="http", auth="user")
    def slack_connect(self, **kwargs):
        params = odoo_request.env["ir.config_parameter"].sudo()
        client_id = params.get_param("student_society.slack_client_id")
        if not client_id:
            raise UserError("Slack OAuth client ID is not configured.")
        state = self._new_state("slack")
        query = {
            "client_id": client_id,
            "redirect_uri": self._callback_url("slack"),
            "scope": params.get_param("student_society.slack_bot_scopes") or "chat:write,users:read,users:read.email",
            "user_scope": params.get_param("student_society.slack_user_scopes") or "identity.basic,identity.email",
            "state": state,
        }
        return odoo_request.redirect("https://slack.com/oauth/v2/authorize?" + parse.urlencode(query))

    @http.route("/society/oauth/slack/callback", type="http", auth="user")
    def slack_callback(self, **kwargs):
        self._check_state("slack", kwargs.get("state"))
        code = kwargs.get("code")
        if not code:
            return self._plain_response("Slack authorization did not return a code.")
        params = odoo_request.env["ir.config_parameter"].sudo()
        token = self._post_form(
            "https://slack.com/api/oauth.v2.access",
            {
                "code": code,
                "client_id": params.get_param("student_society.slack_client_id"),
                "client_secret": params.get_param("student_society.slack_client_secret"),
                "redirect_uri": self._callback_url("slack"),
            },
        )
        if not token.get("ok", True):
            return self._plain_response(f"Slack OAuth failed: {token.get('error')}")
        authed_user = token.get("authed_user") or {}
        if token.get("access_token"):
            params.set_param("student_society.slack_bot_access_token", token.get("access_token"))
        if token.get("bot_user_id"):
            params.set_param("student_society.slack_bot_user_id", token.get("bot_user_id"))
        self._upsert_account(
            provider="slack",
            external_id=authed_user.get("id") or token.get("bot_user_id"),
            external_email=False,
            scopes=",".join(filter(None, [token.get("scope"), authed_user.get("scope")])),
            access_token=authed_user.get("access_token"),
            refresh_token=token.get("refresh_token"),
            expires_in=token.get("expires_in"),
        )
        return odoo_request.redirect("/web#action=student_society.action_society_connected_accounts")

    def _new_state(self, provider):
        state = secrets.token_urlsafe(32)
        odoo_request.session[f"society_oauth_state_{provider}"] = state
        return state

    def _check_state(self, provider, state):
        expected = odoo_request.session.pop(f"society_oauth_state_{provider}", None)
        if not expected or not state or expected != state:
            raise UserError("OAuth state validation failed.")

    def _callback_url(self, provider):
        base_url = odoo_request.env["ir.config_parameter"].sudo().get_param("web.base.url")
        return f"{base_url}/society/oauth/{provider}/callback"

    def _upsert_account(self, provider, external_id, external_email, scopes, access_token, refresh_token, expires_in):
        partner = odoo_request.env.user.partner_id
        Account = odoo_request.env["society.connected.account"].sudo()
        account = Account.search([("partner_id", "=", partner.id), ("provider", "=", provider)], limit=1)
        values = {
            "partner_id": partner.id,
            "user_id": odoo_request.env.user.id,
            "provider": provider,
            "external_id": external_id,
            "external_email": external_email,
            "granted_scopes": scopes,
            "token_status": "connected",
            "access_token": access_token,
            "last_sync_at": False,
        }
        if refresh_token:
            values["refresh_token"] = refresh_token
        if expires_in:
            values["token_expires_at"] = odoo_request.env["society.connected.account"]._expires_at(int(expires_in))
        if account:
            account.write(values)
        else:
            Account.create(values)

    def _post_form(self, url, payload):
        data = parse.urlencode(payload).encode()
        req = request.Request(url, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
        with request.urlopen(req, timeout=20) as response:
            return json.loads(response.read().decode())

    def _get_json(self, url, access_token):
        req = request.Request(url, headers={"Authorization": f"Bearer {access_token}"})
        with request.urlopen(req, timeout=20) as response:
            return json.loads(response.read().decode())

    def _plain_response(self, body):
        return odoo_request.make_response(body, headers=[("Content-Type", "text/plain; charset=utf-8")])
