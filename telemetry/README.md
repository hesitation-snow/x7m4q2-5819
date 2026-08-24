# Yomiru anonymous telemetry

This Cloudflare Worker records one anonymous installation and at most one anonymous open per
installation per UTC day. It also forwards user-submitted feedback to the project Discord channel.

It accepts only:

- a randomly generated installation identifier;
- app version, build number and platform;
- operating-system version, CPU architecture, locale and device model.

The daily open record stores only a peppered installation hash, UTC day and timestamp. It is
idempotent per installation and day, so repeated launches or retries do not inflate the count.

It does not accept account identifiers, login credentials, session keys, book or reading data, IP addresses, or location. The short IP-derived rate-limit key is hashed and retained only in Cloudflare Cache for five minutes; it is never written to D1.

Feedback is accepted only after an explicit user action in the app. It is limited to 1600 characters,
is sent with the app version and basic device context, and is protected by a separate five-minute
per-IP rate limit. Users are warned not to include passwords, tokens or other sensitive information.

## Deploy

The existing `yomiru-telemetry` Worker uses the `yomiru-telemetry` D1 database and the `telemetry.yutro.uk` custom domain. It requires the Worker secrets `DISCORD_WEBHOOK_URL`, `TELEMETRY_PEPPER`, and `STATS_TOKEN`. Set only missing secrets before deploying:

```bash
npx wrangler secret put DISCORD_WEBHOOK_URL
npx wrangler secret put TELEMETRY_PEPPER
npx wrangler secret put STATS_TOKEN
npx wrangler deploy
```

The protected `GET /stats` endpoint returns installation totals, today's first installations,
`opens_today`, `opens_last_7_days`, and platform totals. The open counts are unique anonymous
installations, not raw process-launch events. Its daily windows use the UTC+8 calendar day.

The Worker also sends a daily summary to the configured Discord webhook at `00:00 UTC+8`
(`16:00 UTC`). The summary reports the completed UTC+8 calendar day, including total
installations, new installations, daily opens, and the previous seven completed days of opens.
A D1 report record prevents the same UTC+8 day from being sent more than once during normal
retries.

Never commit `.dev.vars`, Wrangler state, API tokens, or the Discord webhook.
