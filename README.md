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
| `docker-compose.yml` | Stock compose file plus the five overlay mounts and a pinned image version |

Everything else — application code, database, TLS, email templates — is the unmodified official image `docuseal/docuseal` (pinned, currently `3.1.5`). Email wording, policy links, and the completion message are configured in the app's own Personalization settings, not in this repo.

## License compliance (AGPL-3.0)

DocuSeal is AGPL-3.0 with [additional terms](https://github.com/docusealco/docuseal/blob/master/LICENSE_ADDITIONAL_TERMS) requiring that DocuSeal attribution is retained in **interactive user interfaces**. Accordingly:

- Both modified page templates keep a visible "Powered by DocuSeal" line on the signing and status pages.
- The email footer attribution is removed by `mailer_attribution.html.erb`; emails are not an interactive user interface, so we read the additional terms as not covering them. If DocuSeal clarifies otherwise, this override is a one-line revert.
- This repository is public, which satisfies the AGPL source-availability requirement for our modifications.

## Deploying / updating on the server

```bash
cd /opt/docuseal
git clone https://github.com/ICODOS/docuseal-branding.git tmp-branding \
  && cp -r tmp-branding/branding . \
  && cp tmp-branding/docker-compose.yml . \
  && rm -rf tmp-branding
docker compose up -d --force-recreate app
```

(`.env` with `HOST` and `POSTGRES_PASSWORD` already lives in `/opt/docuseal` and is not part of this repo.)

## MCP server

The instance's built-in MCP server (Settings → MCP) is **enabled**, with a named access token used by our Claude/Cowork workspace (endpoint `https://sign.icodos.com/mcp`, static Bearer auth). Tokens can be revoked and re-issued on that settings page at any time. No code changes are involved — noting it here because it is part of the instance's active configuration.

## Updating DocuSeal itself

The image is version-pinned, so updates are deliberate:

1. Check the [DocuSeal releases](https://github.com/docusealco/docuseal/releases) for changes to the four overridden templates: `app/views/submit_form/_docuseal_logo.html.erb`, `app/views/start_form/_docuseal_logo.html.erb`, `app/views/shared/_mailer_attribution.html.erb`, `app/views/layouts/_head_tags.html.erb`. If they changed upstream, update our copies accordingly.
2. Bump the version in `docker-compose.yml`, commit, deploy as above.
3. Open sign.icodos.com and check: ICODOS header renders, a test email has no DocuSeal footer, tab title reads "ICODOS – Document Signing".
4. After a version bump, also confirm the MCP endpoint still responds (it is a recent DocuSeal feature).

Note: the server's weekly cron (`docker compose pull`) is a no-op for the pinned app image; version bumps are manual by design. A monthly automated check compares the pinned version against the latest DocuSeal release.
