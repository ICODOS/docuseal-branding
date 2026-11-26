# ICODOS DocuSeal Branding

Branding overlay for our self-hosted [DocuSeal](https://github.com/docusealco/docuseal) instance at sign.icodos.com. Instead of forking and rebuilding the whole application, we mount modified view templates and the ICODOS logo over the official Docker image, and add two layers of our own: Microsoft Entra SSO for staff sign-in, and an OAuth 2.1 authorization server so Claude's admin-managed connectors can reach the MCP endpoint as a specific user. No image rebuild, no new gems, no database migrations.

**For everyday admin tasks — adding staff, rotating the Entra client secret, break-glass, running the MCP OAuth connector — see [`20260807-DocuSeal-Entra admin runbook-v1.md`](./20260807-DocuSeal-Entra%20admin%20runbook-v1.md).** This README documents *what's in the overlay* and *how to deploy it*; the runbook covers the recurring operations.

**For a DocuSeal version bump, see [`20261101-DocuSeal-Version bump 3.3.4 runbook-v1.md`](./20261101-DocuSeal-Version%20bump%203.3.4%20runbook-v1.md).** It covers the 3.1.6 to 3.3.4 bump specifically, and the shape of it carries over to the next one. [`20261125-DocuSeal-Version bump 3.4.0 runbook-v1.md`](./20261125-DocuSeal-Version%20bump%203.4.0%20runbook-v1.md) records the 3.3.4 to 3.4.0 bump and what was tested before it.

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
| `contracts/*` | Phase E — SharePoint contract filing: the two ICODOS MCP tools, the `/icodos/hooks/filing` hook, the Graph client and its checks |
| `contracts/zz_icodos_timestamp.rb` | Timestamp guard: with a timestamp server set, every configured server is tried, a token is verified before it is embedded, and a document is never signed with a broken timestamp (see below) |
| `reveal/*` | SSO API key reveal: re-authenticate with Microsoft instead of typing a password nobody has |
| `reminders/*` | Signature reminders, which DocuSeal ships only in Pro: scheduler, sweep, mailer, settings page |
| `deploy.sh` | Refreshes **every** overlay directory on the server, dumps the database first, refuses to start if a bind-mount source is missing, and proves the running container sees the new files |
| `docker-compose.yml` | Stock compose file plus the overlay mounts, SSO + MCP OAuth env vars, and a pinned image version |

Everything else — application code, database, TLS, email templates — is the unmodified official image `docuseal/docuseal` (currently `3.4.0`, pinned by tag and by digest, as are `postgres` and `caddy`). Email wording, policy links, and the completion message are configured in the app's own Personalization settings, not in this repo.

## License compliance (AGPL-3.0)

DocuSeal is AGPL-3.0 with [additional terms](https://github.com/docusealco/docuseal/blob/master/LICENSE_ADDITIONAL_TERMS) requiring that DocuSeal attribution is retained in **interactive user interfaces**. Accordingly:

- Both modified page templates keep a visible "Powered by DocuSeal" line on the signing and status pages.
- The email footer attribution is removed by `mailer_attribution.html.erb`; emails are not an interactive user interface, so we read the additional terms as not covering them. If DocuSeal clarifies otherwise, this override is a one-line revert.
- This repository is public, which satisfies the AGPL source-availability requirement for our modifications.

## Microsoft Entra SSO overlay

Staff sign in via Microsoft Entra ID (Azure AD). The community DocuSeal image doesn't ship SSO — we add a small OIDC layer over the top with no changes to the base image and no new gems.

### How it works

- `GET /auth/entra` starts an OpenID Connect authorization-code flow with PKCE.
- `GET /auth/entra/callback` verifies the returned `id_token`: the RS256 signature against Entra's JWKS, `iss`, `aud`, `nonce` and the `state` CSRF value must match; `exp` and `iat` must be present and are checked, `nbf` is checked whenever present (Entra sends it), each with 60 seconds of leeway. No configuration switches any of these off. It then requires `tid` to be this tenant, an `oid`, and a member account: a guest's token carries an `idp` claim naming its home identity provider, and is refused.
- **The Microsoft account is bound to the DocuSeal user, not its email.** At the first sign-in the pair `tid`/`oid`, which never changes for an account, is stored with the user (in `user_configs`, key `icodos_entra_identity`; no migration). From then on that pair signs in to that record, whatever either email says. Until 26 November 2026 the join was the email alone, and both sides of it are editable: any admin can change any user's email in the settings, and Entra addresses are renamed and, after someone leaves, reissued. A reissued address inherited the record and its API key, a renamed account got a second admin record, and an admin who swapped two addresses in the settings could sign in as a colleague and reveal the colleague's API key. The reveal now compares the bound `oid` as well.
- **First sign-in and auto-provisioning.** An account that is not bound yet needs an address in `SSO_ALLOWED_DOMAINS`. It takes the DocuSeal user with that address if that user is not bound to another account, otherwise a new user is created: role `admin`, name from Entra's `given_name` / `family_name` / `name`, random password the user never sees. A user already bound to a different Microsoft account is refused, with a log line, because that is a renamed or reissued address. The Entra setting "Assignment required = Yes" decides which members of the tenant may sign in at all; the checks here add that the account is a member of this tenant and not a guest, that its address is on an allowed domain at the first sign-in, and that a user bound to one Microsoft account is never handed to another.
- Archived DocuSeal users are not silently unarchived; they're refused with a message and require admin action.
- Users can set their own password later via the standard "Forgot password?" flow (only reachable while password login is allowed: `SSO_ENFORCE=false`, `SSO_BREAK_GLASS=true`, or an incomplete Entra configuration; see "Break-glass procedure").
- Public signing routes (`/d/`, `/s/`, `/p/`) are untouched — external counterparties never see any of this.
- **Account picker on every sign-in**: `/auth/entra` sends `prompt=select_account` to Microsoft by default, so users always see the Microsoft account picker (they never get silently signed in as whichever account the browser has a session for). One extra click per sign-in in exchange for account-choice reliability. Explicit override via `?prompt=login|consent|select_account` is honored; `prompt=none` is deliberately not accepted.

### Environment variables (in `/opt/docuseal/.env`, not in this repo)

| Key | Purpose |
|---|---|
| `ENTRA_TENANT_ID` | Microsoft tenant GUID |
| `ENTRA_CLIENT_ID` | App registration (client) ID |
| `ENTRA_CLIENT_SECRET` | App registration client secret — sensitive; do not commit or log |
| `SSO_ENFORCE` | `true` switches off password authentication on every route and makes the sign-in, password reset and invitation routes refuse; see "What enforcement actually blocks". Default `false`. |
| `SSO_BREAK_GLASS` | `true` re-enables password login even when `SSO_ENFORCE=true`. Default `false`. |
| `SSO_ALLOWED_DOMAINS` | Email domains a Microsoft account must have to be bound or provisioned at its first sign-in. Default in `docker-compose.yml`: `icodos.com,icodos.de`. Set but empty: nobody new; accounts already bound still sign in. |
| `SESSION_REMEMBER_DAYS` | How long a browser stays signed in without a new Microsoft sign-in. Set to `30` in `docker-compose.yml`; upstream's default is 730. |

Redirect URI to register in the Azure portal: `https://sign.icodos.com/auth/entra/callback`

### What enforcement actually blocks

With `SSO_ENFORCE=true`, and unless break-glass is on, three things hold. The boot log states the result in one line:

```
[sso] configured=true enforce=true break_glass=false password_login=blocked password_strategy=off
```

1. **No password is ever compared.** Devise asks the `User` model, per request, whether a strategy may authenticate from request parameters. The overlay answers no. There is no session, no remember cookie and no failed-attempt count from a posted password, on any route.
2. **The sign-in, password and invitation routes refuse.** `/sign_in`, `/password` and `/invitation` redirect to Microsoft on GET and answer 403 otherwise. The one exception: after a refused Microsoft sign-in, GET `/sign_in` shows the reason with the Microsoft button and no password form, instead of sending the browser straight back to Microsoft.
3. **Sessions last 30 days**, not upstream's 730 (`SESSION_REMEMBER_DAYS`).

Until 25 November 2026 only the second point existed, and only for the first two routes, and it did not do what it said. The refusal was a `before_action` that ran last. Before it, `ApplicationController` had already called `current_user`, which on `POST /sign_in` makes Warden check the posted password; on a match the session and a two-year remember cookie were set, and the 403 that followed carried them. A wrong password on the same path counted towards Devise's lockout, so 15 anonymous requests locked a known address out of Microsoft sign-in for 23 hours. `/invitation` is served by a sibling of `PasswordsController` and was never patched: it accepted a reset token, set a password and signed the user in. All three were reproduced on a scratch copy before the fix and shown closed after it; the bump runbook has the table.

`SSO_ENFORCE` and `SSO_BREAK_GLASS` are read case-insensitively and trimmed. They used to be compared with `== 'true'`, so `True` or a stray space switched enforcement off without a word.

### Break-glass procedure

If Entra has an outage, if the client secret expires, or if the config is wrong and staff can't sign in:

```bash
ssh root@sign.icodos.com
cd /opt/docuseal
# Edit .env — set SSO_BREAK_GLASS=true (add the line if missing)
docker compose up -d
```

Within ~5 seconds password login is available again; the boot line then reads `password_login=ALLOWED password_strategy=ON`. This was tested together with the enforcement fix, because a block that break-glass cannot lift would be worse than the gap it closed. Fix Entra, then flip `SSO_BREAK_GLASS` back to `false` and `docker compose up -d` once more.

A misconfigured SSO (any of `ENTRA_TENANT_ID` / `ENTRA_CLIENT_ID` / `ENTRA_CLIENT_SECRET` missing) is treated as an implicit break-glass — password login stays enabled and a warning is logged at boot. This is deliberate: a bad config must never lock admins out of their own instance.

### AGPL note

The SSO layer is our own code, distributed under the same public repository. DocuSeal attribution in the DocuSeal UI is unchanged.

## Deploying / updating on the server

A deploy names the exact commit it installs. Take the id of the commit you have read, in full:

```bash
git ls-remote https://github.com/ICODOS/docuseal-branding.git main
```

```bash
cd /opt/docuseal && SHA=<the 40-character id> && curl -fsSL "https://raw.githubusercontent.com/ICODOS/docuseal-branding/$SHA/deploy.sh" | DEPLOY_SHA="$SHA" bash
```

**Why a commit id and not `main`.** The script runs as root, and what it installs is mounted into the app. A branch is a pointer that anyone with push access can move between the moment a change was read and the moment it is deployed; a commit id names one tree and cannot be moved. That holds for the URL as well: fetched from a branch it is whatever the branch holds at that second, fetched from a commit id it is the file as reviewed. `deploy.sh` refuses to run without `DEPLOY_SHA`, refuses anything that is not a full id, checks after fetching that it got that commit, and writes the id to `/opt/docuseal/.deployed_sha` once the new code is proven live. `cat /opt/docuseal/.deployed_sha` answers "what is running".

`deploy.sh` is the whole procedure. It refuses to run outside a directory holding `.env` and `secrets/`, dumps the database to `/var/backups/docuseal` (readable by root only), refreshes **all six** overlay directories, checks every bind-mount source, brings the stack up and waits for the health gate. The settings it reads are listed in its header; `SKIP_DB_BACKUP=1` and `BOOT_TIMEOUT` are the ones a person would use.

**A failed boot rolls itself back.** Before it replaces anything, the script keeps a copy of the overlay and compose file in place. After the restart it waits, up to three minutes, until `/up` answers inside the app container and through the proxy, and the boot log since the container started holds the line of each feature this instance runs (`[sso] configured=true`, `[mcp-oauth] enabled.`, `[icodos-contracts] enabled.`, `[icodos-reminders] enabled,`). A restart of the container or an error marker in the log (`NOT attached`, `NameError`, `Zeitwerk`, `FATAL`, `password_strategy=ON`) ends the wait at once. If the gate fails, or a bind-mount source is missing, or the checksum step finds a stale file, the copy is put back, the app is recreated on it and checked again, and the run ends with exit 1 and `.deployed_sha` unchanged. Database migrations are not reversed by that; the dump is what reverses them.

Tested before it was used, on a scratch copy of the stack: a commit that raises at boot was back on the previous commit 21 seconds after the deploy started; a commit that silently switched the reminders off was rolled back when the gate timed out on the missing line; a missing secret put the previous files back without restarting anything.

Two things it does that a hand-run deploy tends to get wrong, both found on 20 November 2026:

- **It recreates the app container even when only overlay files changed.** `docker compose up -d` recreates a container only when its compose configuration changes, and the contents of bind-mounted files are not part of that configuration, so a code-only deploy would leave the app running the previous files.
- **It ends by comparing checksums.** Every overlay file on the host is compared with the file the running container has mounted at the same place, and the script fails, naming the stale files, if any differ. So `done` means the new code is live, not just copied.

Piping it into bash is safe. Everything runs inside `main()`, so bash has read the whole file before any command runs. Before that, the `docker compose exec` of the database dump read the rest of the script from the pipe, and the deploy stopped silently after the dump with exit status 0.

Two things it does that the old hand-typed command did not, and both have teeth:

- **It copies every overlay directory, not just `branding/`.** `docker-compose.yml` mounts files from `branding/`, `sso/`, `mcp/`, `contracts/`, `reveal/` and `reminders/`. Copying a subset leaves the rest at whatever version the server happened to have, which is how a view override silently goes stale.
- **It checks that every bind-mount source exists and is a file before starting anything.** Docker creates a *directory* in place of a missing bind-mount source. Rails then sees an empty directory where a controller or a key should be, and the dependent feature disables itself with no error in any log. The check turns that into a refusal to deploy.

It also dumps the database first, because DocuSeal runs migrations on boot and putting the old image tag back does not reverse them.

If you deploy by hand instead, do all of the above by hand.

(`.env` with `HOST`, `POSTGRES_PASSWORD`, and the SSO / MCP OAuth variables from the sections above already lives in `/opt/docuseal` and is not part of this repo. `secrets/mcp_oauth_signing_key.pem` also lives only on the server — see "The signing key" below. It must exist before the first `docker compose up -d`.)

## MCP server

The instance's built-in MCP server (Settings → MCP) is **enabled**, with named access tokens used by our Claude/Cowork workspace (endpoint `https://sign.icodos.com/mcp`, static Bearer auth). Tokens can be revoked and re-issued on that settings page at any time.

Since Phase D the same endpoint *also* accepts OAuth 2.1 access tokens, so Claude's admin-managed custom connectors can authenticate each user individually instead of everyone sharing one token. See the next section.

## Phase D — MCP endpoint speaks OAuth 2.1

Claude's admin-managed custom connectors require OAuth 2.1 with RFC 9728 discovery. Phase D adds that, so a tool call arrives as *a specific DocuSeal user* rather than as whoever owns the shared static token. Nothing about the static token path changed.

### Design choice: we are the authorization server, Entra is still the identity provider

There were two options. Pointing Claude straight at Microsoft Entra as the authorization server turned out to need Azure changes we'd rather avoid: MCP clients must send `resource=https://sign.icodos.com/mcp` (RFC 8707), and Entra rejects that unless the MCP URL is registered as an Application ID URI on the app registration (it fails with `AADSTS9010010`). Without a custom exposed scope, the token Entra returns is audienced at Microsoft Graph rather than at us, and accepting such a token is exactly the token-passthrough pattern the MCP authorization spec forbids. Entra also has no RFC 7591 dynamic client registration endpoint.

So DocuSeal itself is the authorization server, and it delegates the human authentication step to the SSO overlay that already exists. **No Azure changes were needed** — same tenant, same client ID, same secret, same registered redirect URI.

What that means in practice: `/oauth/authorize` requires a DocuSeal session. If there isn't one it redirects to `/auth/entra?return_to=<the authorize URL>`, and `sso/entra_auth_controller.rb` does the `id_token` verification, the tenant, member and domain checks, the `tid`/`oid` binding, the auto-provisioning and the archived-user refusal exactly as it does for a normal web sign-in. **MCP OAuth therefore cannot auto-provision anyone the web SSO flow would not have auto-provisioned: it is the same code path, not a copy of it.** Phase D did not change that controller; later work did (the API key reveal, the identity binding).

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

Four signed token types: authorization codes, access tokens, refresh tokens, and the consent token that carries a validated authorization request across the consent screen. Each carries its own `token_use` claim, and verification requires both the expected `token_use` and the expected `aud`: access tokens are audienced at the MCP resource, consent tokens at the authorization endpoint, codes and refresh tokens at the token endpoint, where `token_use` alone tells them apart. So no artifact can be replayed at an endpoint it wasn't minted for.

**Known limitations, stated plainly.** Both were confirmed by the independent security review and are accepted consequences of the stateless design, not oversights.

*Refresh-token reuse detection rests on Redis.* Tokens **rotate** on every use (which OAuth 2.1 requires), and the record of used refresh tokens, authorization codes and consent tokens, as well as the rate-limit counters, is kept in the Redis that DocuSeal already runs, with `SET NX EX` and `INCR`. Until November 2026 it was `Rails.cache`, a per-process `MemoryStore`: lost at every restart, so after each deploy a stolen refresh token that had since been rotated was valid again until its 14-day cap. Redis is shared by every Puma process and writes its snapshot to the data volume, so the record survives a restart and a deploy; what was written in the minutes before an unclean stop can still be lost. While Redis cannot be asked, the per-process cache stands in and `[mcp-oauth] Redis not reachable for the single-use records` is logged once a minute: the guarantee falls back to what it was, never to none. The boot line ends `single_use=redis`.

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

Dynamic client registration has to be open, because there's no way to pre-share a credential with Claude. What keeps that safe is that a registered https `redirect_uri` must be one of a short list of exact addresses, by default **`https://claude.ai/api/mcp/auth_callback`** (the address the claude.ai connector registers, seen in the log on 26 November 2026) and its `claude.com` counterpart, so a stranger cannot register a client that redirects authorization codes anywhere else, not even to another path on those hosts. Until November 2026 only the host was checked. `MCP_OAUTH_ALLOWED_REDIRECT_URIS` replaces the list; narrowing it also invalidates clients registered with an address no longer on it, because every client_id is re-checked when it is used. HTTPS is required, with no userinfo, no fragment, and no `code` / `state` / `iss` / `error` query parameter that could collide with what we append on the way back.

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
| `MCP_OAUTH_ALLOWED_REDIRECT_HOSTS` | Comma separated. Default `claude.ai,claude.com`; loopback deliberately excluded, see above |
| `MCP_OAUTH_ALLOWED_REDIRECT_URIS` | Comma separated exact https callback addresses. Default `https://claude.ai/api/mcp/auth_callback,https://claude.com/api/mcp/auth_callback` |
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
| A `kid` a client doesn't recognise triggers a key reload, and `/mcp` has no rate limit — so an unauthenticated flood of random `kid` values meant a disk read, a 3072-bit RSA parse and a log line per request | Reload is now debounced *and* gated on the key file's mtime actually changing. A `kid` flood against an unchanged key no longer reads the key file or parses the key; each request is rejected like any other invalid token, with one warning line in the log. |
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

## Phase E — contract tools: SharePoint in, signed PDF out

Two MCP tools and one internal webhook that move ICODOS employment-contract preparation off the browser entirely. An agent produces the document, files it in SharePoint as before, then makes two tool calls. DocuSeal reads the file server-side, places the signature fields, sends employer-first, and files the signed PDF back when both parties have signed.

Same overlay pattern as Phase D: bind-mounted files, no image rebuild, no new gems, no database migrations.

### The tools

| Tool | What it does |
|---|---|
| `icodos_create_contract_template` | Reads a PDF from the SharePoint contracts folder, creates a template with fields placed, roles assigned, folder set, and the filing destination recorded |
| `icodos_send_contract` | Sends for signature with `submitters_order: 'preserved'`. Without `confirm` it returns a **preview** (signers in order, each signer's email text, filing folder, expiry, email code) and a `preview_token`, and sends nothing. It sends only with `confirm: true` plus the token of a preview of exactly the same arguments |

Both inherit `Mcp::McpBaseController`, so authentication, the archived-user check and the Phase D OAuth hook apply exactly as they do to the upstream tools. Archiving a DocuSeal user still revokes access.

### Which tools an agent is offered

| Tool | Offered |
|---|---|
| `search_templates`, `load_template`, `search_documents` | yes, read only, upstream |
| `icodos_create_contract_template`, `icodos_send_contract` | yes |
| `send_documents`, `create_template` | **no**, refused since 25 November 2026 |
| any tool a later upstream version adds | **no**, until it is reviewed and named in `ICODOS_MCP_UPSTREAM_TOOLS` |

The policy is an allowlist. `send_documents` and `create_template` sat next to the guarded ICODOS tools with none of the guards: any template to any recipient with random signing order, and a server-side fetch of any `https` address. The guards therefore protected only an agent that chose the guarded tool, and an instruction smuggled into a document gives an agent no reason to. The first version hid those two by name, which would have offered every tool a later upstream version adds the moment the image was bumped. A refused tool is absent from `tools/list`; a client that still calls it from an older list gets the tool error `tool_refused` naming what to use instead.

`ICODOS_MCP_UPSTREAM_TOOLS` controls this: unset or empty offers the three read-only tools above, a comma-separated list offers exactly those upstream tools, `none` offers no upstream tool, `all` offers everything upstream ships, reviewed or not. The ICODOS tools are not part of the list. It is independent of `ICODOS_CONTRACTS_ENABLED` on purpose: a lapsed Graph certificate switches the contract tools off, and that must not be what puts the unguarded tools back. The boot line `[icodos-contracts] tool policy: upstream_offered=… upstream_refused=…` shows the result; an upstream tool nobody here has reviewed is named in a warning. The former `ICODOS_MCP_HIDDEN_TOOLS` is no longer read, and an error line says so if it is still set.

### Errors the tools return

Every failure of the two ICODOS tools is a tool error (`isError: true`) whose text is one JSON object:

```json
{"error": "preview_expired", "message": "...", "retryable": false,
 "hint": "Make a new preview and show it to the requester.", "done": "nothing", "request_id": "..."}
```

`retryable` is true only when the same call may simply be repeated later. `done` says what had already happened: `nothing`, or a sentence naming what now exists and must not be created or sent again. `request_id` matches the log and the audit record. The codes:

| Code | Meaning | Retryable |
|---|---|---|
| `invalid_arguments` | an argument is missing, malformed or contradicts the template | no |
| `not_found` | no such template in this account | no |
| `disabled` | the contract tools are off on this instance | no |
| `path_refused` | a path outside the permitted folders, or malformed | no |
| `invalid_pdf` | the source file is empty, too large, not a PDF or unreadable | no |
| `template_archived`, `template_not_original` | the template cannot be sent from here | no |
| `fixed_term_refused` | fixed-term employment documents are signed on paper for now | no |
| `preview_required`, `preview_invalid`, `preview_mismatch`, `preview_expired` | the confirmation is not bound to a preview of these arguments; make a new preview | no |
| `in_progress` | an identical call is running right now; repeat the same call shortly | yes |
| `store_unreachable` | Redis cannot be asked; nothing was sent | yes |
| `sharepoint_not_found`, `sharepoint_error` | SharePoint refused the request | no |
| `sharepoint_unavailable`, `sharepoint_unreachable` | SharePoint is busy or the network failed | yes |
| `sharepoint_config` | the server's SharePoint access is broken; an administrator must act | no |
| `submission_failed`, `save_failed` | DocuSeal did not build or save the record | no |
| `internal_error` | anything nobody anticipated; logged with its class and place | no |
| `tool_refused` | the tool is not offered on this instance | no |

### Repeated calls

Both tools can be called again safely after a timeout. The send tool answers a confirmed call whose `preview_token` was already used with the send it made then (`"replayed": true`), not with a second one; a send that fails before the invitations go out removes its submission and releases the token, so the identical call can be repeated. The create tool checks every field, including its page against the PDF's page count, before anything is saved, so a refusal leaves nothing behind; an identical call by the same user within 24 hours returns the template the first one made (`"reused": true`), and while one call is creating, an identical one is told `in_progress`.

### The audit record

Every `tools/call` to `/mcp`, whichever tool it names and however it ends, leaves one JSON line in `/data/docuseal/icodos_audit/mcp-YYYY-MM.jsonl` on the data volume (mode 0600). The nightly backup takes the volume whole, and a deploy does not touch it; the container log, the only trace before November 2026, starts afresh at every deploy.

```json
{"at":"2026-11-26T10:47:26.318Z","request_id":"…","user_id":1,"auth":"oauth","client":"29f6a17ea0df",
 "client_name":"Claude","tool":"icodos_send_contract","args_sha256":"43f4…","outcome":"ok",
 "sent":true,"submission_id":120,"template_id":129,"ms":874}
```

- No argument in clear: they carry employees' names and private addresses. `args_sha256` is SHA-256 over the arguments as canonical JSON (keys sorted at every level, as `[key, value]` pairs, no whitespace), so a known call can be matched to its line.
- `client` is the first 12 hex digits of SHA-256 over the OAuth `client_id`, with the client's registered name beside it; `static:<id>` for a static MCP token. The `[mcp-oauth]` log lines show the first 12 characters of the `client_id` itself, which are the same for every client.
- `outcome` is `ok`, `tool_error`, `protocol_error`, `unauthorized`, `forbidden` or `http_<status>`. `sent` tells a preview of the send tool from a send.
- It fails open: a line that cannot be written is logged as `[icodos-audit] could not write …` and the call stands. It is written after the response exists, so it could not stop the action anyway. The boot line `[icodos-contracts] tool policy: … audit=<dir> audit_identity=attached` says where it writes and whether the caller is being noted.

```bash
docker compose exec -T app tail -n 20 /data/docuseal/icodos_audit/mcp-$(date -u +%Y-%m).jsonl
```

### Why not the upstream tools

`create_template` accepts only a name and an optional URL, hardcodes the folder to the account default and the fields to `[]`, and its URL branch needs the contract exposed at a fetchable address. `send_documents` has no signing-order parameter and falls back to `'random'` when the template preference is unset — which is the case for every template created before Phase E. Employer-first is a hard requirement for employment documents, so it is hardcoded here.

### Reading file content is not a Graph operation

The one genuinely surprising thing in this layer, and the reason two Entra permissions are needed rather than one.

Graph serves metadata, listings, uploads and deletes with a Graph-audience token. It does **not** serve file content: `GET .../content` returns `302` to `_layouts/15/download.aspx`, and `@microsoft.graph.downloadUrl` points at the same place. In this tenant that endpoint returns `401` with an HTML sign-in page for every credential — no token, a Graph token, and a valid SharePoint token alike. The embedded `tempauth` parameter is not honoured.

What works is SharePoint's own REST API with a SharePoint-audience token:

```
GET https://<tenant>.sharepoint.com/sites/<site>/_api/web/GetFileByServerRelativeUrl('<server-relative>')/$value
Authorization: Bearer <token for https://<tenant>.sharepoint.com>
```

So the app registration holds `Sites.Selected` on **both** Microsoft Graph and Office 365 SharePoint Online (different resources, different role GUIDs), and the client caches a token per audience. A single per-site grant covers both.

### The path allowlist is the security boundary

`Sites.Selected` scopes to a site, not a folder, and the ICODOS contracts library lives on the org-wide site. The only thing confining these tools to the employee-contracts tree is `IcodosGraph#normalize_path!`.

That matters because the paths arrive as MCP tool arguments — model-generated text derived from Notion pages, email and documents the company does not fully control. The allowlist normalises first and then requires a **segment-wise** prefix match, so `.../01 Employee contracts evil/x.pdf` is rejected rather than accepted by a string comparison. Colons are rejected outright because Graph addresses drive items as `/root:/{path}:/content` and a colon would silently retarget the request.

### More than one permitted tree

`ICODOS_CONTRACTS_PATH_PREFIX` accepts several trees, **separated by `|`**. Employment contracts and EU time-report sign-offs live in different parts of the library, and the alternative — widening the prefix to a common ancestor — would have exposed customer contracts, banking documents, insurance policies and lawyer correspondence to these tools.

The separator is `|` and not `,` because six folders in this library have commas in their names (`06 Design, Branding, Marketing, Conferences`, `09 Internet, mobile, celular`, and others). A comma-separated list would have silently split a legitimate prefix into fragments the first time one of them was used. `|` is already in `FORBIDDEN_PATH_CHARS`, so it can never appear in a valid path and is unambiguous by construction.

Each tree is matched segment-wise independently, so adding one does not weaken the others.

### Waiting out OneDrive

Documents are often written through the OneDrive-synced library on a Mac, so there is a real gap between "saved" and "visible to SharePoint". `download_when_synced` retries **only** a 404, for 30 seconds, then fails with a message naming OneDrive rather than the path. A 403 fails immediately — that is access, not timing, and retrying would delay the real diagnosis.

The create tool also checks the file actually starts with `%PDF-`, so a `.docx` passed by mistake, or a half-written file, fails at creation rather than at signature time.

Neither the OneDrive wait nor the `%PDF-` check has an offline test. `contracts/selftest.rb` covers the path allowlist, the order of the site and drive lookups, the redirect rules and how a file is resolved before it is read, with no network, credentials or Rails; `contracts/send_selftest.rb` covers the send tool's preview token, fixed-term pattern, email code default and the plain-text note to the first signer:

```bash
ruby contracts/selftest.rb
ruby contracts/send_selftest.rb
```

### Other deliberate constraints

- **Sending is a separate tool from preparing**, so a contract can never be sent as a side effect of building one.
- **A confirmation is bound to its preview.** The preview returns a `preview_token`: an HMAC over the user and a digest of everything the preview showed (the template and its content, signers in order, each signer's email subject and text, filing folder, expiry, email code). `confirm: true` sends only with that token and the same arguments, within 15 minutes, once; the nonce is recorded in Redis before anything is sent and on the submission afterwards. A changed address, message or folder, a template edited in between, or another user's token is refused and nothing is sent; a second use sends nothing again and answers with the send already made (`"replayed": true`). Before 26 November 2026 the first call could carry `confirm: true` with arguments nobody had seen; before 25 November `confirm` was a Rails boolean cast, under which `"False"`, `"no"` and `2` all sent.
- **The preview shows the email text per signer.** With a `message` in the call that text; otherwise the template's and then the account's invitation text, exactly as `SubmitterMailer` would choose it. `{...}` placeholders are filled in per signer when sent.
- **The first signer's invitation names who signs next and where the signed copy is filed.** The ICODOS signer is the only person who sees the document before the other party is contacted, so their invitation ends with the next signers (role, name, address), the filing folder and the expiry, and asks them not to sign if any of it is wrong. Caller-supplied values are inserted as plain text: no links, emphasis, HTML or `{variables}`.
- **`expire_at` takes effect.** It is passed where upstream reads it (the submission attributes); until 26 November 2026 it was echoed by the preview and dropped, and the account's invitation text "Could you sign by {submission.expire_at}?" went out with a blank date. A date alone means the end of that day in the account's time zone; less than an hour ahead is refused.
- **Email code before signing.** Upstream's `require_email_2fa`, per signer. By default (`ICODOS_CONTRACTS_EMAIL_CODE=external`) signers outside the first-signer domains get it, which are the employees' private addresses; staff mailboxes already sit behind Microsoft sign-in. `all` and `off` are the alternatives; a call can say `require_email_code: true` (everyone) or `false` (nobody), and the preview shows the value per signer.
- **Fixed-term employment documents are refused**, for now: they are signed on paper. The caller must state `fixed_term` for every send, and the template name, source file name, document names and role names are checked for working student, intern, thesis, fixed-term and extension wording (permanent, "unbefristet", is not a match). `ICODOS_CONTRACTS_FIXED_TERM_GUARD=off` lifts it on the server.
- **Every role must own a signature field.** Upstream turns a role without fields into a viewer and invites the next role at once, so a template whose fields all belonged to the employee passed the first-signer check on the employer's address and then went straight to the employee. The create tool refuses such a field list before reading the file; the send tool refuses a template whose first role does not sign.
- **The first signer must be at a configured domain** (`ICODOS_CONTRACTS_FIRST_SIGNER_DOMAINS`, default `icodos.com,icodos.de`). The first signer countersigns for ICODOS; without this, an instruction smuggled into a document could send a fabricated contract with both roles pointed at addresses an attacker controls.
- **Filing never overwrites.** A name collision files alongside with a numeric suffix and logs a warning. The upload asks Graph to fail rather than replace (`@microsoft.graph.conflictBehavior=fail`), so not even a race between the existence check and the write replaces an executed contract; the graph check's write probe proves the 409 against the tenant.
- **Filing is idempotent.** The chosen name is recorded on the submission before the upload, the filed path after it, and one filing per submission runs at a time (a Redis lock). A retry after a lost response finds its own file under the recorded name, compares it byte for byte and records it, instead of filing a second copy. DocuSeal retries any non-2xx up to ten times; after that, the host's hourly reconciliation (`Filing.reconcile`, `docuseal-filing.timer` in the operations repository) files whatever the hook should have filed and has not.
- **What the hook files.** A submission with a filing folder (sent by `icodos_send_contract`), and a submission of a template made by `icodos_create_contract_template` sent any other way, into the template's folder: the Make scenario skips those templates by their marker, so until November 2026 such a submission was filed by nobody. Not a copy of such a template: a copy inherits the original's folder and file name, which belong to the original's employee. The create tool records the template's own id so that a copy can be recognised, and the send tool refuses copies and templates it did not make. Everything else is left to the Make scenario.
- **Drafts are limited to 3 MB.** The signed copy is filed with Graph's simple upload, which takes 4 MiB; a larger draft used to be accepted (up to 32 MiB) and its signed copy could then never be filed.

### The filing webhook

`POST /icodos/hooks/filing`, registered as a DocuSeal webhook pointing at `http://app:3000/icodos/hooks/filing` — inside the compose network; the proxy refuses the path from outside. `SendWebhookRequest` only enforces HTTPS and blocks localhost when `Docuseal.multitenant?`, which is false here, so an internal address is accepted.

It is still authenticated: DocuSeal HMAC-signs every webhook and the signature is verified with `WebhookUrls::Signatures.verify`, against the registration whose address is exactly the hook's (`ICODOS_FILING_HOOK_URL` if the address ever differs), and the submission must belong to that registration's account. Until November 2026 any registration whose address merely ended in the hook path was accepted, and any admin can register one. Note that `WebhookUrl#url` is encrypted non-deterministically, so the registration cannot be found with a SQL `LIKE` — the lookup filters in Ruby after decryption.

To file one submission by hand, or to see why it was not filed (the log says), from `/opt/docuseal`:

```bash
docker compose exec -T -w /app app rails runner \
  'Icodos::FilingHookController::Filing.call(Submission.find(<id>))'
```

Register it once:

```ruby
WebhookUrl.create!(account: <account>, url: 'http://app:3000/icodos/hooks/filing',
                   events: ['submission.completed'])
```

Deliveries are recorded as `WebhookEvent`s and visible in the DocuSeal UI, so failures surface where someone already looks.

### Environment variables (in `/opt/docuseal/.env`, not in this repo)

| Variable | Notes |
|---|---|
| `ICODOS_CONTRACTS_ENABLED` | `false` unless explicitly `true`. Off means the tools are neither advertised nor routable |
| `ICODOS_GRAPH_TENANT_ID` | Entra tenant |
| `ICODOS_GRAPH_CLIENT_ID` | The "ICODOS DocuSeal Filing" app registration — deliberately **not** the SSO app |
| `ICODOS_GRAPH_KEY_PATH` | Private key. Both halves are needed: the key signs the client assertion, the certificate supplies the `x5t` thumbprint |
| `ICODOS_GRAPH_CERT_PATH` | Certificate |
| `ICODOS_GRAPH_SITE_HOSTNAME` | e.g. `<tenant>.sharepoint.com` |
| `ICODOS_GRAPH_SITE_PATH` | e.g. `/sites/<site>` |
| `ICODOS_CONTRACTS_PATH_PREFIX` | The only subtree these tools may touch |
| `ICODOS_CONTRACTS_FIRST_SIGNER_DOMAINS` | Optional; defaults to `icodos.com,icodos.de`. Also the company domains for the email code default |
| `ICODOS_CONTRACTS_EMAIL_CODE` | Optional; `external` (default), `all` or `off`: who enters an emailed code before the document opens |
| `ICODOS_CONTRACTS_FIXED_TERM_GUARD` | Optional; `on` (default) refuses fixed-term employment documents, `off` lifts it |
| `ICODOS_AUDIT_DIR` | Optional; where the audit record of tool calls is written, default `/data/docuseal/icodos_audit` |
| `ICODOS_FILING_HOOK_URL` | Optional; the filing hook's registered address, default `http://app:3000/icodos/hooks/filing` |
| `ICODOS_MCP_UPSTREAM_TOOLS` | Optional; the upstream tools agents may use. Unset: `search_templates`, `load_template`, `search_documents`. `none` or `all` |

### The credential

A separate app registration from SSO, holding a **certificate rather than a client secret**. Adding an application permission to the SSO app would have turned its secret from one factor in a user sign-in flow into a standalone key to every employment contract, and the secret-rotation procedure copies `.env` to backup files on the host. The certificate stays in one `0400` file owned by uid 2000, the same shape as the Phase D signing key.

```bash
mkdir -p secrets && chmod 700 secrets
openssl req -x509 -newkey rsa:3072 -sha256 -days 730 -nodes \
  -keyout secrets/graph_filing_key.pem \
  -out    secrets/graph_filing_cert.pem \
  -subj "/CN=ICODOS DocuSeal Filing"
chown 2000:2000 secrets/graph_filing_key.pem secrets/graph_filing_cert.pem
chmod 400 secrets/graph_filing_key.pem
chmod 444 secrets/graph_filing_cert.pem
```

Upload the **certificate** (public half) to the app registration. Add its expiry to the quarterly checks — a lapsed certificate stops contract filing quietly, unlike a lapsed SSO secret which everyone notices at once.

### Smoke check

Run after any enable, key rotation, or DocuSeal version bump. `write: true` additionally round-trips a probe file and deletes it.

```bash
docker compose exec -T -w /app app rails runner \
  'require "icodos_graph_check"; IcodosGraphCheck.call(write: true)'
```

It verifies the configuration, both tokens, the SharePoint roles claim, site and drive resolution, the path allowlist, tool registration, the filing route and webhook, and the first-signer guard. `Sites.Selected` in particular shows a green tick in the Azure Portal while granting access to nothing, so the only honest test is reading a real file.

### What breaks on a version bump

Phase E depends on these internal APIs, none of which are a public contract:

`Mcp::McpBaseController` as superclass, with `mcp_params`, `render_tool_result`, `render_result`, `render_error`, `current_ability`, `check_authorization` and (prepended) `current_user` · `McpController#call`, `McpController::TOOLS`, `McpController::TOOL_CONTROLLERS`, `request.request_parameters` · `Mcp::ProtocolController#tools_list` and `mcp_body` · `McpToken` · `Templates::CreateAttachments` · `TemplateFolders.find_or_create_by_name` · `SearchEntries.enqueue_reindex` · `WebhookUrls.enqueue_events` · `Submissions.create_from_submitters` (its attribute keys, `is_viewer`, `require_email_2fa`, `expire_at`) · `Submissions.send_signature_requests` · `Templates.build_default_expire_at` · how `SubmitterMailer#invitation_email` chooses its text, with `AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY` · `Submissions::EnsureCombinedGenerated` · `WebhookUrls::Signatures` · `WebhookUrl#url` and `#hmac_secret` · the webhook payload's `data.id` · `Template#preferences` and `Submission#preferences` as free-form stores · `Templates::Clone` copying preferences. The timestamp guard depends on `Submissions::TimestampHandler#sign` and HexaPDF's `SignedDataCreator#create_unsigned_attrs`.

The prepends fail closed and log `[icodos-contracts] could not attach to the MCP controllers`; the boot line reports whether the dispatch hook attached. From an MCP client, unregistered tools are indistinguishable from tools that never existed, which is why the smoke check asserts registration explicitly.

### AGPL note

These files are part of the modified source published for AGPL-3.0 compliance. DocuSeal attribution in the interactive UI is untouched.

## Revealing the API key without a password

Upstream gates the API key behind `current_user.valid_password?`. SSO-provisioned users are created with `password: SecureRandom.hex(16)` — a value nobody ever sees — so that check can never succeed for them, and `SSO_ENFORCE` blocks the "Forgot password?" flow that would otherwise let them set one. On an SSO-only instance the key is unreachable for everyone but the break-glass admin.

This replaces the password proof with a fresh Microsoft re-authentication.

### What the password prompt was for

Worth stating, because a replacement that merely checks "is this request signed in" would look equivalent and be a straight downgrade.

The API key is a long-lived bearer credential with full account access. The prompt exists so that a live session is **not** sufficient to walk away with it — someone holding a stolen cookie, or sitting at an unlocked laptop, has to prove identity again. The requirement is *fresh proof of identity at the moment of reveal*.

### How the replacement holds that property

1. **Freshness is verified, not requested.** The round trip sends `prompt=login` and `max_age=0`, then checks the returned `auth_time` claim is within 120 seconds. `prompt` is a request to the IdP; only the claim is evidence. `max_age` is what obliges Entra to return `auth_time` at all.
2. **Identity is bound.** The re-authenticated Microsoft identity must match the DocuSeal user already signed in. Without this, anyone able to reach a signed-in session could authenticate as *themselves* and unlock the key belonging to whoever left the browser open. This is the check that matters most and the easiest to omit.
3. **The grant is single-use and short-lived** — 120 seconds, bound to the user id, consumed atomically on first read, with the jti carried in the session so it only works in the browser it was minted for.

### Why grants live in Redis, not `Rails.cache`

DocuSeal hardcodes `config.cache_store = :memory_store`, which is **per-process and lost on restart**. A grant minted in one web process would be invisible to another and the rate limiter would count per process, so the single-use guarantee would hold only while the app happens to run one worker — with nothing asserting that, and nothing later connecting `WEB_CONCURRENCY=2` to "reveals started failing intermittently".

Grants and rate limits therefore use Redis, which is already present and configured for Sidekiq. `SET .. NX .. EX` and `GETDEL` are atomic, so mint and consume are genuinely single-use across processes rather than nearly so. Nothing else about how DocuSeal caches is changed.

**Phase D followed in November 2026.** `mcp_oauth.rb` enforced single-use authorization codes and refresh tokens through `Rails.cache`, whose probe checks that `unless_exist` is *honoured* but not that the store is *shared*. It moved to Redis as its own reviewed change (finding A7), tested on the scratch stack with a refresh token presented again after an app restart.

Rate limited to 5 attempts per user per minute. A successful reveal is logged; upstream logs nothing.

### It fails closed, everywhere

Not enabled, SSO unconfigured, a cache that ignores `unless_exist`, a missing or stale `auth_time`, an identity mismatch, an expired intent, a broken rate-limiter — every one of these serves the upstream password dialog or refuses, and none of them reveals anything. `ICODOS_SSO_REVEAL_ENABLED` unset restores stock behaviour exactly.

The re-authentication branch returns **before** `reset_session` in the SSO callback: this is a re-auth, not a sign-in, and it must leave the existing session intact.

| Variable | |
|---|---|
| `ICODOS_SSO_REVEAL_ENABLED` | `false` unless explicitly `true` |

### Offline test

```bash
ruby reveal/selftest.rb
```

Covers `auth_time` boundaries (including exactly-at and one-second-stale), intent binding, grant single-use, consumption on mismatch, rate limiting, and refusal of a cache that cannot enforce single use. No Rails, no network, no tenant.

### Detecting override drift on a version bump

The overridden view is a copy of upstream's with three branches added. Upstream's original at tag 3.1.6 is:

```
sha256  4331da87d2a4c871b2dc76420113a7344cf1bd439c4eab234d26442b4d828c08   app/views/reveal_access_token/show.html.erb
```

On a version bump, diff the new upstream file against that baseline. If it changed, the override needs the same change — otherwise the modal renders an old layout with no error anywhere.

```bash
curl -sS https://raw.githubusercontent.com/docusealco/docuseal/refs/tags/<TAG>/app/views/reveal_access_token/show.html.erb | shasum -a 256
```

### Smoke check

```bash
docker compose exec -T -w /app app rails runner \
  'require "icodos_reveal_check"; IcodosRevealCheck.call'
```

Asserts the feature is enabled, SSO is configured, the guard store is Redis and actually atomic, a grant is single-use across replay and cross-user attempts, the prepend is attached, the view override is the ICODOS one, and the re-auth URL still carries `prompt=login` and `max_age=0`.

### Zeitwerk trap, learned the hard way

`lib/foo.rb` must define the constant `Foo`. A second file `lib/icodos_reveal_patch.rb` defining `IcodosReveal::RevealAccessTokenPatch` **stops the application booting** — Zeitwerk raises, the container crash-loops, and with `SSO_ENFORCE=true` nobody can sign in. It does not degrade gracefully. The patch module therefore lives inside `lib/icodos_reveal.rb` alongside its parent namespace.

If you add files to `lib/`, name them for the constant they define, and watch the first boot.

### AGPL note

Part of the modified source published for AGPL-3.0 compliance. DocuSeal attribution in the interactive UI is untouched.

## Automatic reminders

DocuSeal ships automatic reminders in Pro only. The community build has the reminder email template, its per-template override and a `send_reminder_email` audit event type — but nothing that schedules or sends, and a settings form writing `submitter_reminders`, a key nothing reads. On this instance that key held `{two_days, four_days, six_days}` and had sent exactly zero reminders while thirteen submissions sat unsigned. Anyone reading the settings page would reasonably have believed reminders were on.

This adds the scheduler, the sender, and a settings page that says what is actually happening.

### Design follows researched behaviour, not invention

| Product | Default | Borrowed here |
|---|---|---|
| DocuSign | every 3 days until signed; 120-day expiry | max one reminder per person per day |
| Dropbox Sign | 3 and 7 days after sending; also 3 and 7 days *before* an expiry | never within an hour of any previous reminder, manual included; deadline-anchored reminders |
| Adobe Acrobat Sign | daily / weekdaily / every other / weekly, "until signed" | **"only the current recipients are notified"** — order awareness |
| RightSignature | — | 30-reminder ceiling per signer |

The escalating pattern practitioners recommend — day 3, day 7, then daily — is not offered natively by any of them, so it is the default here.

### The policy model

One list of hour offsets plus an optional steady interval expresses every cadence above:

```
DocuSign default      schedule [72],      then_every_hours 72
Dropbox Sign default  schedule [72, 168], no steady phase
Adobe weekly-until    schedule [168],     then_every_hours 168
Escalating (default)  schedule [72, 168], then_every_hours 24
```

Stored per submission in `submissions.preferences`, with an account default in an `AccountConfig`. No migration.

**The account default is anchored at the time it is saved.** The stored value carries `activated_at` and the defaults before it, and a submission without its own policy follows the default that was in force when it was created. Until November 2026 the bare policy was stored and read afresh by every sweep, so one click on the settings page moved every pending signer to the new schedule, and "off" deleted the record; the page said "for new documents" all along. The page now saves with a button rather than on click.

**Order awareness matters most.** With `submitters_order = 'preserved'`, only the signer whose turn it is gets reminded. Chasing an employee before ICODOS has countersigned is worse than not reminding at all.

**Caps no policy can override:** one per person per day, never within an hour of a previous send, 30 per signer, 200 per sweep. A wrong policy must send fewer emails than intended, never more. The daily cap is also kept in Redis, claimed before each email and independent of the record in the database: a reminder whose email or whose record fails is not tried again for 20 hours, where it used to be tried at every sweep. Hand resends count towards the spacing and the 30. These caps hold for every reminder the sweep sends; `IcodosReminderSweep.send_one!`, the console method for sending one reminder at once, ignores the schedule and every cap except the 20 hours in Redis.

**Escalation ends the reminders.** The reminder that reaches `escalate_after` unanswered goes out with a note to the sender saying that no further reminders follow, and none do. Until November 2026 they continued up to the stop count. "Once a week, until they sign" therefore no longer escalates.

**Viewers are not reminded, and resends count.** A role that owns no field is a viewer upstream and is never asked to sign; in signing order a viewer that came first used to be reminded instead of the signer whose turn it was. An invitation sent again by hand ("Resend", or the API; upstream records each as `send_email`) counts as a reminder for spacing and totals, so the schedule does not follow it minutes later.

### The sweep

Every 15 minutes from `docuseal-reminders.timer` on the host (systemd, kept in the private operations repository and installed from there), through `rails runner`. Not a self-rescheduling Sidekiq job: that needs no gem but dies silently if Redis is flushed, and a reminder engine that quietly stops is the exact failure this work exists to fix.

A Redis lock keeps two sweeps from running at once, and the cap of 20 hours per signer, claimed in Redis before each email, stops a second email to the same person even if two sweeps overlap. Each reminder is sent on its own: one address the mail relay rejects is counted as an error of that sweep, and the others are still reminded (it used to abort the sweep for everyone, every 15 minutes, with the heartbeat still green). A dead or failing timer is loud: the host's health job alerts when no sweep has finished successfully for 30 minutes or the last one reported errors. The heartbeat (`last_swept_at`, written at the end of every sweep, a failed one included) turns the settings page red and fails the smoke check when it is older than two hours; the smoke check's own dry run writes it as well.

### Two defects worth remembering

**Spring-forward DST.** Advancing a daily interval by 86,400 seconds moves 09:00 to 10:00 across the March transition, because that day is 23 hours long. Whole-day steps advance in calendar terms instead. The autumn case had been passing only by luck — it landed at 08:00, before the sending window, and the window shift happened to correct it. `reminders/selftest.rb` covers both directions.

**Per-submitter counters need their own preferences key.** Most submissions inherit the account default and carry no policy. Writing counters into the policy key leaves behind a hash containing only counters, which is then read *as* the policy and rejected for having no anchor — so reminders stop after exactly one per submission, for a reason nobody would guess.

### Tests

```bash
# Both run in the container. Unlike contracts/selftest.rb and reveal/selftest.rb,
# reminders/selftest.rb only defines a module when run with plain ruby: the
# scheduler is timezone arithmetic and needs real tzinfo data, not a laptop's.
# Neither sends anything, touches a tenant, or writes to the database.
docker compose exec -T -w /app app rails runner 'require "icodos_reminders_selftest"; IcodosRemindersSelftest.call'
docker compose exec -T -w /app app rails runner 'require "icodos_reminder_check"; IcodosReminderCheck.call'
```

### Environment variables (in `/opt/docuseal/.env`, not in this repo)

| Variable | Notes |
|---|---|
| `ICODOS_REMINDERS_ENABLED` | `false` unless explicitly `true` |
| `ICODOS_REMINDERS_DRY_RUN` | **Defaults to true.** Sending requires setting it to `false` explicitly, so a half-finished deployment cannot start emailing employees |

### AGPL note

Part of the modified source published for AGPL-3.0 compliance. DocuSeal attribution in the interactive UI is untouched.

## Timestamp guard

A timestamp server is set under Settings → E-Signature → Timestamp Server. DocuSeal then asks it for an RFC 3161 token over each signature and embeds the token in the signature, so a PDF viewer can show the signing time as proven by a third party instead of asserted by this server's clock. The server receives a SHA-256 digest of the signature value and nothing else. A fallback can follow after a comma: `http://timestamp.digicert.com,http://timestamp.sectigo.com`. Upstream's settings form tests the whole value as one address and refuses that, although the signing code reads it; save it from a Rails console instead, after testing each part.

`contracts/zz_icodos_timestamp.rb` replaces two things upstream does when the server fails, both reproduced on a scratch copy of the stack on 25 November 2026:

- **A failure was written into the document.** Upstream's handler rescues every error and returns a bare time value, which is then embedded where the token belongs. A timeout or a refused connection produced a signed PDF whose timestamp attribute cannot be decoded. HexaPDF's own verifier raised on it. That reads as a broken signature, which is worse than none, and nothing was logged as a failure.
- **The fallback covered only an HTTP error status.** After a network error on the first server the second was never asked.

The guard asks each configured server in turn, on any failure. A response is used only if it is a granted token over exactly this signature, carries the nonce that was sent, and is signed by a time-stamping certificate the system trust store accepts. If no server gives one, the signature is made without a timestamp, as before a server was configured, the error is logged as `[icodos-timestamp] FAILED`, and the time and reason go to `/data/docuseal/icodos_timestamp_failure.json` for whatever watches the host. The boot log says `[icodos-timestamp] guard attached`, or `NOT attached` if an upstream change moved either seam (`Submissions::TimestampHandler#sign`, HexaPDF's `SignedDataCreator#create_unsigned_attrs`), which `deploy.sh` treats as a failed boot. Without a timestamp server the guard does nothing.

## Updating DocuSeal itself

The image is version-pinned, so updates are deliberate:

1. Diff the overridden files between the pinned tag and the new one, rather than reading release notes. The notes do not mention view changes, and a stale view override renders an old layout with no error anywhere. From a clone of upstream:

   ```bash
   git diff <old-tag> <new-tag> -- $(sed -n 's|.*- \./[^:]*:/app/\([^:]*\):ro|\1|p' docker-compose.yml | tr '\n' ' ')
   ```

   **Also diff `app/views/**` for classes we use that upstream stopped using.** Tailwind scans `./app/views/**/*.erb` at *image build time*, before any overlay file exists, so our files are never scanned. A class upstream drops is purged from the compiled CSS and silently stops working in our overrides. 3.3.4 removed `min-w-[160px]`, which the navbar override depended on. Check any arbitrary-value or uncommon class before trusting it:

   ```bash
   docker compose exec app sh -c "grep -o 'the-class' /app/public/packs/css/application-*.css | head -1"
   ```

   The current overrides map to these upstream paths:
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
   - `app/views/reveal_access_token/show.html.erb`, `app/views/notifications_settings/_reminder_banner.html.erb` and `_reminder_form.html.erb` are overridden too and are missing from the list above for historical reasons; the `sed` command at the top of this step derives the full list from `docker-compose.yml` and will not miss them.
   - **Ruby patch targets.** `sessions_controller.rb` and `passwords_controller.rb` (SSO filter), `mcp_controller.rb` and `mcp/protocol_controller.rb` (contract tools), `reveal_access_token_controller.rb` (reveal), `submitter_mailer.rb` and `account_config.rb` (reminders). The overlay adds files and patches at boot; it overwrites no upstream Ruby file. A patch (a prepend or a filter) that cannot attach fails closed and logs, so a renamed patch target switches that feature off and leaves the app running. A renamed superclass does not degrade: the two contract tools inherit `Mcp::McpBaseController`, the reminder mailer `SubmitterMailer`, and the SSO, OAuth consent and reminder settings controllers `ApplicationController`, and production loads every class at boot, so Rails does not start. `deploy.sh` treats that as a failed boot and puts the previous overlay back. Check these superclasses at the new tag before bumping.
   - **Check the migrations.** `git diff --stat <old-tag> <new-tag> -- db/migrate`. They run on boot and are not reversed by restoring the old image tag, which is why `deploy.sh` dumps the database first.
2. Bump the version in `docker-compose.yml`, commit, deploy as above.
3. Open sign.icodos.com and check:
   - ICODOS header renders on signed-in pages, no navbar on `/sign_in` or `/`.
   - The user menu in the top right still opens at its normal width, with Profile, Console, Verify PDF and Sign out. A collapsed, text-width menu means a purged class.
   - `/auth/entra` still redirects to `login.microsoftonline.com`.
   - A test email has no DocuSeal footer.
   - Tab title reads "ICODOS – Document Signing".
4. After a version bump, also confirm the MCP endpoint still responds (it is a recent DocuSeal feature), and run the Phase D smoke check in the admin runbook, section 7. Run the reveal and reminder checks as well; both are one `rails runner` line and both are listed in their own sections above.

Note: nothing on the server pulls images on a schedule and nothing checks for new releases. An earlier version of this note claimed a weekly pull and a monthly check; neither existed, and the proxy and database images, then on floating tags, went four and five months without an update. All three images are now pinned by tag and digest, so nothing changes until `docker-compose.yml` does. Upstream releases roughly weekly: https://github.com/docusealco/docuseal/releases
