# DocuSeal + Entra SSO — admin runbook

**Instance:** https://sign.icodos.com
**Server:** `root@31.70.107.24` (IONOS VPS, stack in `/opt/docuseal`)
**Overlay repo (this repo):** https://github.com/ICODOS/docuseal-branding

This runbook covers the recurring operational tasks — adding/removing staff, rotating the Entra client secret, and running the MCP OAuth connector (section 7) — plus the break-glass procedure and periodic checks. Written for an admin sitting in the Azure Portal with SSH access to the VPS.

If you also need the original *setup* guide (one-time Azure app registration, `.env` seeding, deployment from scratch), that's a separate file the person who initially deployed this instance kept locally. Everything below assumes the instance is already running and configured.

---

## 1. Add a new staff member so they can sign in

**When**: a new ICODOS employee needs access to DocuSeal.

**Prerequisites**: the person has an ICODOS Microsoft account (usually a `@icodos.com` or `@icodos.de` address) that already exists in the ICODOS Entra tenant.

### Steps

1. Azure Portal → **Microsoft Entra ID** → **Enterprise applications** → find and open **ICODOS DocuSeal**.
2. Left sidebar → **Users and groups** → click **+ Add user/group**.
3. Under **Users**, search for the person by name or email → select them → click **Select**.
4. Under **Select a role**, leave the default (there's only one role available on the free Entra plan).
5. Click **Assign** at the bottom.
6. Tell the person to visit **https://sign.icodos.com/auth/entra** and sign in with their Microsoft account.

### What happens on first sign-in

- Microsoft's account picker appears (because we default `prompt=select_account`).
- User picks their ICODOS account, completes any MFA that Entra Conditional Access requires.
- The OIDC callback auto-creates their DocuSeal user with role `admin`, their name from Entra claims, and a random password they never see.
- They land on the DocuSeal dashboard as themselves.

### Verify

After the person signs in, in DocuSeal go to **Settings → Users**. The new user should be listed with correct name and email. Server-side you can also confirm:

```bash
ssh root@31.70.107.24
docker compose -f /opt/docuseal/docker-compose.yml logs --tail 200 app | grep -i "auto-provisioned"
```

You'll see a line like `[sso] auto-provisioned user id=N email=…`.

### Note on roles

DocuSeal community edition only implements one functional role (`admin`) — see the design decision recorded in the overlay repo README. Every staff user has full DocuSeal permissions within the ICODOS account. This is a DocuSeal-community limitation, not a config choice. If that ever becomes a real problem, options are DocuSeal Pro (vendor-supported granular roles) or custom `Ability`-class overlay work.

---

## 2. Remove a staff member's access

**When**: a staff member is leaving, or their access needs to be revoked.

Do steps 1 and 2 together, and consider step 3 if they had any content in DocuSeal.

### Step 1 — Revoke Entra assignment (blocks future SSO sign-ins)

1. Azure Portal → **Enterprise applications** → **ICODOS DocuSeal** → **Users and groups**.
2. Find the person, tick their row, click **Remove** in the top bar → confirm.

After this, they can no longer sign in via `/auth/entra` — Microsoft's callback will not return a valid token for them.

### Step 2 — Archive their DocuSeal record

Any existing browser session they have will keep working until their session cookie expires (default: `SESSION_REMEMBER_DAYS=730` = 2 years). To end their access immediately:

1. Sign in to DocuSeal as an admin.
2. **Settings → Users** → find the person.
3. Click **Edit** on their row → check **Archive** (or the equivalent "archive user" action).

Archiving is preferred over deletion because DocuSeal has foreign-key relationships from templates and submissions back to the user. Deletion cascades and may remove content you want to keep. Archived users cannot sign in (our SSO controller explicitly refuses archived users with "Your account has been archived").

### Step 3 — Content handoff (optional)

If the person authored important templates or submissions, transfer ownership to another admin *before* archiving. DocuSeal's UI supports reassigning templates from **Settings → Users → Edit → transfer** or similar (exact wording changes between versions).

### Verify

1. Try signing in as them from a private browser window on `sign.icodos.com/auth/entra` — should fail with "Your Microsoft account isn't linked to a DocuSeal user" (Entra unassigned) or "Your account has been archived" (DocuSeal archived).
2. In DocuSeal, they should no longer appear in **Settings → Users** (or appear under archived users if the UI shows those).

---

## 3. Rotate the Entra client secret

**When**:
- **Every 22 months** — the secret is issued with a 24-month expiry by default. Rotate before it expires or SSO breaks for everyone.
- **After any suspected exposure** — accidentally pasted into a chat, logs, ticket, etc. Rotate immediately.
- **After an admin leaves who had access to `.env` or the Azure Portal.**

The whole procedure takes ~5 minutes and causes zero downtime if you follow the order below (add new secret first, deploy, then delete old).

### Steps

**3a. Create a new client secret in Azure**

1. Azure Portal → **App registrations** → **ICODOS DocuSeal**.
2. Left sidebar → **Certificates & secrets** → **Client secrets** tab → **+ New client secret**.
3. Description: `docuseal-sign-icodos-<yyyymm>` (dated so you can tell rotations apart).
4. Expires: **24 months** (or shorter if that's your policy).
5. Click **Add**.
6. **Copy the "Value" column immediately** — Azure hides it forever once you navigate away. Paste it somewhere safe temporarily (password manager, or straight into a Terminal command per step 3b).

**3b. Deploy the new secret to the server**

Prefer this in-one-Terminal-line approach so the secret never sits on your clipboard longer than necessary. Replace `NEW_SECRET_HERE` with the value you just copied from Azure:

```bash
ssh root@31.70.107.24 'set -e; cd /opt/docuseal; cp .env .env.bak-secret-$(date +%s); sed -i "s|^ENTRA_CLIENT_SECRET=.*|ENTRA_CLIENT_SECRET=NEW_SECRET_HERE|" .env; docker compose up -d; sleep 8; docker compose ps'
```

What that does:
- Backs up the current `.env`.
- Rewrites only the `ENTRA_CLIENT_SECRET=` line (leaves the other 6 lines untouched).
- Recreates the app container with the new env var.
- Prints the container status.

**3c. Verify SSO still works**

In a private browser window: **https://sign.icodos.com/auth/entra** → sign in as yourself. Should land on the dashboard normally.

Also grep the server logs for any token-exchange errors:

```bash
ssh root@31.70.107.24 'docker compose -f /opt/docuseal/docker-compose.yml logs --tail 200 app | grep -i "sso\|entra\|token endpoint"'
```

If you see `[sso] token verification failed` or `token endpoint returned 401` — the new secret didn't paste correctly. Re-run 3b with the correct value, or fall back to break-glass (section 4) while you diagnose.

**3d. Delete the old secret in Azure**

Once you've confirmed 3c, go back to Azure Portal → App registrations → ICODOS DocuSeal → Certificates & secrets, find the OLD secret row (compare to the new one by description or ID), and **delete it**. Only the currently-used secret should remain listed.

This ensures the old secret can't be used to impersonate the app even if it was exposed.

### Calendar reminder

After each rotation, set a reminder in your calendar for **22 months later** so you rotate the new one before it expires. If it expires unnoticed, SSO stops working and staff can't sign in until break-glass is enabled.

---

## 4. Break-glass — bring password login back temporarily

**When**: SSO is broken (Entra outage, expired secret, mis-config) and you need staff to sign in some other way.

**How** (one Terminal command flips it, one flips it back):

```bash
# Enable break-glass — password login works again in ~10s
ssh root@31.70.107.24 'cd /opt/docuseal; sed -i "s/^SSO_BREAK_GLASS=false$/SSO_BREAK_GLASS=true/" .env; docker compose up -d'

# Once SSO is fixed, disable break-glass and re-enforce
ssh root@31.70.107.24 'cd /opt/docuseal; sed -i "s/^SSO_BREAK_GLASS=true$/SSO_BREAK_GLASS=false/" .env; docker compose up -d'
```

While break-glass is active, `/sign_in` and `/password/new` behave normally. Staff who never set a password can use "Forgot your password?" on `/sign_in` to receive a reset email and pick their own.

---

## 5. Periodic checks (do these ~quarterly)

**5a. Entra Assignment Required is still ON**

- Azure Portal → **Enterprise applications** → **ICODOS DocuSeal** → **Properties**.
- Confirm **"Assignment required?"** = **Yes**.

If this ever flips to **No**, any user in the ICODOS Entra tenant will auto-provision a DocuSeal admin account on first sign-in. Entra assignment is the only ACL between the tenant and DocuSeal.

**5b. Assigned user list is current**

- Azure Portal → **Enterprise applications** → **ICODOS DocuSeal** → **Users and groups**.
- Compare against your current staff list. Remove anyone who's left the company.

**5c. Secret expiration is not near**

- Azure Portal → **App registrations** → **ICODOS DocuSeal** → **Certificates & secrets**.
- Look at the **Expires** column for each client secret. Rotate anything within ~2 months of expiry (see section 3).

**5d. DocuSeal user list matches Entra assignment list**

- In DocuSeal: **Settings → Users** (compare to the Entra assigned-users list from 5b).
- Archived users can remain archived in DocuSeal — they can't sign in anyway. But their name still shows on documents they authored, which is usually fine.

---

## 6. Troubleshooting common issues

**"AADSTS7000215: Invalid client secret provided" in the browser after signing in on Microsoft**
The `ENTRA_CLIENT_SECRET` in `.env` doesn't match what Azure has. Almost always: the secret expired, or a paste error during rotation. Fix: rotate again (section 3), being careful with the copy.

**User sees "Your Microsoft account isn't linked to a DocuSeal user. Contact your administrator."**
Should not happen anymore since auto-provisioning is on. If it does, either:
- The user's Entra `preferred_username` / `email` claim is empty (unusual — check their Entra profile has an email set).
- Auto-provisioning failed silently. Check server logs: `docker compose logs --tail 200 app | grep sso`.

**User sees "Your account has been archived."**
Their DocuSeal user exists but is archived. In DocuSeal **Settings → Users** → unarchive them. Alternatively, if you meant to revoke access, do both step 1 and step 2 of section 2.

**Nobody can sign in at all**
Break-glass (section 4), then diagnose. Common causes:
- Client secret expired → section 3.
- Entra Conditional Access policy blocking the app → check Azure Portal → **Microsoft Entra ID → Security → Conditional Access**.
- Container not running → `ssh root@31.70.107.24 'docker compose -f /opt/docuseal/docker-compose.yml ps'`.

**"AADSTS50011: The reply URL specified in the request does not match the reply URLs configured for the application"**
The redirect URI in Azure (**App registrations → Authentication → Redirect URIs**) is wrong. It must be exactly `https://sign.icodos.com/auth/entra/callback` — no trailing slash, no different subdomain.

**User signed in but sees a permissions error inside DocuSeal**
Not an SSO problem. DocuSeal itself is refusing the action. Usually means the user's DocuSeal account belongs to a different Account (multi-account edge case) or they somehow have a non-`admin` role in the DB. Check `Settings → Users` and their role.

---

## 7. MCP OAuth connector (Phase D)

**What this is.** `https://sign.icodos.com/mcp` accepts two kinds of credential. The old one is a static Bearer token you create in **Settings → MCP** — one token, shared by whoever holds it. The new one is OAuth 2.1, which is what Claude's admin-managed custom connectors require, and which makes each tool call run as a *specific* DocuSeal user. Both work at the same time. Static tokens are tried first, so they cannot be affected by anything in the OAuth path.

Design notes and the full endpoint list are in the overlay repo's `README.md`, "Phase D" section. This section is only the operational procedures.

### 7a. Turn it on

The code ships disabled. To enable:

```bash
ssh root@31.70.107.24
cd /opt/docuseal

# 1. The signing key must exist first — Docker creates a *directory* in place of a
#    missing bind-mount source, which would silently leave the layer disabled.
ls -l secrets/mcp_oauth_signing_key.pem     # should be -r-------- owned by 2000:2000

# 2. Add one line to .env
echo 'MCP_OAUTH_ENABLED=true' >> .env

# 3. Apply
docker compose up -d app
```

Confirm it came up enabled:

```bash
docker compose logs app --since 2m | grep mcp-oauth
# want: [mcp-oauth] enabled. issuer=https://sign.icodos.com resource=https://sign.icodos.com/mcp kid=...
# NOT:  [mcp-oauth] disabled ...
# NOT:  [mcp-oauth] MCP_OAUTH_ENABLED=true but the signing key is unusable ...
```

### 7b. Smoke check (run after any enable, key rotation, or DocuSeal version bump)

```bash
# 1. Discovery documents exist and are well formed
curl -s https://sign.icodos.com/.well-known/oauth-protected-resource | python3 -m json.tool
curl -s https://sign.icodos.com/.well-known/oauth-authorization-server | python3 -m json.tool

# 2. Unauthenticated /mcp must 401 *and* carry the discovery pointer.
#    Without this header Claude never finds the authorization server.
curl -s -i -X POST https://sign.icodos.com/mcp \
  -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"tools/list","id":1}' \
  | grep -i -E '^HTTP/|www-authenticate'
# want: 401, and www-authenticate: Bearer resource_metadata="https://sign.icodos.com/.well-known/oauth-protected-resource", scope="mcp"

# 3. The JWKS must contain public key material only — no "d", "p" or "q"
curl -s https://sign.icodos.com/oauth/jwks.json | python3 -m json.tool

# 4. An existing static token still works (backward compatibility)
curl -s -X POST https://sign.icodos.com/mcp -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <a-token-from-Settings-MCP>' \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
# want: the tool list
```

### 7c. Add the connector in Claude

An admin adds a custom connector pointing at `https://sign.icodos.com/mcp`. Leave the **OAuth Client ID** and **OAuth Client Secret** fields empty — Claude registers itself automatically via dynamic client registration, and this authorization server issues public clients only, so there is no secret to supply.

On connect, each user is sent to Microsoft to sign in (if they don't already have a DocuSeal session in that browser), then sees an ICODOS consent screen naming their DocuSeal account and the host the authorization will be sent to. After **Allow**, their tools work as that DocuSeal identity.

Users need to reconnect at most every 14 days — that's the absolute lifetime of the grant, and rotation does not extend it. Re-authorizing is two clicks when they're already signed in to Microsoft.

**Claude Code and other local MCP clients will not connect** as configured. Redirect URIs are restricted to `claude.ai` and `claude.com`; loopback addresses (`localhost`, `127.0.0.1`) are excluded on purpose, because any program on a user's machine could otherwise register itself and phish a one-click grant. If you later need a local client, add the hosts to `MCP_OAUTH_ALLOWED_REDIRECT_HOSTS` in `.env` and understand that you are accepting that risk.

### 7d. Revoke one person's access

**Someone is leaving.** Archive their DocuSeal user (section 2, step 2) and remove their Entra assignment (section 2, step 1). Archiving takes effect on the **next request** — every `/mcp` call and every token refresh re-checks that the account is still active.

**You suspect a specific connector was compromised** (stolen laptop, malware, a token pasted somewhere it shouldn't be). Archiving alone is not enough here, and this is worth understanding before you need it:

> Grants are stateless signed tokens, not database rows. Archiving the user makes every existing token stop working immediately — but it **suspends** rather than destroys them. If you later un-archive that user and their refresh token is still inside its 14-day window, it starts working again.

So for a suspected compromise, do both:

1. Archive the user (immediate effect), and
2. **rotate the signing key** (7e) — the only action that truly destroys issued grants.

There is no per-grant revoke button, by design: the stateless approach was chosen deliberately so that nothing is written to the database holding your executed contracts. The trade-off is exactly this. If it turns out to matter in practice, tell whoever maintains the overlay — adding a small revocation table is a contained change.

**Turning MCP off for the whole account** (Settings → MCP) also blocks every OAuth grant on the next request, and is the fastest blunt instrument if you don't yet know which user is affected.

### 7e. Rotate the signing key

Rotating invalidates every issued token **and** every registered OAuth client, because the client-ID authentication key is derived from the signing key. Every connector has to be reconnected in Claude afterwards. Static Bearer tokens are unaffected.

Do this if you suspect the key was exposed, or on a schedule if you want one (there's no expiry forcing it).

```bash
ssh root@31.70.107.24
cd /opt/docuseal

# 1. Keep the old key so tokens already issued keep verifying during the overlap
mv secrets/mcp_oauth_signing_key.pem secrets/mcp_oauth_signing_key.previous.pem

# 2. New key
openssl genrsa -out secrets/mcp_oauth_signing_key.pem 3072
chown 2000:2000 secrets/mcp_oauth_signing_key.pem
chmod 400 secrets/mcp_oauth_signing_key.pem

# 3. Publish the old public key alongside the new one during the overlap.
#    Add the mount to docker-compose.yml, in the Phase D block:
#      - ./secrets/mcp_oauth_signing_key.previous.pem:/app/config/icodos/mcp_oauth_previous_key.pem:ro
#    and add to .env:
#      MCP_OAUTH_PREVIOUS_SIGNING_KEY_PATH=/app/config/icodos/mcp_oauth_previous_key.pem
docker compose up -d app
docker compose logs app --since 2m | grep mcp-oauth      # new kid= should appear

# 4. Reconnect the connector in Claude (it re-registers itself).
# 5. After ~2 hours (longer than the 1h access-token lifetime), drop the overlap:
#    remove MCP_OAUTH_PREVIOUS_SIGNING_KEY_PATH from .env, remove the extra mount,
#    docker compose up -d app, then shred the old key.
shred -u secrets/mcp_oauth_signing_key.previous.pem
```

If you don't care about the overlap — simplest and fine for a hard rotation — skip steps 1, 3 and 5: just replace the key, restart, and reconnect. Everyone re-authorizes.

### 7f. Roll back

**Fast rollback — one line, no file changes.** OAuth off, static Bearer tokens keep working exactly as before Phase D:

```bash
ssh root@31.70.107.24
cd /opt/docuseal
# set MCP_OAUTH_ENABLED=false in .env (or delete the line)
docker compose up -d app
```

All eight OAuth endpoints then return 404 and the `/mcp` 401 loses its `WWW-Authenticate` header, which is exactly the pre-Phase-D response. Verified. Any connector using OAuth stops working immediately, so tell users first.

**Full rollback — remove the code too.** Delete the single comment-delimited block from `docker-compose.yml`:

```
# --- Phase D: MCP OAuth 2.1 (delete this whole block to remove the code) ---
   ... five mounts plus the signing key mount ...
# --- end Phase D ---
```

Delete all of it, not parts — the initializer registers routes naming controllers that would otherwise be missing. Then `docker compose up -d app`. (Leaving the `MCP_OAUTH_*` environment lines in place is harmless.)

### 7g. Troubleshooting

**Claude says "Couldn't reach the MCP server" and the authorization server sees no traffic.**
Discovery failed. Run smoke check steps 1 and 2. The usual cause is a missing `WWW-Authenticate` header on the 401, which happens when `MCP_OAUTH_ENABLED` isn't `true`.

**Boot log says "the signing key is unusable".**
Either the file is missing, or it isn't readable by the app process, which runs as uid 2000 inside the container — a root-owned mode-600 file is *not* readable by it. Fix with `chown 2000:2000` and `chmod 400`. The layer stays off until this is resolved; static tokens are unaffected. Also check that `secrets/mcp_oauth_signing_key.pem` is a file and not a directory Docker created.

**Boot log says "could not install the /mcp authentication hook".**
Either a partial rollback (the initializer is mounted but `mcp/mcp_oauth.rb` isn't), or a DocuSeal upgrade changed `app/controllers/mcp/mcp_base_controller.rb`. OAuth tokens are refused; static tokens still work. See the README's "Updating DocuSeal itself" checklist.

**A user gets "Your account has been archived."**
Same cause and same fix as the SSO version of this message — see section 6. It's the identical rule, deliberately.

**"Unknown OAuth client" on the consent page.**
The client registration no longer verifies, normally because the signing key was rotated. Remove and re-add the connector in Claude so it registers again.

**Users are asked to reconnect more often than every 14 days.**
Access tokens last an hour and are refreshed automatically. If reconnection is being demanded more often, check the container isn't restarting frequently — the refresh-token reuse guard lives in process memory, and a restart can invalidate an in-flight rotated token, which surfaces as one reconnect prompt.

**A connector fails to register with HTTP 429.**
Registration is rate limited to 20 attempts per hour per source IP. Normal use registers once per connection, so this usually means something is retrying in a loop. Wait an hour, or check the logs for what is hammering it.

**I want to see who is using OAuth.**
`docker compose logs app | grep 'mcp-oauth'`. Successful calls log `/mcp authorized user_id=… client=… scope=…`. Tokens are never logged.

---

## 8. Reference

- Overlay repo: https://github.com/ICODOS/docuseal-branding
- Design notes: see the overlay repo's `README.md`, "Microsoft Entra SSO overlay" and "Phase D — MCP endpoint speaks OAuth 2.1" sections.
- Upstream DocuSeal: https://github.com/docusealco/docuseal (AGPL-3.0). Version pinned in `docker-compose.yml`.
- Entra Enterprise Application: Azure Portal → Microsoft Entra ID → Enterprise applications → ICODOS DocuSeal.
- Entra App registration (secrets, redirect URIs, API permissions): Azure Portal → Microsoft Entra ID → App registrations → ICODOS DocuSeal.

Last updated: 2026-08-07 (added section 7, MCP OAuth connector).

---

## 9. API key reveal for SSO users

SSO-provisioned users have no password — provisioning sets a random one and `SSO_ENFORCE` blocks the reset flow — so DocuSeal's own "enter your password to reveal the API key" dialog is unusable for them. The overlay replaces that prompt with a fresh Microsoft re-authentication.

**For the user:** Settings → API → click the key field → **Confirm with Microsoft**. Microsoft will ask them to sign in again even though they are already signed in to DocuSeal; that is deliberate and is what replaces the password. They then click the key field once more and it is revealed, for two minutes, once.

### Turning it off

```bash
ssh root@31.70.107.24 'cd /opt/docuseal && sed -i "s/^ICODOS_SSO_REVEAL_ENABLED=.*/ICODOS_SSO_REVEAL_ENABLED=false/" .env && docker compose up -d'
```

Takes about fifteen seconds. DocuSeal's stock password dialog returns unchanged; nothing else is affected.

### Smoke check

Run after any enable, restart or DocuSeal version bump:

```bash
ssh root@31.70.107.24 'cd /opt/docuseal && docker compose exec -T -w /app app rails runner "require \"icodos_reveal_check\"; IcodosRevealCheck.call"'
```

All seven lines must read `ok`. The one that matters most is **controller patch attached** — if it detaches on a version bump, users are shown a password box they cannot fill, which looks like a user problem rather than a deployment one.

### Reading the log lines

| Line | Meaning |
|---|---|
| `[icodos-reveal] enabled. guard=redis …` | Normal, at boot |
| `[icodos-reveal] disabled (…)` | Flag off, SSO unconfigured, or Redis unreachable. Fails closed — the password dialog is served |
| `[icodos-reveal] API key revealed to user_id=N …` | A key was disclosed. Upstream logs nothing here; this is the audit trail |
| `[icodos-reveal] identity mismatch …` | Someone re-authenticated as a different Microsoft account than the session they were in. Refused. **Worth asking about** |
| `[icodos-reveal] auth_time missing or stale …` | Microsoft did not confirm a fresh sign-in. Usually a slow round trip; persistent occurrences are worth investigating |
| `[icodos-reveal] rate limited user_id=N` | More than 5 attempts in a minute |
| `[icodos-reveal] could not attach …` | The prepend failed, most likely after a version bump. The password dialog still works for the break-glass admin |

### If Entra is down

Nobody can reveal an API key while Microsoft is unreachable, including during an incident. The fallback is the console:

```bash
ssh root@31.70.107.24 'cd /opt/docuseal && docker compose exec -T -w /app app rails runner "puts User.find_by(email: %q{someone@icodos.com}).access_token.token"'
```

Treat the output as a password — it grants full API access to that account and does not expire until rotated. Rotate afterwards if it was handled carelessly.

### Deployment trap

The overlay's `.rb` files are bind-mounted and **Rails caches classes in production — copying a file to the server does not load it.** A `docker compose restart app` (or `up -d`) is always required.

Worse, files under `lib/` must be named for the constant they define: `lib/icodos_reveal.rb` → `IcodosReveal`. A mismatch does not degrade — Zeitwerk raises, the container crash-loops, and with `SSO_ENFORCE=true` nobody can sign in. This took the instance down for 45 seconds on 15 August 2026. After any change under `lib/`, watch the first boot:

```bash
ssh root@31.70.107.24 'cd /opt/docuseal && docker compose logs app --since 60s | grep -iE "error|zeitwerk|FATAL"'
```

---

## 10. Automatic signature reminders

Overlay code lives in `/opt/docuseal/reminders` and is published in the branding repo. Design and research are in `20260815-DocuSeal-Reminder engine design-v1.md`.

### The scheduled task is NOT in git

This is the part that will be lost on a host rebuild:

```bash
crontab -l | grep -A1 'reminder sweep'
```

It should read:

```
*/15 * * * * cd /opt/docuseal && /usr/bin/docker compose exec -T -w /app app rails runner "IcodosReminderSweep.call" >> /var/log/icodos-reminders.log 2>&1
```

If it is missing, reminders silently stop. The settings page shows a red warning after two hours without a check, and the smoke check fails — but only if someone looks.

### Turning it on and off

```bash
# stop sending immediately, keep the schedule and history
ssh root@31.70.107.24 'cd /opt/docuseal && sed -i "s/^ICODOS_REMINDERS_DRY_RUN=.*/ICODOS_REMINDERS_DRY_RUN=true/" .env && docker compose up -d'

# off entirely
ssh root@31.70.107.24 'cd /opt/docuseal && sed -i "s/^ICODOS_REMINDERS_ENABLED=.*/ICODOS_REMINDERS_ENABLED=false/" .env && docker compose up -d'
```

Dry run defaults to **true**. Sending requires setting it to `false` explicitly.

### Checks

```bash
ssh root@31.70.107.24 'cd /opt/docuseal && docker compose exec -T -w /app app rails runner "require \"icodos_reminder_check\"; IcodosReminderCheck.call"'
tail -20 /var/log/icodos-reminders.log
```

`sweep sent: N due` means live. `sweep dry_run: N due` means nothing was emailed.

### Reading the log

| Line | Meaning |
|---|---|
| `enabled, LIVE` / `enabled, DRY RUN` | mode, at boot |
| `sweep sent: 0 due` | ran, nothing was due — the normal quiet case |
| `SENT submission=N to=…` | a reminder was emailed |
| `ESCALATED submission=N to=…` | the sender was told instead; the signer is now left alone |
| `WOULD SEND …` | dry run only |
| `sweep already running, skipping` | the Redis lock held; normal if two sweeps overlap, suspicious if constant |

### Where the settings are

`/settings/notifications` → *Sign Request Email Reminders*. Four choices, nothing else. Per-document schedules, stop-dates and deadline anchoring are set through the MCP tool, not the page — a date cannot be an account-wide default.

The page shows red text only when reminders are **not** reaching anyone: test mode, a stalled scheduler, or the engine switched off. Silence there means it is working.

### Known behaviour, not a bug

Reminders follow the signing order. With `submitters_order = preserved` only the person whose turn it is is reminded, so an employee is never chased before ICODOS has countersigned.
