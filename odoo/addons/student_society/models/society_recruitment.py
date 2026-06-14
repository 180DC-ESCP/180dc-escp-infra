from odoo import api, fields, models


class SocietyRecruitmentStage(models.Model):
    _name = "society.recruitment.stage"
    _description = "Recruitment Stage"
    _order = "sequence, name"

    name = fields.Char(required=True)
    sequence = fields.Integer(default=10)
    fold = fields.Boolean()
    is_accepted = fields.Boolean()
    is_refused = fields.Boolean()


class SocietyRecruitmentSource(models.Model):
    _name = "society.recruitment.source"
    _description = "Recruitment Source"
    _order = "name"

    name = fields.Char(required=True)

    _name_unique = models.Constraint("unique(name)", "Recruitment source names must be unique.")


class SocietyApplicant(models.Model):
    _name = "society.applicant"
    _description = "Society Applicant"
    _inherit = ["mail.thread", "mail.activity.mixin"]
    _order = "create_date desc"

    name = fields.Char(required=True, tracking=True)
    partner_id = fields.Many2one("res.partner", string="Contact", ondelete="set null", tracking=True)
    stage_id = fields.Many2one("society.recruitment.stage", required=True, tracking=True)
    campus_id = fields.Many2one("society.campus", ondelete="restrict", tracking=True)
    source_id = fields.Many2one("society.recruitment.source", ondelete="set null")
    role_id = fields.Many2one("society.role", string="Target Role", ondelete="restrict")
    assignment_start_date = fields.Date(string="Assignment Start Date")
    assignment_end_date = fields.Date(string="Assignment End Date")
    email_180 = fields.Char(string="180 Email")
    email_private = fields.Char(string="Private Email")
    email_escp = fields.Char(string="ESCP Email")
    phone = fields.Char()
    program = fields.Char()
    languages = fields.Char()
    nationality = fields.Char()
    cv_url = fields.Char(string="CV Drive URL")
    date_of_birth = fields.Date(groups="student_society.group_society_recruitment_membership,student_society.group_society_admin,base.group_system")
    note = fields.Html()
    state = fields.Selection(
        selection=[
            ("open", "Open"),
            ("accepted", "Accepted"),
            ("refused", "Refused"),
        ],
        compute="_compute_state",
        store=True,
    )

    @api.depends("stage_id.is_accepted", "stage_id.is_refused")
    def _compute_state(self):
        for applicant in self:
            if applicant.stage_id.is_accepted:
                applicant.state = "accepted"
            elif applicant.stage_id.is_refused:
                applicant.state = "refused"
            else:
                applicant.state = "open"

    def action_create_or_update_contact(self):
        Partner = self.env["res.partner"].sudo()
        for applicant in self:
            partner = applicant.partner_id
            domain = []
            if applicant.email_180:
                domain = ["|", ("society_email_180", "=", applicant.email_180), ("email", "=", applicant.email_180)]
            elif applicant.email_escp:
                domain = [("society_email_escp", "=", applicant.email_escp)]
            elif applicant.email_private:
                domain = [("society_email_private", "=", applicant.email_private)]
            if not partner and domain:
                partner = Partner.search(domain, limit=1)
            values = applicant._contact_values()
            if partner:
                partner.write(values)
            else:
                partner = Partner.create(values)
            applicant.partner_id = partner.id
        return True

    def action_accept_member(self):
        member_group = self.env.ref("student_society.group_society_member")
        internal_group = self.env.ref("base.group_user")
        User = self.env["res.users"].sudo().with_context(no_reset_password=True, mail_create_nosubscribe=True)
        Assignment = self.env["society.member.assignment"].sudo()
        for applicant in self:
            applicant.action_create_or_update_contact()
            partner = applicant.partner_id.sudo()
            partner.write({"society_is_member": True})
            if applicant.email_180:
                user = User.search([("login", "=", applicant.email_180)], limit=1)
                groups = [internal_group.id, member_group.id]
                if user:
                    user.write({"partner_id": partner.id, "email": applicant.email_180, "group_ids": [(4, member_group.id)]})
                else:
                    User.create(
                        {
                            "name": partner.name,
                            "login": applicant.email_180,
                            "email": applicant.email_180,
                            "partner_id": partner.id,
                            "group_ids": [(6, 0, groups)],
                        }
                    )
            if applicant.role_id:
                assignment = Assignment.search(
                    [
                        ("partner_id", "=", partner.id),
                        ("date_start", "=", applicant.assignment_start_date or fields.Date.context_today(applicant)),
                    ],
                    limit=1,
                )
                values = {
                    "partner_id": partner.id,
                    "date_start": applicant.assignment_start_date or fields.Date.context_today(applicant),
                    "date_end": applicant.assignment_end_date,
                    "role_id": applicant.role_id.id,
                    "campus_id": applicant.campus_id.id if applicant.campus_id else False,
                }
                if assignment:
                    assignment.write(values)
                else:
                    Assignment.create(values)
        return True

    def _contact_values(self):
        self.ensure_one()
        return {
            "name": self.name,
            "email": self.email_180 or self.email_escp or self.email_private,
            "phone": self.phone,
            "society_email_180": self.email_180,
            "society_email_private": self.email_private,
            "society_email_escp": self.email_escp,
            "society_program": self.program,
            "society_languages": self.languages,
            "society_nationality": self.nationality,
            "society_cv_url": self.cv_url,
            "society_date_of_birth": self.date_of_birth,
            "society_estimated_graduation_date": self.assignment_end_date,
        }
