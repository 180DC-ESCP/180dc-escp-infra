from odoo import fields, models


class ResConfigSettings(models.TransientModel):
    _inherit = "res.config.settings"

    society_google_client_id = fields.Char(
        string="Google OAuth Client ID",
        config_parameter="student_society.google_client_id",
    )
    society_google_client_secret = fields.Char(
        string="Google OAuth Client Secret",
        config_parameter="student_society.google_client_secret",
    )
    society_slack_client_id = fields.Char(
        string="Slack OAuth Client ID",
        config_parameter="student_society.slack_client_id",
    )
    society_slack_client_secret = fields.Char(
        string="Slack OAuth Client Secret",
        config_parameter="student_society.slack_client_secret",
    )
    society_slack_bot_scopes = fields.Char(
        string="Slack Bot Scopes",
        config_parameter="student_society.slack_bot_scopes",
        default="chat:write,users:read,users:read.email",
    )
    society_slack_user_scopes = fields.Char(
        string="Slack User Scopes",
        config_parameter="student_society.slack_user_scopes",
        default="identity.basic,identity.email",
    )
