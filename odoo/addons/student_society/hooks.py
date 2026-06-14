import csv
import re
from datetime import date, datetime
from pathlib import Path

from odoo import SUPERUSER_ID, api, fields


IMPORT_ROOTS = [
    Path("/mnt/import"),
    Path("/mnt/import/odoo"),
]
MEMBER_CSV = "Member Database - Member Database.csv"
PROJECT_CSVS = [
    "Client Database - Project Database.csv",
    "Client Database - Client Database.csv",
]


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
        self.member_project_mentions = {}
        self.project_name_index = {}

    def run(self):
        self._seed_recruitment_stages()
        self._seed_default_roles()
        self._import_members()
        self._import_projects()
        self._link_project_participants()

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

    def _csv_path(self, filename):
        for root in IMPORT_ROOTS:
            path = root / filename
            if path.exists():
                return path
        return False

    def _read_csv(self, filename):
        path = self._csv_path(filename)
        if not path:
            return []
        with path.open("r", encoding="utf-8-sig", newline="") as stream:
            return list(csv.DictReader(stream))

    def _import_members(self):
        rows = self._read_csv(MEMBER_CSV)
        Partner = self.env["res.partner"].sudo()
        User = self.env["res.users"].sudo().with_context(no_reset_password=True, mail_create_nosubscribe=True)
        member_group = self.env.ref("student_society.group_society_member")
        internal_group = self.env.ref("base.group_user")

        for row in rows:
            full_name = clean(row.get("Full Name")) or "Unnamed Member"
            email_180 = clean(row.get("Email 180"))
            email_escp = clean(row.get("Email ESCP"))
            email_private = clean(row.get("Email Private"))
            search_domain = []
            if email_180:
                search_domain = ["|", ("society_email_180", "=", email_180), ("email", "=", email_180)]
            elif email_escp:
                search_domain = [("society_email_escp", "=", email_escp)]
            elif email_private:
                search_domain = [("society_email_private", "=", email_private)]
            partner = Partner.search(search_domain, limit=1) if search_domain else Partner.browse()

            values = {
                "name": full_name,
                "is_company": False,
                "society_is_member": True,
                "email": email_180 or email_escp or email_private,
                "phone": clean(row.get("Phone")),
                "society_email_180": email_180,
                "society_email_private": email_private,
                "society_email_escp": email_escp,
                "society_program": clean(row.get("Program")),
                "society_languages": clean(row.get("Languages")),
                "society_nationality": clean(row.get("Nationality")),
                "society_cv_url": clean(row.get("CV Drive")),
                "society_date_of_birth": parse_date(row.get("Date of Birth")),
                "society_estimated_graduation_date": parse_date(row.get("Estimated leaving date")),
                "society_joining_date": parse_date(row.get("Joining Date")),
            }
            if partner:
                partner.write(values)
            else:
                partner = Partner.create(values)

            if email_180:
                self._ensure_user(User, partner, email_180, [internal_group.id, member_group.id])

            role = self._get_or_create_role(clean(row.get("Position")), clean(row.get("Department")))
            campus = self._get_or_create_campus(clean(row.get("Campus")))
            if role:
                assignment_start = values.get("society_joining_date") or fields.Date.context_today(partner)
                assignment = self.env["society.member.assignment"].sudo().search(
                    [("partner_id", "=", partner.id), ("date_start", "=", assignment_start)],
                    limit=1,
                )
                assignment_values = {
                    "partner_id": partner.id,
                    "date_start": assignment_start,
                    "date_end": parse_date(row.get("Leaving Date")),
                    "role_id": role.id,
                    "campus_id": campus.id if campus else False,
                }
                if assignment:
                    assignment.write(assignment_values)
                else:
                    self.env["society.member.assignment"].sudo().create(assignment_values)

            projects = split_multi(row.get("Projects"))
            if projects:
                self.member_project_mentions[partner.id] = projects

    def _ensure_user(self, User, partner, login, group_ids):
        user = User.search([("login", "=", login)], limit=1)
        if user:
            wanted_groups = set(user.group_ids.ids).union(group_ids)
            user.write({"partner_id": partner.id, "email": login, "group_ids": [(6, 0, list(wanted_groups))]})
            return user
        return User.create(
            {
                "name": partner.name,
                "login": login,
                "email": login,
                "partner_id": partner.id,
                "group_ids": [(6, 0, group_ids)],
            }
        )

    def _import_projects(self):
        seen = set()
        for filename in PROJECT_CSVS:
            for row in self._read_csv(filename):
                client_name = clean(row.get("Client Name"))
                if not client_name:
                    continue
                date_start, date_end = project_dates_from_legacy_period(clean(row.get("Cycle (Fall/Spring [Year])")))
                project_type = clean(row.get("Project Type"))
                key = (normalize(client_name), date_start, normalize(project_type), normalize(row.get("POC Email")))
                if key in seen:
                    continue
                seen.add(key)
                client = self._get_or_create_client(row)
                poc = self._get_or_create_poc(client, row)
                project = self.env["society.project"].sudo().search(
                    [
                        ("client_id", "=", client.id),
                        ("date_start", "=", date_start),
                        ("name", "=", client_name),
                        ("project_type", "=", project_type),
                    ],
                    limit=1,
                )
                values = {
                    "name": client_name,
                    "client_id": client.id,
                    "poc_id": poc.id if poc else False,
                    "date_start": date_start,
                    "date_end": date_end,
                    "gtm_vertical": clean(row.get("GTM Vertical")),
                    "project_type": project_type,
                    "financial_contribution": parse_float(row.get("Financial contribution [€]")),
                    "client_logo_url": clean(row.get("Client logo")),
                    "contract_url": clean(row.get("Contract")),
                    "scoping_document_url": clean(row.get("Scoping Document")),
                    "final_presentation_url": clean(row.get("Final Presentation")),
                    "more_documents_url": clean(row.get("More documents")),
                    "note": clean(row.get("Note")),
                    "confidentiality": "confidential",
                }
                if project:
                    project.write(values)
                else:
                    project = self.env["society.project"].sudo().create(values)
                self._index_project(project)

    def _get_or_create_client(self, row):
        Partner = self.env["res.partner"].sudo()
        client_name = clean(row.get("Client Name"))
        website = clean(row.get("Website"))
        client = Partner.search([("is_company", "=", True), ("name", "=", client_name)], limit=1)
        values = {
            "name": client_name,
            "is_company": True,
            "society_is_client": True,
            "website": website,
            "country_id": self._country_id(clean(row.get("Country"))),
            "society_client_logo_url": clean(row.get("Client logo")),
        }
        if client:
            client.write(values)
        else:
            client = Partner.create(values)
        return client

    def _get_or_create_poc(self, client, row):
        poc_email = clean(row.get("POC Email"))
        raw_name = clean(row.get("POC (Name + Position)"))
        if not raw_name and not poc_email:
            return self.env["res.partner"].browse()
        name, function = parse_poc(raw_name)
        Partner = self.env["res.partner"].sudo()
        domain = [("email", "=", poc_email)] if poc_email else [("parent_id", "=", client.id), ("name", "=", name)]
        poc = Partner.search(domain, limit=1)
        values = {
            "name": name or poc_email,
            "email": poc_email,
            "function": function,
            "parent_id": client.id,
            "is_company": False,
            "society_is_client_contact": True,
        }
        if poc:
            poc.write(values)
        else:
            poc = Partner.create(values)
        return poc

    def _link_project_participants(self):
        Participant = self.env["society.project.participant"].sudo()
        for partner_id, project_names in self.member_project_mentions.items():
            for project_name in project_names:
                candidates = self.project_name_index.get(normalize(project_name), [])
                if not candidates:
                    continue
                project = sorted(
                    candidates,
                    key=lambda item: (item.date_start or fields.Date.from_string("1900-01-01"), item.id),
                    reverse=True,
                )[0]
                existing = Participant.search([("project_id", "=", project.id), ("partner_id", "=", partner_id)], limit=1)
                if not existing:
                    Participant.create({"project_id": project.id, "partner_id": partner_id})

    def _index_project(self, project):
        for key in {normalize(project.name), normalize(project.client_id.name)}:
            if key:
                self.project_name_index.setdefault(key, []).append(project)

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

    def _get_or_create_role(self, position, department):
        if not position:
            return self.env["society.role"].browse()
        role_name = role_name_from_position(position, department)
        track = role_track(position, department)
        rank = role_rank(position)
        group = self._group_for_role(position, department)
        return self._upsert_role(role_name, track, normalized_department(department), rank, group)

    def _group_for_role(self, position, department):
        position_key = normalize(position)
        department_key = normalize(department)
        if position_key in {"president", "vicepresident"}:
            return self.env.ref("student_society.group_society_admin")
        if position_key == "projectleader":
            return self.env.ref("student_society.group_society_project_leader")
        if "head" in position_key and department_key in {"consulting", "consultants"}:
            return self.env.ref("student_society.group_society_project_management")
        if "head" in position_key and department_key in {"peopleorganization", "peopleandorganization", "po"}:
            return self.env.ref("student_society.group_society_recruitment_membership")
        return False

    def _get_or_create_campus(self, name):
        if not name:
            return self.env["society.campus"].browse()
        Campus = self.env["society.campus"].sudo()
        campus = Campus.search([("name", "=", name)], limit=1)
        return campus or Campus.create({"name": name})

    def _country_id(self, value):
        if not value:
            return False
        Country = self.env["res.country"].sudo()
        country = Country.search([("code", "=", value.upper())], limit=1)
        if not country:
            country = Country.search([("name", "ilike", value)], limit=1)
        return country.id if country else False


