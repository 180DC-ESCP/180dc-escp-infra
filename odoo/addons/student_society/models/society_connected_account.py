from dateutil.relativedelta import relativedelta
import json
from urllib import parse, request

from odoo import exceptions, fields, models


class SocietyConnectedAccount(models.Model):
    _name = "society.connected.account"
    _description = "Connected Account"
    _order = "partner_id, provider"

    partner_id = fields.Many2one(
        "res.partner",
        string="Member",
        required=True,
        domain=[("society_is_member", "=", True)],
        ondelete="cascade",
        index=True,
    )
    user_id = fields.Many2one("res.users", string="Odoo User")
    provider = fields.Selection(
        selection=[
            ("google", "Google Workspace"),
            ("slack", "Slack"),
        ],
        required=True,
        index=True,
    )
    external_id = fields.Char(string="External User ID", index=True)
    external_email = fields.Char()
    granted_scopes = fields.Text()
    google_calendar_id = fields.Char(default="primary")
    token_status = fields.Selection(
        selection=[
            ("not_connected", "Not Connected"),
            ("connected", "Connected"),
            ("expired", "Expired"),
            ("revoked", "Revoked"),
        ],
        default="not_connected",
        required=True,
    )
    access_token = fields.Char(groups="base.group_system")
    refresh_token = fields.Char(groups="base.group_system")
    token_expires_at = fields.Datetime()
    last_sync_at = fields.Datetime()
    notification_enabled = fields.Boolean(default=True)

    _partner_provider_unique = models.Constraint(
        "unique(partner_id, provider)",
        "This member already has this provider connected.",
    )

    def action_connect(self):
        self.ensure_one()
        return {
            "type": "ir.actions.act_url",
            "target": "self",
            "url": f"/society/oauth/{self.provider}/connect",
        }

    def action_disconnect(self):
        self.write(
            {
                "token_status": "revoked",
                "access_token": False,
                "refresh_token": False,
                "token_expires_at": False,
            }
        )
        return True

    def action_sync_google_calendar(self):
        self.ensure_one()
        if self.provider != "google":
            raise exceptions.UserError("Google calendar sync is only available for Google connected accounts.")
        self._google_pull_events()
        self._google_push_events()
        self.last_sync_at = fields.Datetime.now()
        return True

    def action_send_slack_test_notification(self):
        self.ensure_one()
        if self.provider != "slack":
            raise exceptions.UserError("Slack notifications are only available for Slack connected accounts.")
        self._send_slack_dm("Your Slack account is connected to Odoo.")
        return True

    def _expires_at(self, expires_in):
        return fields.Datetime.now() + relativedelta(seconds=expires_in)

    def _google_pull_events(self):
        self.ensure_one()
        base_url = "https://www.googleapis.com/calendar/v3"
        calendar_id = parse.quote(self.google_calendar_id or "primary", safe="")
        now = fields.Datetime.now()
        time_min = (now - relativedelta(days=30)).isoformat() + "Z"
        time_max = (now + relativedelta(days=180)).isoformat() + "Z"
        url = (
            f"{base_url}/calendars/{calendar_id}/events?"
            + parse.urlencode({"singleEvents": "true", "timeMin": time_min, "timeMax": time_max, "orderBy": "startTime"})
        )
        payload = self._google_request("GET", url)
        Event = self.env["calendar.event"].sudo()
        for item in payload.get("items", []):
            if item.get("status") == "cancelled":
                continue
            start = self._google_datetime(item.get("start") or {})
            stop = self._google_datetime(item.get("end") or {})
            if not start or not stop:
                continue
            event = Event.search(
                [
                    ("society_connected_account_id", "=", self.id),
                    ("society_google_event_id", "=", item.get("id")),
                ],
                limit=1,
            )
            values = {
                "name": item.get("summary") or "Google Calendar Event",
                "start": start,
                "stop": stop,
                "description": item.get("description"),
                "partner_ids": [(4, self.partner_id.id)],
                "society_google_event_id": item.get("id"),
                "society_connected_account_id": self.id,
                "society_google_synced_at": fields.Datetime.now(),
            }
            if event:
                event.write(values)
            else:
                Event.create(values)

    def _google_push_events(self):
        self.ensure_one()
        calendar_id = parse.quote(self.google_calendar_id or "primary", safe="")
        Event = self.env["calendar.event"].sudo()
        events = Event.search(
            [
                ("partner_ids", "in", [self.partner_id.id]),
                "|",
                ("society_connected_account_id", "=", False),
                ("society_connected_account_id", "=", self.id),
                ("start", ">=", fields.Datetime.now() - relativedelta(days=1)),
                ("start", "<=", fields.Datetime.now() + relativedelta(days=180)),
            ]
        )
        for event in events:
            payload = {
                "summary": event.name,
                "description": event.description or "",
                "start": {"dateTime": fields.Datetime.to_string(event.start).replace(" ", "T") + "Z"},
                "end": {"dateTime": fields.Datetime.to_string(event.stop).replace(" ", "T") + "Z"},
            }
            if event.society_google_event_id:
                url = f"https://www.googleapis.com/calendar/v3/calendars/{calendar_id}/events/{parse.quote(event.society_google_event_id, safe='')}"
                response = self._google_request("PATCH", url, payload)
            else:
                url = f"https://www.googleapis.com/calendar/v3/calendars/{calendar_id}/events"
                response = self._google_request("POST", url, payload)
            event.write(
                {
                    "society_google_event_id": response.get("id") or event.society_google_event_id,
                    "society_connected_account_id": self.id,
                    "society_google_synced_at": fields.Datetime.now(),
                }
            )

    def _google_datetime(self, payload):
        value = payload.get("dateTime") or payload.get("date")
        if not value:
            return False
        return fields.Datetime.to_datetime(value.replace("Z", "+00:00"))

    def _google_request(self, method, url, payload=None):
        self._ensure_google_access_token()
        data = json.dumps(payload).encode() if payload is not None else None
        headers = {"Authorization": f"Bearer {self.access_token}", "Content-Type": "application/json"}
        req = request.Request(url, data=data, headers=headers, method=method)
        with request.urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode())

    def _ensure_google_access_token(self):
        self.ensure_one()
        if self.token_expires_at and self.token_expires_at > fields.Datetime.now() + relativedelta(minutes=2):
            return
        if not self.refresh_token:
            raise exceptions.UserError("Google refresh token is missing. Reconnect the Google account.")
        params = self.env["ir.config_parameter"].sudo()
        payload = {
            "client_id": params.get_param("student_society.google_client_id"),
            "client_secret": params.get_param("student_society.google_client_secret"),
            "refresh_token": self.refresh_token,
            "grant_type": "refresh_token",
        }
        req = request.Request(
            "https://oauth2.googleapis.com/token",
            data=parse.urlencode(payload).encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        with request.urlopen(req, timeout=30) as response:
            token = json.loads(response.read().decode())
        self.write(
            {
                "access_token": token.get("access_token"),
                "token_expires_at": self._expires_at(int(token.get("expires_in") or 3600)),
                "token_status": "connected",
            }
        )

    def _send_slack_dm(self, text):
        self.ensure_one()
        token = self.env["ir.config_parameter"].sudo().get_param("student_society.slack_bot_access_token") or self.access_token
        if not token:
            raise exceptions.UserError("Slack bot token is missing. Reconnect Slack or configure the bot token.")
        if not self.external_id:
            raise exceptions.UserError("Slack user ID is missing. Reconnect Slack.")
        channel = self._slack_request("https://slack.com/api/conversations.open", token, {"users": self.external_id}).get("channel", {})
        channel_id = channel.get("id")
        if not channel_id:
            raise exceptions.UserError("Could not open a Slack DM channel.")
        self._slack_request("https://slack.com/api/chat.postMessage", token, {"channel": channel_id, "text": text})

    def _slack_request(self, url, token, payload):
        req = request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json; charset=utf-8"},
            method="POST",
        )
        with request.urlopen(req, timeout=20) as response:
            body = json.loads(response.read().decode())
        if not body.get("ok"):
            raise exceptions.UserError(f"Slack API failed: {body.get('error')}")
        return body
