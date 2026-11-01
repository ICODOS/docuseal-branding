# DocuSeal 3.1.6 to 3.3.4: deploy runbook

sign.icodos.com, IONOS VPS, `/opt/docuseal`. Overlay repo `ICODOS/docuseal-branding`, branch `main`.

Written 1 November 2026 against upstream tag 3.3.4. Everything below was checked against the upstream source at both tags, not against release notes.

---

## 1. What changes

**Image:** `docuseal/docuseal:3.1.6` to `docuseal/docuseal:3.3.4`.

| | 3.1.6 | 3.3.4 |
|---|---|---|
| Ruby | 4.0.5 | 4.0.9 |
| Rails | 8.1.3 | 8.1.3.1 |
| devise | 5.0.4 | 5.0.4 |
| turbo-rails | 2.0.23 | 2.0.23 |

Upstream diff across the two tags: 381 files, +14313 / -4702.

Three image-level changes worth knowing about:

- **The trusted CA bundle is refreshed** (`apk upgrade --no-cache ca-certificates-bundle`). This is the reason 3.3.4 is marked "recommended for all on-premises users". It is also the change most likely to matter here: Phase E talks to Microsoft Graph over TLS and the SSO layer talks to `login.microsoftonline.com`.
- **jemalloc is installed** and `MALLOC_CONF` is set, though `LD_PRELOAD` is left commented out, so the allocator is not actually swapped in. No action.
- **Two font packages are added** (`font-liberation`, `font-carlito`), which go with the DOCX upload support that 3.3.3 brought into the open-source build.

**Five new migrations, all of which run on boot:**

| Migration | What it does |
|---|---|
| `20260819091500_add_submissions_account_template_statistics` | adds statistics columns |
| `20260930061927_create_otp_challenges` | new OTP table, replaces `EmailVerificationCodes` for form email 2FA |
| `20261025120000_add_template_id_to_submitters` | adds `submitters.template_id` |
| `20261025120001_populate_submitter_template_id` | backfills it in batches of 10,000, outside a transaction |
| `20261025120002_add_submitters_template_id_indexes` | adds two indexes, drops the old `email` index |

The index migration uses a plain `CREATE INDEX`, not `CONCURRENTLY`, so it holds a lock that blocks writes to `submitters` while it runs. Upstream warns the backfill takes one to two minutes per 500,000 submissions. Size it before deploying, step 2.

**Migrations are not reversed by putting the old image tag back.** That is the whole reason this runbook insists on a database dump.

---

## 2. Before deploying

Size the migration. On the server:

```bash
cd /opt/docuseal && docker compose exec -T postgres psql -U postgres -d docuseal -c "SELECT (SELECT count(*) FROM submissions) AS submissions, (SELECT count(*) FROM submitters) AS submitters;"
```

At our volume this is expected to be seconds, not minutes. If `submitters` is above roughly 200,000, plan the deploy outside working hours; below that, do it whenever.

Record the live feature flags, so the acceptance checks in step 5 test what is actually switched on:

```bash
cd /opt/docuseal && grep -E '^(SSO_ENFORCE|SSO_BREAK_GLASS|MCP_OAUTH_ENABLED|ICODOS_CONTRACTS_ENABLED|ICODOS_SSO_REVEAL_ENABLED|ICODOS_REMINDERS_ENABLED|ICODOS_REMINDERS_DRY_RUN)=' .env
```

Check `secrets/`. The old deploy command copied only `branding/` and `docker-compose.yml`, so `sso/`, `mcp/`, `contracts/`, `reveal/` and `reminders/` on the server may be older than `main`; `deploy.sh` replaces all of them, so that resolves itself. What does not resolve itself is a missing secret:

```bash
cd /opt/docuseal && ls -la secrets/
```

`secrets/` must contain three regular files: `mcp_oauth_signing_key.pem`, `graph_filing_key.pem`, `graph_filing_cert.pem`, all owned by uid 2000. If any of them is a **directory**, Docker created it in place of a missing file at some earlier deploy and the matching feature has been silently off since. Fix that before deploying; `deploy.sh` will refuse to start otherwise.

---

## 3. Deploy

```bash
cd /opt/docuseal && curl -fsSL https://raw.githubusercontent.com/ICODOS/docuseal-branding/main/deploy.sh | bash
```

The script dumps the database to `/var/backups/docuseal`, refreshes all six overlay directories and `docker-compose.yml`, checks that all 39 bind-mount sources exist and are files, brings the stack up, and prints the ICODOS boot diagnostics. It stops before touching the stack if any check fails.

Expect roughly a minute of downtime for the container restart plus the migrations.

---

## 4. Read the boot log

```bash
cd /opt/docuseal && docker compose logs app --since 10m | grep -E '\[sso\]|\[mcp-oauth\]|\[icodos-contracts\]|\[icodos-reveal\]|\[icodos-reminders\]'
```

Each overlay prints one line saying enabled or disabled. Compare them against the flags you recorded in step 2. A feature whose flag is `true` but whose line says disabled, or which prints `could not attach`, means the patch did not take: the overlay fails closed, so the app stays up and the feature is simply absent.

Lines that mean something is wrong:

