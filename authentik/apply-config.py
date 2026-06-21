import os
import time

from authentik.core.models import Application, User
from authentik.flows.models import Flow
from authentik.outposts.models import Outpost
from authentik.policies.expression.models import ExpressionPolicy
from authentik.policies.models import PolicyBinding
from authentik.providers.proxy.models import ProxyProvider
from authentik.sources.oauth.models import OAuthSource
from authentik.stages.identification.models import IdentificationStage
from authentik.stages.user_write.models import UserWriteStage


BASE_URL = os.environ.get("AUTHENTIK_BASE_URL", "https://login.180dc-escp.org").rstrip("/")
BASE_DOMAIN = os.environ.get("BASE_DOMAIN", "180dc-escp.org").strip().lower()
ALLOWED_DOMAIN = os.environ.get("AUTHENTIK_ALLOWED_EMAIL_DOMAIN", "180dc.org").lstrip("@").lower()
PLATFORM_ADMIN_EMAIL = os.environ.get("PLATFORM_ADMIN_EMAIL", "escp@180dc.org").strip().lower()
GOOGLE_CLIENT_ID = os.environ["GOOGLE_OAUTH_CLIENT_ID"]
GOOGLE_CLIENT_SECRET = os.environ["GOOGLE_OAUTH_CLIENT_SECRET"]
INCLUDE_VEXA = os.environ.get("AUTHENTIK_INCLUDE_VEXA", "true").lower() not in {"0", "false", "no"}


_required_flows = [
    "default-source-authentication",
    "default-source-enrollment",
    "default-provider-authorization-implicit-consent",
    "default-provider-invalidation-flow",
]

_required_stages = [
    ("IdentificationStage", "default-authentication-identification"),
    ("UserWriteStage", "default-source-enrollment-write"),
]

for flow_slug in _required_flows:
    tries = 0
    while Flow.objects.filter(slug=flow_slug).count() == 0:
        tries += 1
        if tries > 60:
            print(f"timeout waiting for flow {flow_slug!r}")
            break
        print(f"waiting for flow {flow_slug!r}… ({tries}/60)")
        time.sleep(2)

for model_cls, stage_name in _required_stages:
    model = globals()[model_cls]
    tries = 0
    while model.objects.filter(name=stage_name).count() == 0:
        tries += 1
        if tries > 60:
            print(f"timeout waiting for stage {stage_name!r}")
            break
        print(f"waiting for stage {stage_name!r}… ({tries}/60)")
        time.sleep(2)


def flow(slug):
    return Flow.objects.get(slug=slug)


def bind_single_policy(app, policy):
    PolicyBinding.objects.filter(target=app).exclude(policy=policy).delete()
    PolicyBinding.objects.update_or_create(
        target=app,
        policy=policy,
        defaults={
            "enabled": True,
            "negate": False,
            "order": 0,
            "timeout": 30,
        },
    )


google, _ = OAuthSource.objects.update_or_create(
    slug="google",
    defaults={
        "name": "Google",
        "provider_type": "google",
        "consumer_key": GOOGLE_CLIENT_ID,
        "consumer_secret": GOOGLE_CLIENT_SECRET,
        "additional_scopes": "openid email profile",
        "authentication_flow": flow("default-source-authentication"),
        "enrollment_flow": flow("default-source-enrollment"),
    },
)

ident = IdentificationStage.objects.get(name="default-authentication-identification")
ident.password_stage = None
ident.recovery_flow = None
ident.save()
ident.sources.set([google])

write_stage = UserWriteStage.objects.get(name="default-source-enrollment-write")
write_stage.user_type = "internal"
write_stage.save()

policy_expression = f'''email = getattr(request.user, "email", "") or ""
email = email.lower()
return bool(
    email == "{PLATFORM_ADMIN_EMAIL}"
    or email.endswith("@{ALLOWED_DOMAIN}")
)'''

policy, _ = ExpressionPolicy.objects.update_or_create(
    name="Allow 180DC ESCP Google users",
    defaults={"expression": policy_expression},
)

authorization_flow = flow("default-provider-authorization-implicit-consent")
invalidation_flow = flow("default-provider-invalidation-flow")

apps = [
    ("n8n", "n8n", f"https://n8n.{BASE_DOMAIN}"),
    ("Odoo", "odoo", f"https://odoo.{BASE_DOMAIN}"),
]
obsolete_app_slugs = {"bimi", "n8n-hooks", "odoo-retired", "vexa-api-admin"}
obsolete_provider_names = {"BIMI", "n8n hooks", "Odoo retired", "Vexa API Admin"}
if INCLUDE_VEXA:
    apps.insert(1, ("Vexa", "vexa", f"https://vexa.{BASE_DOMAIN}"))
else:
    obsolete_app_slugs.add("vexa")
    obsolete_provider_names.add("Vexa")

providers = []
for name, slug, external_host in apps:
    provider, _ = ProxyProvider.objects.update_or_create(
        name=name,
        defaults={
            "authorization_flow": authorization_flow,
            "invalidation_flow": invalidation_flow,
            "mode": "forward_single",
            "external_host": external_host,
            "internal_host": "",
            "cookie_domain": "",
            "basic_auth_enabled": False,
            "intercept_header_auth": True,
        },
    )
    providers.append(provider)

    app, _ = Application.objects.update_or_create(
        slug=slug,
        defaults={
            "name": name,
            "provider": provider,
            "policy_engine_mode": "any",
        },
    )
    bind_single_policy(app, policy)

outpost = Outpost.objects.filter(name="authentik Embedded Outpost").first()
if outpost:
    outpost.providers.set(providers)
    config = outpost.config
    config.authentik_host = BASE_URL
    config.authentik_host_browser = BASE_URL
    outpost.config = config
    outpost.save()

Application.objects.filter(slug__in=obsolete_app_slugs).delete()
ProxyProvider.objects.filter(name__in=obsolete_provider_names).delete()

for user in User.objects.filter(email__iendswith=f"@{ALLOWED_DOMAIN}"):
    if user.type != "internal" or not user.is_active:
        user.type = "internal"
        user.is_active = True
        user.save()

platform_admins = User.objects.filter(email__iexact=PLATFORM_ADMIN_EMAIL)
for user in platform_admins:
    changed = False
    for field, value in {
        "type": "internal",
        "is_active": True,
        "is_superuser": True,
        "is_staff": True,
    }.items():
        if hasattr(user, field) and getattr(user, field) != value:
            setattr(user, field, value)
            changed = True
    if changed:
        user.save()

if platform_admins.exists():
    for username in ("akadmin", "admin"):
        for user in User.objects.filter(username=username).exclude(email__iexact=PLATFORM_ADMIN_EMAIL):
            changed = False
            for field in ("is_superuser", "is_staff"):
                if hasattr(user, field) and getattr(user, field):
                    setattr(user, field, False)
                    changed = True
            if changed:
                user.save()

print("authentik config applied")
print(f"allowed domain: @{ALLOWED_DOMAIN}")
print(f"platform admin: {PLATFORM_ADMIN_EMAIL}")
print("google-only source: google")
print("managed apps:", ", ".join(name for name, _, _ in apps))
