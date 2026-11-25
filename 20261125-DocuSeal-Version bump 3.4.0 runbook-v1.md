# DocuSeal 3.3.4 to 3.4.0: deploy runbook

**Date:** 25 November 2026
**Scope:** the version bump, the sign-in enforcement fix, the MCP tool policy, two guards in the contract tools, pinned images, 30-day sessions.
**Shape:** follows `20261101-DocuSeal-Version bump 3.3.4 runbook-v1.md`. That document's acceptance checks still apply and are not repeated here.

---

## 1. What changes

| Area | Change |
|---|---|
| Image | `docuseal/docuseal` 3.3.4 to 3.4.0. `postgres` 16.14 to 16.16 and `caddy` 2.11.4 to 2.11.9. All three pinned by tag and digest. |
| Upstream, relevant here | The server now enforces signing order when a later signer submits (3.3.7). Signer-supplied values are validated before they reach the audit trail (3.3.7, 3.4.0). Signed documents are no longer served with permanent public caching (3.3.7). The stock Active Storage routes are no longer drawn (3.3.6). Rails 8.1.4.1, Rack 3.2.9, Ruby 4.0.10. |
| Overridden views | One upstream change in twelve files: `shared/_navbar` gained a line rendering a banner for the DocuSeal mobile app. Left out on purpose, see the file header. No class the overrides use was removed from the compiled CSS. |
| Migrations | Three, index changes only, reversible. The schema they leave is compatible with 3.3.4. |
| Sign-in | Password authentication is switched off at the model while SSO is enforced; `/invitation` is covered; flags are read tolerantly; one boot line states the result. |
| Sessions | `SESSION_REMEMBER_DAYS=30`. Remember cookies older than 30 days stop working, so everyone signs in with Microsoft once after the deploy. |
| MCP | `send_documents` and `create_template` are hidden. A static token that authenticates is logged. |
| Contract tools | `confirm` must be the boolean `true`. Every role needs a signature field. Errors inside a tool no longer surface as "Unknown tool". |

## 2. Tested before deploying

For the first time the overlay was exercised before production: a scratch copy of the stack on the server, own containers and volumes, empty database, reachable on loopback only, SSO enforcement on, generated test credentials. First with 3.3.4 and the overlay as deployed, then switched to 3.4.0 and the candidate on the same database, which also ran the three migrations.

| Check, enforcement on | 3.3.4, overlay as deployed | 3.4.0, candidate |
|---|---|---|
| JSON sign-in with the correct password | HTTP 403, **session works**, remember cookie set | HTTP 403, no session, no cookie |
| Three sign-ins with a wrong password | `failed_attempts` 3 | 0 |
| `GET /invitation` with a reset token | 200, password form | 302 to `/auth/entra` |
| `PUT /invitation` with that token | 303, **password changed, signed in** | 403, nothing changed |
| `tools/list` | 7 tools | 5: three read tools and the two ICODOS tools |
| `send_documents`, `create_template` called directly | executed | tool error naming the replacement, nothing created |
| Send, first role owns no field | preview accepted | refused |
| Send with `confirm` as `"False"`, `"true"`, `1` | **sent three times** | preview three times |
| Create, all fields on the second role | went on to read the file | refused before any SharePoint call |

Also confirmed on the candidate: `confirm: true` still sends; the first-signer domain guard still refuses; break-glass restores password login (boot line `password_login=ALLOWED password_strategy=ON`, sign-in works, the form is served); ten signed-in pages render through the overrides with no template error; the reveal and reminder self-checks pass; sign-in still redirects to Microsoft with the reveal mount block removed; remember cookies are issued for 30 days.

Not tested there, because staging has no tenant: real SharePoint reads and filing, real Microsoft sign-in, mail delivery. Those are the post-deploy checks in section 4.

## 3. Deploy

```bash
cd /opt/docuseal && SHA=<the 40-character commit id> && curl -fsSL "https://raw.githubusercontent.com/ICODOS/docuseal-branding/$SHA/deploy.sh" | DEPLOY_SHA="$SHA" bash
```

The images are pulled beforehand so the downtime is the container restarts: database, app, proxy. Expect one to two minutes.

Expect in the boot log, in addition to the lines of the 3.3.4 runbook:

```
[sso] configured=true enforce=true break_glass=false password_login=blocked password_strategy=off
[icodos-contracts] tool policy: hidden=send_documents,create_template hooks=attached
```

`password_strategy=ON` together with `password_login=blocked`, or `hooks=NOT ATTACHED`, means a hook did not attach. Both are logged as errors as well.

## 4. After the deploy

1. The boot lines above, and the `enabled` line of each feature.
2. `cat /opt/docuseal/.deployed_sha` shows the commit just deployed.
3. Sign in with Microsoft. Everyone has to, once.
4. The three smoke checks: Graph with `write: true`, reveal, reminders.
5. From an MCP client: `tools/list` shows five tools; one `icodos_send_contract` preview against a real template.
6. One real contract through create, preview, send, sign, file.
7. The acceptance list of the 3.3.4 runbook, including the user menu width.

## 5. Rollback

Deploy the previous commit id the same way. `.deployed_sha.prev` on the server holds it. The 3.3.4 image stays on the host. The new indexes do not disturb 3.3.4, and PostgreSQL 16.16 data is read by any 16.x.

A rollback also brings back what this deploy closes. If the reason for rolling back is the sign-in change alone, prefer `SSO_BREAK_GLASS=true`, which lifts it without undoing the rest.