- `[icodos-contracts] enabled but the dispatch hook is NOT attached` — the MCP contract tools will 404.
- `[icodos-reveal] enabled but the controller patch is NOT attached` — users with no password get the password dialog.
- `[mcp-oauth] could not install the /mcp authentication hook` — OAuth tokens are refused at `/mcp`; the static bearer token still works.

`[icodos-reveal] opted in but not ready yet` right after boot is normal; it means Redis was still starting and it re-checks on first use.

---

## 5. Acceptance checks

Run every check whose flag is on.

**Branding and layout**

1. `https://sign.icodos.com/` shows the ICODOS landing page, no navbar.
2. `/sign_in` shows the ICODOS sign-in card, no navbar. (With `SSO_ENFORCE=true` and no break glass this redirects to Microsoft instead; that is correct.)
3. Signed in: the ICODOS logo sits in the top left and the header does not jump as the page loads.
4. **Open the user menu in the top right.** It must open at its normal width with Profile, Console, Verify PDF and Sign out. A menu collapsed to the width of its text means a purged CSS class; see section 7.
5. On a narrow window, the same menu shows a Settings entry above Profile.
6. The browser tab reads "ICODOS – Document Signing".
7. Open a signing link: ICODOS logo at the top, "Powered by DocuSeal" under it.

**SSO**

8. `/auth/entra` redirects to `login.microsoftonline.com` and a full sign-in round trip works.
9. With `SSO_ENFORCE=true`, `POST /sign_in` is refused with 403.

**MCP and contract tools**

10. Phase D smoke check, admin runbook section 7.
11. `tools/list` on `/mcp` returns seven tools: the upstream five plus `icodos_create_contract_template` and `icodos_send_contract`.

**Reveal**

```bash
cd /opt/docuseal && docker compose exec -T -w /app app rails runner 'require "icodos_reveal_check"; IcodosRevealCheck.call'
```

12. Settings, API, Reveal: an SSO user is offered "Confirm with Microsoft", not a password box.

**Reminders**

```bash
cd /opt/docuseal && docker compose exec -T app bin/rails runner 'require "icodos_reminders_selftest"; IcodosRemindersSelftest.call' && docker compose exec -T app bin/rails runner 'require "icodos_reminder_check"; IcodosReminderCheck.call'
```

13. Settings, Notifications: the four reminder choices render and the one in force is selected.
14. The banner above them is absent when all is well. When it appears, a red background means something broke; an amber background means somebody switched it off on purpose.

**Email**

15. Send yourself a test invitation. No DocuSeal footer.

---

## 6. Rollback

```bash
cd /opt/docuseal && sed -i 's|docuseal/docuseal:3.3.4|docuseal/docuseal:3.1.6|' docker-compose.yml && docker compose up -d
```

**This does not undo the migrations.** 3.1.6 tolerates the extra columns and tables, because Rails ignores columns it does not know about, but this has not been tested here and it is not a state upstream supports. Treat it as a way to get the previous application code back in a hurry, not as a clean revert.

A clean revert is: restore the dump `deploy.sh` wrote to `/var/backups/docuseal`, then put the old tag back. That loses everything signed since the deploy, so it is a last resort.

The faster fix for most problems is not a rollback at all. Every overlay feature has its own flag in `.env`, and flipping one off plus `docker compose up -d` isolates it in about five seconds.

---

## 7. What was rebased, and what to watch

Three overridden views had changed upstream between the two tags. All three are rebased on 3.3.4.

| Override | What changed upstream | Effect if it had been left alone |
|---|---|---|
| `branding/shared__navbar.html.erb` | `<div>` became `<nav>`; a mobile Settings entry was added; `data: { prefetch: false }` became `data: { turbo_prefetch: false }`; **`min-w-[160px]` became an inline `min-width`** | The user menu loses its minimum width, because `min-w-[160px]` is no longer anywhere in upstream's source and Tailwind therefore purged it from the compiled CSS. Visible, and nothing logs it. |
| `branding/head_tags.html.erb` | Hotwire Native title, `turbo-cache-control` meta, native stylesheet | Native clients only. No web effect. |
| `reveal/reveal_access_token_show.html.erb` | the password form is wrapped in `<native-event>` | Native clients only. |

The purge trap is the thing to remember. Tailwind scans `./app/views/**/*.erb` **at image build time**, inside the Docker build, before any overlay file exists. Our overrides are never scanned. So a class that upstream stops using disappears from the CSS, and our copy of it silently stops working: no error, no log line, just wrong layout. Every override in the repo now carries a comment saying so.

One patch was hardened rather than rebased. `SessionsController#create` gained an XHR JSON sign-in path in 3.3.x that skips the CSRF check. The SSO enforcement filter already covered that action, so it was never a hole; it now answers that caller with JSON instead of plain text.

Everything else the overlay touches was verified unchanged at 3.3.4: `McpController::TOOLS`, `Mcp::McpBaseController`, `Mcp::ProtocolController`, `RevealAccessTokenController`, `PasswordsController`, every `AccountConfig` and `EncryptedConfig` key the overlay reads, every `SubmitterMailer` helper `IcodosReminderMailer` inherits, and `Submitter#template`, which is still `has_one :template, through: :submission` despite the new `template_id` column.
