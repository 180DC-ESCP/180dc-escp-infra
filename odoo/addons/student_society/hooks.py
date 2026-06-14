import re

from odoo import SUPERUSER_ID, api


def post_init_hook(*args):
    if len(args) == 1 and isinstance(args[0], api.Environment):
        env = args[0]
    else:
        env = api.Environment(args[0], SUPERUSER_ID, {})
    importer = SocietyImporter(env)
    importer.run()


class SocietyImporter:
    def __init__(self, env):
        self.env = env

    def run(self):
        self._seed_recruitment_stages()
        self._seed_default_roles()

    def _seed_recruitment_stages(self):
        Stage = self.env["society.recruitment.stage"].sudo()
        stages = [
            ("Applied", 10, False, False, False),
            ("Screening", 20, False, False, False),
            ("Interview", 30, False, False, False),
            ("Decision", 40, False, False, False),
            ("Accepted", 50, True, True, False),
            ("Refused", 60, True, False, True),
        ]
        for name, sequence, fold, is_accepted, is_refused in stages:
            stage = Stage.search([("name", "=", name)], limit=1)
            values = {
                "name": name,
                "sequence": sequence,
                "fold": fold,
                "is_accepted": is_accepted,
                "is_refused": is_refused,
            }
            if stage:
                stage.write(values)
            else:
                Stage.create(values)

    def _seed_default_roles(self):
        departments = [
            "People & Organization",
            "Finance",
            "Marketing",
            "Operations",
            "Business Development",
            "Consulting",
        ]
        role_specs = [
            ("Consultant", "consulting", "", 10, None),
            ("Senior Consultant", "consulting", "", 20, None),
            ("Project Leader", "consulting", "", 30, "student_society.group_society_project_leader"),
            ("Vice President", "presidency", "", 90, "student_society.group_society_admin"),
            ("President", "presidency", "", 100, "student_society.group_society_admin"),
        ]
        for department in departments:
            role_specs.append((f"Associate Director, {department}", "executive", department, 50, None))
            group_xmlid = "student_society.group_society_project_management" if department == "Consulting" else None
            if department == "People & Organization":
                group_xmlid = "student_society.group_society_recruitment_membership"
            role_specs.append((f"Head of {department}", "executive", department, 70, group_xmlid))
        for name, track, department, rank, group_xmlid in role_specs:
            group = self.env.ref(group_xmlid, raise_if_not_found=False) if group_xmlid else False
            self._upsert_role(name, track, department, rank, group)

    def _upsert_role(self, name, track, department, rank, group):
        Role = self.env["society.role"].sudo()
        role = Role.search([("name", "=", name)], limit=1)
        values = {
            "name": name,
            "track": track,
            "department": department,
            "seniority_rank": rank,
            "management_group_id": group.id if group else False,
        }
        if role:
            role.write(values)
        else:
            role = Role.create(values)
        return role

def clean(value):
    if value is None:
        return False
    value = str(value).strip()
    return value or False


def normalize(value):
    value = clean(value)
    if not value:
        return ""
    return re.sub(r"[^a-z0-9]+", "", value.lower())


def normalized_department(department):
    if not department:
        return ""
    if normalize(department) == "consultants":
        return ""
    return department


def role_name_from_position(position, department):
    position = position or "Member"
    department = normalized_department(department)
    key = normalize(position)
    if key in {"consultant", "seniorconsultant", "projectleader", "president", "vicepresident"}:
        return canonical_position(position)
    if department and key in {"associatedirector", "headof", "head"}:
        title = "Associate Director" if key == "associatedirector" else "Head of"
        return f"{title}, {department}" if title == "Associate Director" else f"{title} {department}"
    return canonical_position(position) if not department else f"{canonical_position(position)}, {department}"


def canonical_position(position):
    mapping = {
        "consultant": "Consultant",
        "seniorconsultant": "Senior Consultant",
        "projectleader": "Project Leader",
        "associatedirector": "Associate Director",
        "headof": "Head of",
        "head": "Head of",
        "vicepresident": "Vice President",
        "president": "President",
    }
    return mapping.get(normalize(position), position)


def role_track(position, department):
    key = normalize(position)
    if key in {"president", "vicepresident"}:
        return "presidency"
    if key in {"consultant", "seniorconsultant", "projectleader"} or normalize(department) == "consultants":
        return "consulting"
    return "executive"


def role_rank(position):
    return {
        "consultant": 10,
        "seniorconsultant": 20,
        "projectleader": 30,
        "associatedirector": 50,
        "headof": 70,
        "head": 70,
        "vicepresident": 90,
        "president": 100,
    }.get(normalize(position), 100)
