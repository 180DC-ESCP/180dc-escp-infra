from odoo import fields, models


class CalendarEvent(models.Model):
    _inherit = "calendar.event"

    society_google_event_id = fields.Char(string="Google Event ID", index=True, copy=False)
    society_google_synced_at = fields.Datetime(string="Google Synced At", copy=False)
