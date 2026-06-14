from odoo import api, exceptions, fields, models


class SocietyProject(models.Model):
    _name = "society.project"
    _description = "Consulting Project"
    _inherit = ["mail.thread", "mail.activity.mixin"]
    _order = "date_start desc, name"

    name = fields.Char(string="Project Title", required=True, tracking=True)
    client_id = fields.Many2one(
        "res.partner",
        string="Client",
        required=True,
        domain=[("is_company", "=", True)],
        tracking=True,
    )
    website = fields.Char(related="client_id.website", readonly=False)
    country_id = fields.Many2one(related="client_id.country_id", readonly=False)
    poc_id = fields.Many2one(
        "res.partner",
        string="Client Person",
        domain="[('is_company', '=', False), ('parent_id', '=', client_id)]",
    )
    date_start = fields.Date(tracking=True)
    date_end = fields.Date(tracking=True)
    gtm_vertical = fields.Char(string="GTM Vertical")
    project_type = fields.Char()
    confidentiality = fields.Selection(
        selection=[
            ("undisclosed", "Undisclosed"),
            ("confidential", "Confidential"),
            ("semi_public", "Semi-public"),
            ("public", "Public"),
        ],
        default="confidential",
        required=True,
        tracking=True,
    )
    summary = fields.Text()
    note = fields.Text()
    financial_contribution = fields.Monetary(
        string="Financial Contribution",
        groups="student_society.group_society_project_management,student_society.group_society_admin,base.group_system",
    )
    currency_id = fields.Many2one("res.currency", default=lambda self: self.env.company.currency_id)
    client_logo_url = fields.Char()
    contract_url = fields.Char(string="Contract URL")
    scoping_document_url = fields.Char(string="Scoping Document URL")
    final_presentation_url = fields.Char(string="Final Presentation URL")
    more_documents_url = fields.Char(string="More Documents URL")
    participant_ids = fields.One2many("society.project.participant", "project_id", string="Participants")
    participant_partner_ids = fields.Many2many(
        "res.partner",
        compute="_compute_participant_partner_ids",
        string="Participant Contacts",
    )
    project_lead_id = fields.Many2one("res.partner", string="Project Lead")

    @api.depends("participant_ids.partner_id")
    def _compute_participant_partner_ids(self):
        for project in self:
            project.participant_partner_ids = project.participant_ids.mapped("partner_id")

    @api.constrains("project_lead_id", "participant_ids")
    def _check_project_lead_is_participant(self):
        for project in self:
            if project.project_lead_id and project.project_lead_id not in project.participant_partner_ids:
                raise exceptions.ValidationError("Project lead must be one of the project participants.")


class SocietyProjectParticipant(models.Model):
    _name = "society.project.participant"
    _description = "Project Participant"
    _order = "project_id, partner_id"

    project_id = fields.Many2one("society.project", required=True, ondelete="cascade", index=True)
    partner_id = fields.Many2one(
        "res.partner",
        string="Member",
        required=True,
        domain=[("society_is_member", "=", True)],
        ondelete="cascade",
        index=True,
    )
    assignment_id = fields.Many2one(
        "society.member.assignment",
        compute="_compute_assignment",
        store=True,
    )
    role_id = fields.Many2one(related="assignment_id.role_id", string="Assignment Role", store=True)
    campus_id = fields.Many2one(related="assignment_id.campus_id", string="Assignment Campus", store=True)
    is_project_lead = fields.Boolean(compute="_compute_is_project_lead", store=True)

    _project_partner_unique = models.Constraint(
        "unique(project_id, partner_id)",
        "This member is already linked to the project.",
    )

    @api.depends("project_id.date_start", "project_id.date_end", "partner_id")
    def _compute_assignment(self):
        Assignment = self.env["society.member.assignment"]
        for participant in self:
            participant.assignment_id = False
            if not participant.partner_id:
                continue
            project_start = participant.project_id.date_start or fields.Date.to_date("1900-01-01")
            project_end = participant.project_id.date_end or fields.Date.to_date("9999-12-31")
            participant.assignment_id = Assignment.search(
                [
                    ("partner_id", "=", participant.partner_id.id),
                    ("date_start", "<=", project_end),
                    "|",
                    ("date_end", "=", False),
                    ("date_end", ">=", project_start),
                ],
                order="date_start desc, id desc",
                limit=1,
            )

    @api.depends("project_id.project_lead_id", "partner_id")
    def _compute_is_project_lead(self):
        for participant in self:
            participant.is_project_lead = participant.partner_id == participant.project_id.project_lead_id
