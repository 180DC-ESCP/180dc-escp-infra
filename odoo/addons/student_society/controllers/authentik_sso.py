import logging
import os

from odoo import SUPERUSER_ID, http
from odoo.addons.web.controllers.utils import _get_login_redirect_url, ensure_db
from odoo.http import request


_logger = logging.getLogger(__name__)

ALLOWED_DOMAIN = os.environ.get("AUTHENTIK_ALLOWED_EMAIL_DOMAIN", "180dc.org").lstrip("@").lower()
PLATFORM_ADMIN_EMAIL = os.environ.get("PLATFORM_ADMIN_EMAIL", "escp@180dc.org").strip().lower()


def _header(name):
    return (request.httprequest.headers.get(name) or "").strip()


def _allowed_email(email):
    return email == PLATFORM_ADMIN_EMAIL or email.endswith(f"@{ALLOWED_DOMAIN}")


def _safe_redirect(target):
    if target and target.startswith("/") and not target.startswith("//"):
        return target
    return "/odoo"


class AuthentikSSO(http.Controller):
    @http.route("/auth/authentik/login", type="http", auth="none", readonly=False)
    def login(self, redirect=None, **kwargs):
        ensure_db()

        email = _header("X-Authentik-Email").lower()
        name = _header("X-Authentik-Name") or email
        if not email or not _allowed_email(email):
            return request.make_response("Authentik identity is missing or not allowed.", status=403)

        user = self._get_or_create_user(email, name)
        request.session["pre_login"] = user.login
        request.session["pre_uid"] = user.id
        request.session.finalize(request.env)
        request.update_env(user=user.id, context=request.session.context)
        user.sudo()._update_last_login()

        target = _safe_redirect(redirect or kwargs.get("redirect"))
        response = request.redirect(_get_login_redirect_url(user.id, target), 303)
        response.autocorrect_location_header = False
        return response

    def _get_or_create_user(self, email, name):
        env = request.env(
            user=SUPERUSER_ID,
            context={
                **request.env.context,
                "no_reset_password": True,
                "mail_create_nosubscribe": True,
            },
        )
        User = env["res.users"].sudo()
        Partner = env["res.partner"].sudo()

        user = User.search(["|", ("login", "=", email), ("email", "=", email)], limit=1)
        if user:
            self._sync_user(user, email, name)
            return user

        partner = Partner.search(
            [
                "|",
                "|",
                "|",
                ("email", "=", email),
                ("society_email_180", "=", email),
                ("society_email_escp", "=", email),
                ("society_email_private", "=", email),
            ],
            limit=1,
        )

        values = {
            "name": name,
            "login": email,
            "email": email,
            "group_ids": [(6, 0, self._group_ids(env, email))],
        }
        if partner:
            values["partner_id"] = partner.id

        _logger.info("Provisioning Odoo user from Authentik: %s", email)
        return User.create(values)

    def _sync_user(self, user, email, name):
        group_ids = set(user.group_ids.ids).union(self._group_ids(user.env, email))
        values = {"email": email, "group_ids": [(6, 0, list(group_ids))]}
        if name and user.name != name:
            values["name"] = name
        if user.login != email:
            values["login"] = email
        if not user.active:
            values["active"] = True
        user.write(values)

    def _group_ids(self, env, email):
        groups = [
            env.ref("base.group_user").id,
            env.ref("student_society.group_society_member").id,
        ]
        if email == PLATFORM_ADMIN_EMAIL:
            groups.extend(
                [
                    env.ref("base.group_system").id,
                    env.ref("student_society.group_society_admin").id,
                ]
            )
        return groups
