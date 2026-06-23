from odoo import fields, models


class CalendarEvent(models.Model):
    _inherit = "calendar.event"

    society_google_event_id = fields.Char(string="Google Event ID", index=True, copy=False)
    society_connected_account_id = fields.Many2one(
        "society.connected.account",
        string="Google Connected Account",
        ondelete="set null",
        index=True,
        copy=False,
    )
    society_google_synced_at = fields.Datetime(string="Google Synced At", copy=False)

    _society_google_event_account_unique = models.Constraint(
        "unique(society_connected_account_id, society_google_event_id)",
        "A Google event can only be linked once per connected account.",
    )
