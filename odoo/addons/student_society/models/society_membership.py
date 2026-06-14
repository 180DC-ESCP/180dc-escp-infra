from odoo import api, exceptions, fields, models


class SocietyRole(models.Model):
    _name = "society.role"
    _description = "Society Role"
    _order = "seniority_rank, name"

    name = fields.Char(required=True)
    track = fields.Selection(
        selection=[
            ("consulting", "Consulting Team"),
            ("executive", "Executive Team"),
            ("presidency", "Presidency"),
        ],
        string="Role Area",
        required=True,
        default="consulting",
    )
    department = fields.Char(string="Department")
    seniority_rank = fields.Integer(string="Sort Order", default=100)
    management_group_id = fields.Many2one(
        "res.groups",
        string="Mapped Access Group",
        help="Optional Odoo access group to grant to users when this society role should imply system permissions.",
    )

    _name_unique = models.Constraint("unique(name)", "Role names must be unique.")


class SocietyMemberAssignment(models.Model):
    _name = "society.member.assignment"
    _description = "Member Assignment"
    _order = "date_start desc, partner_id"
    _rec_name = "display_name"

    display_name = fields.Char(compute="_compute_display_name")
    partner_id = fields.Many2one(
        "res.partner",
        string="Member",
        required=True,
        domain=[("society_is_member", "=", True)],
        ondelete="cascade",
        index=True,
    )
    date_start = fields.Date(required=True, index=True)
    date_end = fields.Date(index=True)
    campus_id = fields.Many2one("society.campus", ondelete="restrict")
    role_id = fields.Many2one("society.role", required=True, ondelete="restrict")
    is_current = fields.Boolean(compute="_compute_is_current", string="Current")

    @api.model_create_multi
    def create(self, vals_list):
        assignments = super().create(vals_list)
        assignments._apply_mapped_access_groups()
        return assignments

    def write(self, vals):
        result = super().write(vals)
        if {"partner_id", "role_id", "date_start", "date_end"} & set(vals):
            self._apply_mapped_access_groups()
        return result

    @api.depends("date_start", "date_end")
    def _compute_is_current(self):
        today = fields.Date.context_today(self)
        for assignment in self:
            assignment.is_current = bool(
                assignment.date_start
                and assignment.date_start <= today
                and (not assignment.date_end or assignment.date_end >= today)
            )

    @api.depends("partner_id", "date_start", "date_end", "role_id", "campus_id")
    def _compute_display_name(self):
        for assignment in self:
            parts = [
                assignment.partner_id.name,
                assignment.role_id.name,
                assignment.campus_id.name,
                assignment.date_start and fields.Date.to_string(assignment.date_start),
                assignment.date_end and fields.Date.to_string(assignment.date_end),
            ]
            assignment.display_name = " / ".join(part for part in parts if part)

    @api.constrains("partner_id", "date_start", "date_end")
    def _check_date_range(self):
        for assignment in self:
            if assignment.date_end and assignment.date_end < assignment.date_start:
                raise exceptions.ValidationError("Assignment end date cannot be before the start date.")
            domain = [
                ("id", "!=", assignment.id),
                ("partner_id", "=", assignment.partner_id.id),
                ("date_start", "<=", assignment.date_end or fields.Date.to_date("9999-12-31")),
                "|",
                ("date_end", "=", False),
                ("date_end", ">=", assignment.date_start),
            ]
            if self.search_count(domain):
                raise exceptions.ValidationError("A member cannot have overlapping role/campus assignments.")

    def _apply_mapped_access_groups(self):
        today = fields.Date.context_today(self)
        for assignment in self:
            group = assignment.role_id.management_group_id
            if not group:
                continue
            if assignment.date_start and assignment.date_start <= today and (not assignment.date_end or assignment.date_end >= today):
                users = self.env["res.users"].sudo().search([("partner_id", "=", assignment.partner_id.id)])
                users.write({"group_ids": [(4, group.id)]})
