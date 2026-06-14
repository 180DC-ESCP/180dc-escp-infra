from odoo import fields, models


class SocietyCampus(models.Model):
    _name = "society.campus"
    _description = "Campus"
    _order = "name"

    name = fields.Char(required=True)

    _name_unique = models.Constraint("unique(name)", "Campus names must be unique.")
