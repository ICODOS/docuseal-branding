# ICODOS DocuSeal Branding

Branding overlay for our self-hosted [DocuSeal](https://github.com/docusealco/docuseal) instance at sign.icodos.com. Instead of forking and rebuilding the whole application, we mount modified view templates and the ICODOS logo over the official Docker image, and add two layers of our own: Microsoft Entra SSO for staff sign-in, and an OAuth 2.1 authorization server so Claude's admin-managed connectors can reach the MCP endpoint as a specific user. No image rebuild, no new gems, no database migrations.

**For everyday admin tasks — adding staff, rotating the Entra client secret, break-glass, running the MCP OAuth connector — see [`20260807-DocuSeal-Entra admin runbook-v1.md`](./20260807-DocuSeal-Entra%20admin%20runbook-v1.md).** This README documents *what's in the overlay* and *how to deploy it*; the runbook covers the recurring operations.

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
| `mcp/mcp_oauth.rb` | Phase D — OAuth 2.1 core: key handling, JWT issue/verify, client registry, `/mcp` auth hook |
| `mcp/oauth_api_controller.rb` | Phase D — discovery metadata, JWKS, dynamic client registration, token endpoint |
| `mcp/oauth_controller.rb` | Phase D — `/oauth/authorize` and the consent screen |
| `mcp/oauth_consent.html.erb` | Phase D — the consent page (self-contained, no app layout) |
| `mcp/zz_mcp_oauth.rb` | Phase D — initializer: routes, log filtering, boot diagnostics, the `/mcp` hook |
| `docker-compose.yml` | Stock compose file plus the overlay mounts, SSO + MCP OAuth env vars, and a pinned image version |

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
- **Account picker on every sign-in**: `/auth/entra` sends `prompt=select_account` to Microsoft by default, so users always see the Microsoft account picker (they never get silently signed in as whichever account the browser has a session for). One extra click per sign-in in exchange for account-choice reliability. Explicit override via `?prompt=login|consent|select_account` is honored; `prompt=none` is deliberately not accepted.

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
  && cp -r tmp-branding/sso . \
  && cp -r tmp-branding/mcp . \
  && cp tmp-branding/docker-compose.yml . \
  && rm -rf tmp-branding
docker compose up -d --force-recreate app
```

(`.env` with `HOST`, `POSTGRES_PASSWORD`, and the SSO / MCP OAuth variables from the sections above already lives in `/opt/docuseal` and is not part of this repo. `secrets/mcp_oauth_signing_key.pem` also lives only on the server — see "The signing key" below. It must exist before the first `docker compose up -d`.)

## MCP server

The instance's built-in MCP server (Settings → MCP) is **enabled**, with named access tokens used by our Claude/Cowork workspace (endpoint `https://sign.icodos.com/mcp`, static Bearer auth). Tokens can be revoked and re-issued on that settings page at any time.

Since Phase D the same endpoint *also* accepts OAuth 2.1 access tokens, so Claude's admin-managed custom connectors can authenticate each user individually instead of everyone sharing one token. See the next section.

## Phase D — MCP endpoint speaks OAuth 2.1

Claude's admin-managed custom connectors require OAuth 2.1 with RFC 9728 discovery. Phase D adds that, so a tool call arrives as *a specific DocuSeal user* rather than as whoever owns the shared static token. Nothing about the static token path changed.

### Design choice: we are the authorization server, Entra is still the identity provider

There were two options. Pointing Claude straight at Microsoft Entra as the authorization server turned out to need Azure changes we'd rather avoid: MCP clients must send `resource=https://sign.icodos.com/mcp` (RFC 8707), and Entra rejects that unless the MCP URL is registered as an Application ID URI on the app registration (it fails with `AADSTS9010010`). Without a custom exposed scope, the token Entra returns is audienced at Microsoft Graph rather than at us, and accepting such a token is exactly the token-passthrough pattern the MCP authorization spec forbids. Entra also has no RFC 7591 dynamic client registration endpoint.

So DocuSeal itself is the authorization server, and it delegates the human authentication step to the SSO overlay that already exists. **No Azure changes were needed** — same tenant, same client ID, same secret, same registered redirect URI.

What that means in practice: `/oauth/authorize` requires a DocuSeal session. If there isn't one it redirects to `/auth/entra?return_to=<the authorize URL>`, and `sso/entra_auth_controller.rb` does the `id_token` verification, the `preferred_username` / `email` lookup, the auto-provisioning and the archived-user refusal exactly as it does for a normal web sign-in. **MCP OAuth therefore cannot auto-provision anyone the web SSO flow would not have auto-provisioned — it is the same code path, not a copy of it.** `sso/entra_auth_controller.rb` is unmodified.

### New endpoints

| Endpoint | Purpose |
|---|---|
| `GET /.well-known/oauth-protected-resource` | RFC 9728 protected resource metadata. The first thing Claude fetches. Names `https://sign.icodos.com/mcp` as the resource and this host as its authorization server. |
| `GET /.well-known/oauth-protected-resource/mcp` | Same document at the path-inserted URL, which clients probe first. |
| `GET /.well-known/oauth-authorization-server` | RFC 8414 authorization server metadata. |
| `GET /oauth/jwks.json` | Public keys for verifying the tokens we issue. Public key material only. |
| `POST /oauth/register` | RFC 7591 dynamic client registration. Claude registers itself here; there is no way to pre-share a credential with it. |
| `GET /oauth/authorize` | Consent screen. Redirects into Entra SSO first if there's no DocuSeal session. |
| `POST /oauth/authorize` | The Allow/Deny decision. CSRF-protected. |
| `POST /oauth/token` | Authorization-code and refresh-token grants. |

We deliberately do **not** serve `/.well-known/openid-configuration`. Serving RFC 8414 alone satisfies the MCP spec, clients try `oauth-authorization-server` first, and an OpenID Connect document would have to advertise `id_token` support we don't have.

### Everything is stateless — no database changes

Authorization codes, refresh tokens and client registrations are signed or MAC'd artifacts, not rows. There is no migration and nothing is written to the DocuSeal database, so the blast radius on an instance holding executed contracts is nil.

- **`client_id`** is a compact MAC'd blob (`icd1.<base64url payload>.<base64url HMAC>`, ~160 chars) carrying the registered `redirect_uris`. The MAC key is derived from the RSA signing key, so rotating that key invalidates every registered client — they simply re-register on the next connect.
- **Authorization codes** are 60-second JWTs, single-use, bound to client, `redirect_uri`, PKCE challenge, resource and user.
- **Access tokens** are 1-hour JWTs with `aud = https://sign.icodos.com/mcp`.
- **Refresh tokens** are JWTs with `aud = <token endpoint>`, so they are useless at `/mcp`. They rotate on every use and carry a **14-day absolute lifetime that rotation does not extend**.

Three token types, separated by both a `token_use` claim and a distinct `aud`, so no artifact can be replayed at an endpoint it wasn't minted for.

**Known limitations, stated plainly.** Both were confirmed by the independent security review and are accepted consequences of the stateless design, not oversights.

*Refresh-token reuse detection is best-effort.* It uses `Rails.cache`, which here is a per-process `MemoryStore`. Tokens still **rotate** on every use (which OAuth 2.1 requires); what is best-effort is *detecting* that a superseded token was replayed. The burn list is lost on container restart and would not be shared if Puma were configured to run a worker cluster — the initializer logs a warning at boot if `WEB_CONCURRENCY` or `WEB_CONCURRENCY_AUTO` would cause that. Practically: an attacker holding a stolen refresh token that has since been rotated gets one more chance after each deploy, until the absolute 14-day cap expires it.

*There is no per-grant revocation.* The levers are, in order of proportionality:

1. **Archive the DocuSeal user.** Takes effect on the next request — every `/mcp` call and every token refresh re-checks `active_for_authentication?`. This is the right answer for offboarding. Note carefully that archiving *suspends* rather than destroys: because grants are stateless, un-archiving the user makes their existing refresh token valid again if it is still inside its 14-day window. If you archive in response to a suspected compromise rather than a departure, rotate the signing key as well.
2. **Turn MCP off for the account** (Settings → MCP). Also enforced per request.
3. **Rotate the signing key.** The only true revoke-everything. It invalidates every issued token *and* every registered client, so every connector must be reconnected.

If per-grant revocation later matters more than avoiding database rows, the smallest change that buys it is a `jti` denylist table — that is the one place the "no database rows" decision would need revisiting.

### How the two token types coexist, and their precedence

Both are presented the same way: `Authorization: Bearer <token>`.

1. **Static DocuSeal MCP token first.** One indexed lookup on `mcp_tokens.sha256`, byte-identical to pre-Phase-D behaviour. Trying it first is what guarantees existing personal tokens cannot regress no matter what the OAuth code does.
2. **Only on a miss, an OAuth 2.1 access token.** Full RS256 verification against our JWKS, with `iss`, `aud`, `exp`, `nbf`, `iat` all enforced, 60-second leeway, and a `kid` loader that re-reads key material on a miss.

A credential can only ever satisfy one of the two — DocuSeal tokens are 43 characters of base58 with no dots, OAuth tokens are JWS compact serializations.

The hook is a `prepend` onto `Mcp::McpBaseController`, applied in `to_prepare`. That controller is the single auth choke point for `/mcp`: `McpController` is an `ActionController::Metal` that only dispatches, and all six MCP controllers (protocol plus the five tools) inherit it. `config/routes.rb` is not patched.

### Scopes

One scope, `mcp`, meaning "use the MCP tools as this DocuSeal user, with that user's own DocuSeal permissions". A `mcp:read` / `mcp:write` split was considered and dropped: Claude requests whatever the metadata advertises, so both would always be granted, and the only practical effect would be a new way to produce a confusing 403.

`offline_access` is advertised in the *authorization server* metadata (Claude appends it to get a refresh token) but deliberately **not** in the protected resource metadata, per the MCP spec — refresh tokens are a client concern, not a requirement of this resource.

### Redirect URI allowlist

Dynamic client registration has to be open, because there's no way to pre-share a credential with Claude. What keeps that safe is that registered `redirect_uris` must be on an allowlisted host — default **`claude.ai, claude.com`** — so a stranger cannot register a client that redirects authorization codes to a host they control. HTTPS is required, with no userinfo, no fragment, and no `code` / `state` / `iss` / `error` query parameter that could collide with what we append on the way back.

**Loopback (`localhost`, `127.0.0.1`, `::1`) is deliberately excluded from the default.** A loopback `redirect_uri` means "hand the authorization code to a process on this user's own machine", and any local process can bind a port and claim to be a legitimate client. Combined with open registration, that is a one-click consent-phishing route to a grant with the user's full DocuSeal permissions — the security review called this out and it is why the default was narrowed. The hosted Claude surfaces (claude.ai web, Desktop, mobile, Cowork) all use the `claude.ai` callback, so nothing we need is lost. If a local MCP client genuinely needs it later, add the hosts to `MCP_OAUTH_ALLOWED_REDIRECT_HOSTS`; the RFC 8252 port-agnostic match is still implemented (path and query are still compared exactly, and userinfo and fragments are refused).

### Environment variables (in `/opt/docuseal/.env`, not in this repo)

Only the first one is required; everything else has a sensible default.

| Key | Purpose |
|---|---|
| `MCP_OAUTH_ENABLED` | `true` turns the whole OAuth layer on. Default `false`. This is the rollback switch. |
| `MCP_OAUTH_SIGNING_KEY_PATH` | Default `/app/config/icodos/mcp_oauth_signing_key.pem` |
| `MCP_OAUTH_PREVIOUS_SIGNING_KEY_PATH` | Optional. Published in JWKS during a key rotation. |
| `MCP_OAUTH_ISSUER` | Default derived from the app's configured host (`https://sign.icodos.com`) |
| `MCP_OAUTH_RESOURCE` | Default `<issuer>/mcp` |
| `MCP_OAUTH_ALLOWED_REDIRECT_HOSTS` | Comma separated. Default `claude.ai,claude.com` — loopback deliberately excluded, see above |
| `MCP_OAUTH_ACCESS_TOKEN_TTL` | Seconds. Default `3600`, clamped to a 24 h ceiling |
| `MCP_OAUTH_REFRESH_TOKEN_TTL` | Seconds. Default `1209600` (14 days, absolute), clamped to a 90 day ceiling |

### The signing key

An RSA private key, **never in this repo** (`secrets/` is gitignored). It lives on the server and is mounted read-only. Generate it *before* the first `docker compose up -d` — Docker creates a directory in place of a missing bind-mount source, which would silently leave the layer disabled:

```bash
cd /opt/docuseal
mkdir -p secrets && chmod 700 secrets
openssl genrsa -out secrets/mcp_oauth_signing_key.pem 3072
# The app process runs as uid 2000 inside the container, so root-owned 600 is not readable by it.
chown 2000:2000 secrets/mcp_oauth_signing_key.pem
chmod 400 secrets/mcp_oauth_signing_key.pem
```

Rotation and rollback are in the admin runbook, section 7.

### What is deliberately out of scope

- **Client ID Metadata Documents (CIMD).** Claude Code identifies itself with a CIMD rather than dynamic registration. Supporting it means fetching an attacker-suppliable HTTPS URL server-side, which is an SSRF surface we chose not to add. Claude.ai, Desktop, mobile and Cowork all use dynamic registration, which is what the admin-managed connector needs. Whether Claude Code also falls back to dynamic registration when CIMD isn't advertised is untested — worth trying rather than assuming.
- **Confidential clients.** Dynamic registration makes Claude a public client, so only `token_endpoint_auth_method: none` is supported. PKCE S256 is mandatory.
- **`client_credentials`.** Not supported, and Anthropic doesn't support it either — every connection requires user consent.

### Security review

This layer went through two independent adversarial reviews before being enabled — one on the token-validation and cryptographic paths, one on the OAuth protocol flow and web surface. Neither found a critical defect: no authentication bypass at `/mcp`, no token confusion, no algorithm confusion, no open redirect, no CSRF-forced grant, no key leakage. The changes they did produce are worth knowing about, because most of them are load-bearing:

| Finding | Change |
|---|---|
| A `kid` a client doesn't recognise triggers a key reload, and `/mcp` has no rate limit — so an unauthenticated flood of random `kid` values meant a disk read, a 3072-bit RSA parse and a log line per request | Reload is now debounced *and* gated on the key file's mtime actually changing. A `kid` flood against an unchanged key now does no work at all. |
| Loopback redirect URIs plus open registration plus an unverified client name is a one-click consent-phishing route | Loopback dropped from the default allowlist; the consent screen now says the client name is self-asserted and shows the full redirect URI rather than just the host; bidi and zero-width characters are stripped from client names |
| A `NullStore` cache would make `write(unless_exist:)` always succeed, silently disabling every single-use check | The layer probes the cache store at boot and **refuses to enable** if replay protection would not work |
| The jwt gem's `exp`/`nbf` checks return early when the claim is *absent*, so a token with no `exp` verifies and never expires | `required_claims` is now passed to `JWT.decode`, making an immortal token structurally impossible |
| The rate limiter read-then-wrote, so concurrent threads all advanced the counter by one | Uses atomic `Rails.cache.increment` |
| A rotated refresh token's burn entry could expire ~60 s before the token itself stopped verifying (the leeway window) | Burn TTL now covers `exp + leeway` |
| The consent token was not single-use, so **Deny** could be undone with the back button | Consent token is burned on submit, whichever way the user decides |
| `grant_types` were validated at registration, echoed back, then never enforced | Carried inside the `client_id` and enforced at the token endpoint |
| Registered `redirect_uris` could carry a `code`/`state`/`iss` query parameter, duplicating what we append | Those keys are refused at registration |
| Loopback matching ignored userinfo and fragments, and the presented URI was never re-validated | Presented URIs are re-validated; userinfo and fragments refused |
| Unbounded TTL env values could mint a multi-year token from a typo | Clamped to 24 h (access) and 90 days (refresh), with a warning |
| `DEMO=true` would let `ApplicationController` sign an anonymous visitor in as a random real user, who could then be granted a token | The demo filter is skipped on the OAuth controller |
| A grant minted during a Pretender impersonation session would outlive it | Refused while impersonating |
| The authorization endpoint response was cacheable and relied on a framework default for anti-framing | `no-store`, `X-Frame-Options: DENY` and `frame-ancestors 'none'` set explicitly |

Two mistakes surfaced only against the real Claude connector, after the reviews:

- **`form-action 'self'` blocked the authorization hand-back.** Added while addressing the anti-framing finding above. The consent form posts to `'self'`, but that POST answers with a 302 to the client's `redirect_uri`, and Chrome/WebKit enforce `form-action` across the redirect chain following a form submission. The browser silently dropped the navigation carrying the authorization code. Nothing was visible server-side — the log showed a successful grant and simply no token exchange ever followed. `form-action` now lists the redirect-host allowlist alongside `'self'`.
- **A duplicate consent submission reported success as failure.** Clicking Allow a second time while the first was still redirecting hit the single-use consent guard, which rendered "Authorization failed — nothing was granted" *after* the authorization had already completed. The guard now records the decision, so a repeat submission is answered truthfully ("Already authorized", HTTP 200) instead of as an error.

Both are worth knowing about because both were introduced by security hardening and neither was detectable from the server side alone.

One reviewer claim did **not** survive checking: that the IP-based rate limits were bypassable by spoofing `X-Forwarded-For`. Behind this deployment's Caddy they are not — Caddy appends the real peer address and `ActionDispatch` takes the rightmost non-private entry, so a spoofed prefix is ignored. Verified against the running stack. That would stop being true if Caddy were swapped for a proxy that overwrites the header instead of appending.

Both reviewers independently flagged the absence of per-grant revocation; see "Known limitations" above for why that stands and what it would take to change.

### AGPL note

Like the SSO layer, this is our own code distributed under the same public repository. DocuSeal attribution in the DocuSeal UI is unchanged.

## Updating DocuSeal itself

The image is version-pinned, so updates are deliberate:

1. Check the [DocuSeal releases](https://github.com/docusealco/docuseal/releases) for changes to any of the overridden files. The current overrides map to these upstream paths:
   - `app/views/submit_form/_docuseal_logo.html.erb`
   - `app/views/start_form/_docuseal_logo.html.erb`
   - `app/views/shared/_mailer_attribution.html.erb`
   - `app/views/layouts/_head_tags.html.erb`
   - `app/views/shared/_logo.html.erb`
   - `app/views/shared/_title.html.erb`
   - `app/views/shared/_navbar.html.erb`
   - `app/views/pages/landing.html.erb`
   - `app/views/devise/sessions/new.html.erb`
   - `config/routes.rb` (SSO and MCP OAuth routes are added via `Rails.application.routes.append`, but if upstream removes any Devise route we mount an override for, we need to reconsider)
   - Also check `app/controllers/application_controller.rb` and `config/initializers/devise.rb` — SSO relies on `authenticate_user!` behavior and Devise's `SessionsController` / `PasswordsController` subclass structure staying stable.
   - **`app/controllers/mcp/mcp_base_controller.rb` — check this one on every version bump.** The Phase D hook prepends onto it and overrides `user_from_api_key` and `authenticate_user!`. If upstream renames either method, or moves auth out of that class, OAuth tokens stop being accepted at `/mcp`. It fails closed (401), not open, and the initializer logs `could not install the /mcp authentication hook`. The static Bearer path keeps working regardless.
2. Bump the version in `docker-compose.yml`, commit, deploy as above.
3. Open sign.icodos.com and check:
   - ICODOS header renders on signed-in pages, no navbar on `/sign_in` or `/`.
   - `/auth/entra` still redirects to `login.microsoftonline.com`.
   - A test email has no DocuSeal footer.
   - Tab title reads "ICODOS – Document Signing".
4. After a version bump, also confirm the MCP endpoint still responds (it is a recent DocuSeal feature), and run the Phase D smoke check in the admin runbook, section 7.

Note: the server's weekly cron (`docker compose pull`) is a no-op for the pinned app image; version bumps are manual by design. A monthly automated check compares the pinned version against the latest DocuSeal release.
