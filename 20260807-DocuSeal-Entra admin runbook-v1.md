# DocuSeal + Entra SSO — admin runbook

**Instance:** https://sign.icodos.com
**Server:** `root@31.70.107.24` (IONOS VPS, stack in `/opt/docuseal`)
**Overlay repo (this repo):** https://github.com/ICODOS/docuseal-branding

This runbook covers the two recurring operational tasks — adding/removing staff, and rotating the Entra client secret — plus the break-glass procedure and periodic checks. Written for an admin sitting in the Azure Portal with SSH access to the VPS.

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
ssh root@31.70.127.24
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

## 7. Reference

- Overlay repo: https://github.com/ICODOS/docuseal-branding
- Design notes: see the overlay repo's `README.md`, "Microsoft Entra SSO overlay" section.
- Upstream DocuSeal: https://github.com/docusealco/docuseal (AGPL-3.0). Version pinned in `docker-compose.yml`.
- Entra Enterprise Application: Azure Portal → Microsoft Entra ID → Enterprise applications → ICODOS DocuSeal.
- Entra App registration (secrets, redirect URIs, API permissions): Azure Portal → Microsoft Entra ID → App registrations → ICODOS DocuSeal.

Last updated: 2026-08-07.
