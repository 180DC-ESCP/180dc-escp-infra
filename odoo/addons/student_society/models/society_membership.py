import os

from odoo import api, exceptions, fields, models


PLATFORM_ADMIN_EMAIL = os.environ.get("PLATFORM_ADMIN_EMAIL", "escp@180dc.org").strip().lower()


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

    def write(self, vals):
        previous_group_ids = self.management_group_id.ids
        result = super().write(vals)
        if "management_group_id" in vals:
            partner_ids = self.env["society.member.assignment"].sudo().search(
                [("role_id", "in", self.ids)]
            ).partner_id.ids
            self.env["society.member.assignment"]._reconcile_mapped_access_groups(
                partner_ids,
                additional_managed_group_ids=previous_group_ids,
            )
        return result


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
        assignments._reconcile_mapped_access_groups(assignments.partner_id.ids)
        return assignments

    def write(self, vals):
        previous_partner_ids = self.partner_id.ids
        result = super().write(vals)
        if {"partner_id", "role_id", "date_start", "date_end"} & set(vals):
            self._reconcile_mapped_access_groups(previous_partner_ids + self.partner_id.ids)
        return result

    def unlink(self):
        partner_ids = self.partner_id.ids
        result = super().unlink()
        self._reconcile_mapped_access_groups(partner_ids)
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

    @api.model
    def _cron_reconcile_access_groups(self):
        self._reconcile_mapped_access_groups()

    @api.model
    def _reconcile_mapped_access_groups(self, partner_ids=None, additional_managed_group_ids=None):
        today = fields.Date.context_today(self)
        Role = self.env["society.role"].sudo()
        managed_groups = Role.search([]).management_group_id
        managed_groups |= self.env["res.groups"].sudo().browse(additional_managed_group_ids or [])
        managed_group_ids = set((managed_groups | managed_groups.trans_implied_ids).ids)
        baseline_groups = self.env["res.groups"].sudo().browse(
            [
                self.env.ref("base.group_user").id,
                self.env.ref("student_society.group_society_member").id,
            ]
        )
        managed_group_ids -= set((baseline_groups | baseline_groups.trans_implied_ids).ids)
        if not managed_group_ids:
            return

        user_domain = [("partner_id", "in", partner_ids)] if partner_ids else []
        users = self.env["res.users"].sudo().with_context(active_test=False).search(user_domain)
        for user in users:
            assignments = self.sudo().search(
                [
                    ("partner_id", "=", user.partner_id.id),
                    ("date_start", "<=", today),
                    "|",
                    ("date_end", "=", False),
                    ("date_end", ">=", today),
                ]
            )
            desired_groups = assignments.role_id.management_group_id
            if (user.email or user.login or "").strip().lower() == PLATFORM_ADMIN_EMAIL:
                desired_groups |= self.env.ref("student_society.group_society_admin")
            desired_group_ids = set((desired_groups | desired_groups.trans_implied_ids).ids)
            reconciled_group_ids = (set(user.group_ids.ids) - managed_group_ids) | desired_group_ids
            if reconciled_group_ids != set(user.group_ids.ids):
                user.write({"group_ids": [(6, 0, list(reconciled_group_ids))]})
