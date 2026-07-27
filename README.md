# ICODOS DocuSeal Branding

Branding overlay for our self-hosted [DocuSeal](https://github.com/docusealco/docuseal) instance at sign.icodos.com. Instead of forking and rebuilding the whole application, we mount two modified view templates and the ICODOS logo over the official Docker image.

## What is changed

| File | Purpose |
|---|---|
| `branding/submit_form__docuseal_logo.html.erb` | Header on the document signing page — ICODOS logo instead of the DocuSeal logo |
| `branding/start_form__docuseal_logo.html.erb` | Header on start / completed / declined / expired pages |
| `branding/icodos-logo.png` | ICODOS logo (black, transparent background) served at `/icodos-logo.png` |
| `docker-compose.yml` | Stock compose file plus the three overlay mounts and a pinned image version |

Everything else — application code, database, TLS, emails — is the unmodified official image `docuseal/docuseal` (pinned, currently `3.1.5`).

## License compliance (AGPL-3.0)

DocuSeal is AGPL-3.0 with [additional terms](https://github.com/docusealco/docuseal/blob/master/LICENSE_ADDITIONAL_TERMS) requiring that DocuSeal attribution is retained in interactive user interfaces. Accordingly:

- Both modified templates keep a visible "Powered by DocuSeal" line.
- The email attribution partial is untouched.
- This repository is public, which satisfies the AGPL source-availability requirement for our modifications.

## Deploying / updating on the server

```bash
cd /opt/docuseal
git clone https://github.com/ICODOS/docuseal-branding.git tmp-branding \
  && cp -r tmp-branding/branding . \
  && cp tmp-branding/docker-compose.yml . \
  && rm -rf tmp-branding
docker compose up -d
```

(`.env` with `HOST` and `POSTGRES_PASSWORD` already lives in `/opt/docuseal` and is not part of this repo.)

## Updating DocuSeal itself

The image is version-pinned, so updates are deliberate:

1. Check the [DocuSeal releases](https://github.com/docusealco/docuseal/releases) for changes to `app/views/submit_form/_docuseal_logo.html.erb` or `app/views/start_form/_docuseal_logo.html.erb`. If they changed upstream, update our copies accordingly.
2. Bump the version in `docker-compose.yml`, commit, deploy as above.
3. Open sign.icodos.com and check that the header still renders correctly.

Note: the server previously auto-updated weekly via cron (`docker compose pull`). With the pinned version that job is a no-op for the app image; version bumps are manual by design.
