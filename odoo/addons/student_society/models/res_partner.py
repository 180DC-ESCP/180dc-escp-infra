from odoo import api, fields, models


class ResPartner(models.Model):
    _inherit = "res.partner"

    society_email_180 = fields.Char(string="180 Email", index=True)
    society_email_private = fields.Char(string="Private Email")
    society_email_escp = fields.Char(string="ESCP Email")
    society_program = fields.Char(string="Program")
    society_languages = fields.Char(string="Languages")
    society_nationality = fields.Char(string="Nationality")
    society_cv_url = fields.Char(string="CV Drive URL")
    society_date_of_birth = fields.Date(string="Date of Birth", groups="student_society.group_society_recruitment_membership,student_society.group_society_admin,base.group_system")
    society_estimated_graduation_date = fields.Date(string="Estimated Graduation Date")
    society_joining_date = fields.Date(string="Joining Date")
    society_is_member = fields.Boolean(string="Society Member", default=False, index=True)
    society_is_client = fields.Boolean(string="Client Company", default=False, index=True)
    society_is_client_contact = fields.Boolean(string="Client Person", default=False, index=True)
    society_client_logo_url = fields.Char(string="Client Logo URL")
    society_membership_assignment_ids = fields.One2many(
        "society.member.assignment",
        "partner_id",
        string="Membership Assignments",
    )
    society_project_participation_ids = fields.One2many(
        "society.project.participant",
        "partner_id",
        string="Project Participations",
    )
    society_current_project_ids = fields.Many2many(
        "society.project",
        compute="_compute_society_current_project_ids",
        string="Current Projects",
    )

    @api.depends("society_project_participation_ids.project_id.date_start", "society_project_participation_ids.project_id.date_end")
    def _compute_society_current_project_ids(self):
        today = fields.Date.context_today(self)
        for partner in self:
            partner.society_current_project_ids = partner.society_project_participation_ids.mapped("project_id").filtered(
                lambda project: (not project.date_start or project.date_start <= today)
                and (not project.date_end or project.date_end >= today)
            )
