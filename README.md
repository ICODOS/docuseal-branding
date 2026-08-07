# ICODOS DocuSeal Branding

Branding overlay for our self-hosted [DocuSeal](https://github.com/docusealco/docuseal) instance at sign.icodos.com. Instead of forking and rebuilding the whole application, we mount modified view templates and the ICODOS logo over the official Docker image.

## What is changed

| File | Purpose |
|---|---|
| `branding/submit_form__docuseal_logo.html.erb` | Header on the document signing page — ICODOS logo instead of the DocuSeal logo |
| `branding/start_form__docuseal_logo.html.erb` | Header on start / completed / declined / expired pages |
| `branding/mailer_attribution.html.erb` | Empties the "Sent using DocuSeal" footer in all outgoing emails (see license note below) |
| `branding/head_tags.html.erb` | Browser tab title: "ICODOS – Document Signing" instead of "DocuSeal \| Open Source Document Signing" |
| `branding/icodos-logo.png` | ICODOS logo (black, transparent background) served at `/icodos-logo.png` |
| `branding/shared__logo.html.erb` | Overrides the shared logo partial used across the app (top-left header, landing hero, upload spinner, etc.) — replaces the DocuSeal SVG with the ICODOS logo |
| `branding/shared__title.html.erb` | Drops the literal "DocuSeal" text next to the header logo (the ICODOS logo image already contains the wordmark) |
| `branding/shared__navbar.html.erb` | Hides the entire top navbar for unauthenticated visitors — the landing and sign-in pages render as clean hero-style pages, signed-in staff still see the full navbar |
| `branding/pages_landing.html.erb` | Replaces the DocuSeal marketing landing at `/` with a plain ICODOS "Sign in with Microsoft" page |
| `branding/devise_sessions_new.html.erb` | Rewrites `/sign_in` — Microsoft SSO is the primary CTA, password form stays as fallback for break-glass |
| `sso/entra_auth_controller.rb` | OIDC controller for Microsoft Entra SSO — `/auth/entra` and `/auth/entra/callback` |
| `sso/zz_sso_entra.rb` | Initializer that registers the SSO routes and enforces password-login blocking |
| `docker-compose.yml` | Stock compose file plus the overlay mounts, SSO env vars, and a pinned image version |

Everything else — application code, database, TLS, email templates — is the unmodified official image `docuseal/docuseal` (pinned, currently `3.1.6`). Email wording, policy links, and the completion message are configured in the app's own Personalization settings, not in this repo.

## License compliance (AGPL-3.0)

DocuSeal is AGPL-3.0 with [additional terms](https://github.com/docusealco/docuseal/blob/master/LICENSE_ADDITIONAL_TERMS) requiring that DocuSeal attribution is retained in **interactive user interfaces**. Accordingly:

- Both modified page templates keep a visible "Powered by DocuSeal" line on the signing and status pages.
- The email footer attribution is removed by `mailer_attribution.html.erb`; emails are not an interactive user interface, so we read the additional terms as not covering them. If DocuSeal clarifies otherwise, this override is a one-line revert.
- This repository is public, which satisfies the AGPL source-availability requirement for our modifications.

## Microsoft Entra SSO overlay

Staff sign in via Microsoft Entra ID (Azure AD). The community DocuSeal image doesn't ship SSO — we add a small OIDC layer over the top with no changes to the base image and no new gems.

### How it works

- `GET /auth/entra` starts an OpenID Connect authorization-code flow with PKCE.
- `GET /auth/entra/callback` verifies the returned `id_token` (RS256 signature against Entra's JWKS, `iss`, `aud`, `exp`, `nbf`, `nonce`, and the `state` CSRF value — all checks are mandatory, none can be disabled) and matches the `preferred_username` / `email` claim, case-insensitively, against an existing DocuSeal user.
- **Auto-provisioning on first sign-in.** If no DocuSeal user matches, one is created automatically: role `admin`, name filled from Entra's `given_name` / `family_name` / `name` claims, random password the user never sees. The Entra Enterprise Application "Assignment required = Yes" setting is the effective ACL — only users assigned to the app in Entra can reach the callback and get provisioned. **Verify that setting is on** at Azure Portal → Enterprise applications → ICODOS DocuSeal → Properties.
- Archived DocuSeal users are not silently unarchived; they're refused with a message and require admin action.
- Users can set their own password later via the standard "Forgot password?" flow (only reachable when `SSO_ENFORCE=false` or `SSO_BREAK_GLASS=true`).
- Public signing routes (`/d/`, `/s/`, `/p/`) are untouched — external counterparties never see any of this.

### Environment variables (in `/opt/docuseal/.env`, not in this repo)

| Key | Purpose |
|---|---|
| `ENTRA_TENANT_ID` | Microsoft tenant GUID |
| `ENTRA_CLIENT_ID` | App registration (client) ID |
| `ENTRA_CLIENT_SECRET` | App registration client secret — sensitive; do not commit or log |
| `SSO_ENFORCE` | `true` blocks all password sign-in and password-reset routes. Default `false`. |
| `SSO_BREAK_GLASS` | `true` re-enables password login even when `SSO_ENFORCE=true`. Default `false`. |

Redirect URI to register in the Azure portal: `https://sign.icodos.com/auth/entra/callback`

### Break-glass procedure

If Entra has an outage, if the client secret expires, or if the config is wrong and staff can't sign in:

```bash
ssh root@sign.icodos.com
cd /opt/docuseal
# Edit .env — set SSO_BREAK_GLASS=true (add the line if missing)
docker compose up -d
```

Within ~5 seconds password login is available again. Fix Entra, then flip `SSO_BREAK_GLASS` back to `false` and `docker compose up -d` once more.

A misconfigured SSO (any of `ENTRA_TENANT_ID` / `ENTRA_CLIENT_ID` / `ENTRA_CLIENT_SECRET` missing) is treated as an implicit break-glass — password login stays enabled and a warning is logged at boot. This is deliberate: a bad config must never lock admins out of their own instance.

### AGPL note

The SSO layer is our own code, distributed under the same public repository. DocuSeal attribution in the DocuSeal UI is unchanged.

## Deploying / updating on the server

```bash
cd /opt/docuseal
git clone https://github.com/ICODOS/docuseal-branding.git tmp-branding \
  && cp -r tmp-branding/branding . \
  && cp tmp-branding/docker-compose.yml . \
  && rm -rf tmp-branding
docker compose up -d --force-recreate app
```

(`.env` with `HOST`, `POSTGRES_PASSWORD`, and the SSO variables from the section above already lives in `/opt/docuseal` and is not part of this repo.)

## MCP server

The instance's built-in MCP server (Settings → MCP) is **enabled**, with a named access token used by our Claude/Cowork workspace (endpoint `https://sign.icodos.com/mcp`, static Bearer auth). Tokens can be revoked and re-issued on that settings page at any time. No code changes are involved — noting it here because it is part of the instance's active configuration.

## Updating DocuSeal itself

The image is version-pinned, so updates are deliberate:

1. Check the [DocuSeal releases](https://github.com/docusealco/docuseal/releases) for changes to the four overridden templates: `app/views/submit_form/_docuseal_logo.html.erb`, `app/views/start_form/_docuseal_logo.html.erb`, `app/views/shared/_mailer_attribution.html.erb`, `app/views/layouts/_head_tags.html.erb`. If they changed upstream, update our copies accordingly.
2. Bump the version in `docker-compose.yml`, commit, deploy as above.
3. Open sign.icodos.com and check: ICODOS header renders, a test email has no DocuSeal footer, tab title reads "ICODOS – Document Signing".
4. After a version bump, also confirm the MCP endpoint still responds (it is a recent DocuSeal feature).

Note: the server's weekly cron (`docker compose pull`) is a no-op for the pinned app image; version bumps are manual by design. A monthly automated check compares the pinned version against the latest DocuSeal release.
