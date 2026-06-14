import os

from authentik.core.models import Application, User
from authentik.flows.models import Flow
from authentik.outposts.models import Outpost
from authentik.policies.expression.models import ExpressionPolicy
from authentik.providers.proxy.models import ProxyProvider
from authentik.sources.oauth.models import OAuthSource
from authentik.stages.identification.models import IdentificationStage
from authentik.stages.user_write.models import UserWriteStage


BASE_URL = os.environ.get("AUTHENTIK_BASE_URL", "https://login.180dc-escp.org").rstrip("/")
ALLOWED_DOMAIN = os.environ.get("AUTHENTIK_ALLOWED_EMAIL_DOMAIN", "180dc.org").lstrip("@").lower()
GOOGLE_CLIENT_ID = os.environ["GOOGLE_OAUTH_CLIENT_ID"]
GOOGLE_CLIENT_SECRET = os.environ["GOOGLE_OAUTH_CLIENT_SECRET"]


def flow(slug):
    return Flow.objects.get(slug=slug)


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
username = getattr(request.user, "username", "") or ""
return bool(
    getattr(request.user, "is_superuser", False)
    or email.lower().endswith("@{ALLOWED_DOMAIN}")
    or username == "akadmin"
)'''

policy, _ = ExpressionPolicy.objects.update_or_create(
    name="Allow 180DC ESCP Google users",
    defaults={"expression": policy_expression},
)

authorization_flow = flow("default-provider-authorization-implicit-consent")
invalidation_flow = flow("default-provider-invalidation-flow")

apps = [
    ("n8n", "n8n", "https://n8n.180dc-escp.org"),
    ("n8n hooks", "n8n-hooks", "https://hooks.180dc-escp.org"),
    ("BIMI", "bimi", "https://bimi.180dc-escp.org"),
    ("Odoo retired", "odoo-retired", "https://odoo.180dc-escp.org"),
]

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
    app.policies.set([policy])

outpost = Outpost.objects.filter(name="authentik Embedded Outpost").first()
if outpost:
    outpost.providers.set(providers)
    config = outpost.config
    config.authentik_host = BASE_URL
    config.authentik_host_browser = BASE_URL
    outpost.config = config
    outpost.save()

for user in User.objects.filter(email__iendswith=f"@{ALLOWED_DOMAIN}"):
    if user.type != "internal" or not user.is_active:
        user.type = "internal"
        user.is_active = True
        user.save()

print("authentik config applied")
print(f"allowed domain: @{ALLOWED_DOMAIN}")
print("google-only source: google")
print("managed apps:", ", ".join(name for name, _, _ in apps))