def clean(value):
    if value is None:
        return False
    value = str(value).strip()
    return value or False


def parse_date(value):
    value = clean(value)
    if not value:
        return False
    for date_format in ("%Y-%m-%d", "%m/%d/%Y", "%d/%m/%Y"):
        try:
            return datetime.strptime(value, date_format).date()
        except ValueError:
            continue
    return False


def parse_float(value):
    value = clean(value)
    if not value:
        return 0.0
    value = value.replace("€", "").replace(",", ".").strip()
    try:
        return float(value)
    except ValueError:
        return 0.0


def project_dates_from_legacy_period(value):
    match = re.search(r"(?:(\d{4})\s*(spring|summer|fall)|(spring|summer|fall)\s*(\d{4}))", value or "", re.I)
    if not match:
        return False, False
    year = int(match.group(1) or match.group(4))
    term = (match.group(2) or match.group(3)).lower()
    ranges = {
        "spring": (date(year, 1, 1), date(year, 4, 30)),
        "summer": (date(year, 5, 1), date(year, 8, 31)),
        "fall": (date(year, 9, 1), date(year, 12, 31)),
    }
    return ranges[term]


def split_multi(value):
    value = clean(value)
    if not value:
        return []
    return [part.strip() for part in re.split(r",|;", value) if part.strip()]


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


def parse_poc(value):
    value = clean(value)
    if not value:
        return False, False
    match = re.match(r"^(.*?)\s*\((.*?)\)\s*$", value)
    if match:
        return clean(match.group(1)), clean(match.group(2))
    return value, False
