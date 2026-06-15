const crypto = require('crypto');

const N8N_DI_PATH = '/usr/local/lib/node_modules/n8n/node_modules/@n8n/di';
const N8N_JWT_SERVICE_PATH = '/usr/local/lib/node_modules/n8n/dist/services/jwt.service.js';

const allowedDomain = (process.env.AUTHENTIK_ALLOWED_EMAIL_DOMAIN || '180dc.org').replace(/^@/, '').toLowerCase();
const platformAdminEmail = (process.env.PLATFORM_ADMIN_EMAIL || 'escp@180dc.org').toLowerCase();
const ssoSharedSecret = process.env.SSO_SHARED_SECRET || '';

function header(req, name) {
  return req.headers[name.toLowerCase()];
}

function isAllowedEmail(email) {
  return email === platformAdminEmail || email.endsWith(`@${allowedDomain}`);
}

function hasValidSsoSecret(req) {
  return Boolean(ssoSharedSecret) && header(req, 'x-authentik-sso-secret') === ssoSharedSecret;
}

function splitName(name, email) {
  const clean = (name || '').trim();
  if (!clean) return { firstName: email.split('@')[0], lastName: '' };
  const parts = clean.split(/\s+/);
  return {
    firstName: parts[0] || clean,
    lastName: parts.slice(1).join(' '),
  };
}

function createUserHash(user) {
  const payload = [user.email, user.password || ''];
  if (user.mfaEnabled && user.mfaSecret) {
    payload.push(user.mfaSecret.substring(0, 3));
  }
  return crypto.createHash('sha256').update(payload.join(':')).digest('base64').substring(0, 10);
}

function createAuthToken(user, jwtService) {
  return jwtService.sign(
    {
      id: user.id,
      hash: createUserHash(user),
      usedMfa: false,
    },
    { expiresIn: '7d' },
  );
}

function roleForEmail(email) {
  return email === platformAdminEmail ? 'global:owner' : 'global:member';
}

async function createN8nUser(User, email, name, roleSlug) {
  const { firstName, lastName } = splitName(name, email);
  const result = await User.createUserWithProject({
    email,
    firstName,
    lastName,
    password: crypto.randomBytes(32).toString('hex'),
    role: { slug: roleSlug },
  });
  return result.user;
}

async function reconcileN8nUser(User, user, email, name) {
  const { firstName, lastName } = splitName(name, email);
  const roleSlug = roleForEmail(email);
  const changed =
    user.firstName !== firstName ||
    user.lastName !== lastName ||
    user.roleSlug !== roleSlug ||
    user.disabled;

  if (changed) {
    await User.query(
      'UPDATE "user" SET "firstName" = $1, "lastName" = $2, "roleSlug" = $3, "disabled" = false, "updatedAt" = CURRENT_TIMESTAMP WHERE "id" = $4',
      [firstName, lastName, roleSlug, user.id],
    );
    user = await User.findOne({
      where: { email },
      relations: ['role'],
    });
  }

  return user;
}

module.exports = {
  n8n: {
    ready: [
      async function (server) {
        const { Container } = require(N8N_DI_PATH);
        const { JwtService } = require(N8N_JWT_SERVICE_PATH);
        const jwtService = Container.get(JwtService);
        const { User } = this.dbCollections;
        const { app } = server;

        app.get('/auth/authentik/login', async (req, res) => {
          try {
            if (!hasValidSsoSecret(req)) {
              return res.status(403).send('SSO bridge secret is missing or invalid.');
            }

            const email = String(header(req, 'x-authentik-email') || '').trim().toLowerCase();
            const name = String(header(req, 'x-authentik-name') || '').trim();

            if (!email || !isAllowedEmail(email)) {
              return res.status(403).send('Authentik identity is missing or not allowed.');
            }

            let user = await User.findOne({
              where: { email },
              relations: ['role'],
            });

            if (!user) {
              const userCount = await User.count();

              if (userCount === 0 && email !== platformAdminEmail) {
                await createN8nUser(User, platformAdminEmail, '180DC ESCP', 'global:owner');
              }

              user = await createN8nUser(
                User,
                email,
                name,
                roleForEmail(email),
              );
            } else {
              user = await reconcileN8nUser(User, user, email, name);
            }

            const authToken = createAuthToken(user, jwtService);
            res.cookie('n8n-auth', authToken, {
              httpOnly: true,
              secure: process.env.N8N_PROTOCOL === 'https',
              sameSite: 'lax',
              maxAge: 7 * 24 * 60 * 60 * 1000,
            });
            res.redirect('/');
          } catch (error) {
            console.error('[Authentik SSO] Login failed:', error);
            res.status(500).send('SSO login failed.');
          }
        });

        console.log('[Authentik SSO] Route registered: GET /auth/authentik/login');
      },
    ],
  },
};
