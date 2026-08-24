interface Env {
  DB: D1Database;
  /** Cloudflare Worker secret. Never commit the Discord webhook itself. */
  DISCORD_WEBHOOK_URL?: string;
  /** Compatibility name for the previously deployed Worker secret. */
  DISCORD_WEBHOOK?: string;
  /** Hashes the random installation identifier before it reaches D1. */
  PEPPER?: string;
  /** Name used by the previously deployed Worker secret. */
  TELEMETRY_PEPPER?: string;
  /** Protects the optional /stats endpoint. */
  STATS_TOKEN?: string;
}

type TelemetryPayload = {
  type?: unknown;
  message?: unknown;
  installation_id?: unknown;
  app?: {
    version?: unknown;
    build?: unknown;
    platform?: unknown;
  };
  system?: {
    os?: unknown;
    architecture?: unknown;
    locale?: unknown;
    model?: unknown;
  };
};

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  });

const installationIdPattern = /^YOM-[A-F0-9]{32}$/;
const simpleValuePattern = /^[\p{L}\p{N} ._+\-(),/]{1,80}$/u;
const feedbackMentionUserId = '289336103700529152';
const UTC_PLUS_8_OFFSET_MS = 8 * 60 * 60 * 1000;

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === 'GET' && url.pathname === '/health') {
      return json(200, { ok: true });
    }
    if (request.method === 'GET' && url.pathname === '/stats') {
      if (!isAdmin(request, env)) return json(401, { error: 'unauthorized' });
      await ensureSchema(env.DB);
      const now = new Date();
      const today = utcPlus8DateKey(now);
      const tomorrow = shiftDateKey(today, 1);
      const lastSevenDays = shiftDateKey(today, -6);
      const todayStart = localDayStartUtc(today);
      const tomorrowStart = localDayStartUtc(tomorrow);
      const lastSevenDaysStart = localDayStartUtc(lastSevenDays);
      const [total, todayTotal, platforms, opensToday, opensLastSevenDays] =
        await env.DB.batch([
        env.DB.prepare('SELECT COUNT(*) AS total FROM telemetry_installations_v1'),
        env.DB
          .prepare(
            'SELECT COUNT(*) AS total FROM telemetry_installations_v1 WHERE first_seen >= ? AND first_seen < ?',
          )
          .bind(todayStart, tomorrowStart),
        env.DB.prepare(
          'SELECT platform, COUNT(*) AS total FROM telemetry_installations_v1 GROUP BY platform ORDER BY total DESC',
        ),
        env.DB
          .prepare(
            'SELECT COUNT(*) AS total FROM telemetry_daily_opens_v1 WHERE opened_at >= ? AND opened_at < ?',
          )
          .bind(todayStart, tomorrowStart),
        env.DB
          .prepare(
            'SELECT COUNT(*) AS total FROM telemetry_daily_opens_v1 WHERE opened_at >= ? AND opened_at < ?',
          )
          .bind(lastSevenDaysStart, tomorrowStart),
      ]);
      return json(200, {
        total: (total.results[0] as { total?: number } | undefined)?.total ?? 0,
        today: (todayTotal.results[0] as { total?: number } | undefined)?.total ?? 0,
        opens_today:
          (opensToday.results[0] as { total?: number } | undefined)?.total ?? 0,
        opens_last_7_days:
          (opensLastSevenDays.results[0] as { total?: number } | undefined)?.total ?? 0,
        platforms: platforms.results,
      });
    }
    if (request.method !== 'POST' || url.pathname !== '/v1/install') {
      return json(404, { error: 'not_found' });
    }
    if (!request.headers.get('content-type')?.toLowerCase().includes('application/json')) {
      return json(415, { error: 'json_required' });
    }

    let payload: TelemetryPayload;
    try {
      const raw = await request.text();
      if (raw.length > 4096) return json(413, { error: 'payload_too_large' });
      payload = JSON.parse(raw) as TelemetryPayload;
    } catch {
      return json(400, { error: 'invalid_json' });
    }

    const type = stringValue(payload.type, 16).toLowerCase();
    if (type === 'feedback') {
      return handleFeedback(payload, request, env);
    }
    const isOpen = type === 'open';
    if (type !== '' && !isOpen) return json(400, { error: 'invalid_payload' });

    const installationId = stringValue(payload.installation_id, 40);
    const version = stringValue(payload.app?.version, 32);
    const build = stringValue(payload.app?.build, 32);
    const platform = stringValue(payload.app?.platform, 16).toLowerCase();
    const os = stringValue(payload.system?.os, 80);
    const architecture = stringValue(payload.system?.architecture, 32);
    const locale = stringValue(payload.system?.locale, 32);
    const model = stringValue(payload.system?.model, 80);

    if (
      !installationIdPattern.test(installationId) ||
      !simpleValuePattern.test(version) ||
      !simpleValuePattern.test(build) ||
      !['android', 'ios'].includes(platform) ||
      !simpleValuePattern.test(os) ||
      !simpleValuePattern.test(architecture) ||
      !simpleValuePattern.test(locale) ||
      !simpleValuePattern.test(model)
    ) {
      return json(400, { error: 'invalid_payload' });
    }
    const pepper = env.TELEMETRY_PEPPER ?? env.PEPPER;
    if (!pepper) return json(503, { error: 'service_unavailable' });

    await ensureSchema(env.DB);
    const installationHash = await hashInstallationId(installationId, pepper);

    // 已知安装标识不重复写安装记录；打开事件仍需继续写入每日记录。
    const prior = await env.DB
      .prepare('SELECT installation_hash FROM telemetry_installations_v1 WHERE installation_hash = ?')
      .bind(installationHash)
      .first();
    const now = new Date().toISOString();
    let installationRecorded = false;
    if (!prior) {
      // 仅在 Cloudflare Cache 中保留 5 分钟、不可逆哈希后的来源标记；不写入 D1，
      // 以降低脚本被伪造时对 Discord 和数据库的滥用。
      if (!(await reserveRateLimit(request, 'install'))) {
        return json(429, { error: 'rate_limited' });
      }

      const inserted = await env.DB
          .prepare(
            `INSERT OR IGNORE INTO telemetry_installations_v1
              (installation_hash, app_version, build_number, platform, os_name, architecture, locale, model, first_seen)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          )
          .bind(installationHash, version, build, platform, os, architecture, locale, model, now)
          .run();
      installationRecorded = (inserted.meta.changes ?? 0) === 1;

      if (installationRecorded) {
        // 即使有人批量伪造请求，也限制每日 Discord 通知数；统计记录本身不受影响。
        const today = now.slice(0, 10);
        const count = await env.DB
            .prepare('SELECT COUNT(*) AS total FROM telemetry_installations_v1 WHERE first_seen >= ?')
            .bind(today)
            .first<{ total: number }>();
        const webhook = env.DISCORD_WEBHOOK_URL ?? env.DISCORD_WEBHOOK;
        if ((count?.total ?? 0) <= 400 && webhook) {
          ctx.waitUntil(notifyDiscord(webhook, {
            installationId,
            version,
            build,
            platform,
            os,
            architecture,
            locale,
            model,
            now,
          }));
        }
      }
    }

    if (!isOpen) {
      if (prior) return json(200, { ok: true, recorded: false });
      return json(installationRecorded ? 201 : 200, {
        ok: true,
        recorded: installationRecorded,
      });
    }

    const day = utcPlus8DateKey(new Date(now));
    const dailyPrior = await env.DB
      .prepare(
        'SELECT installation_hash FROM telemetry_daily_opens_v1 WHERE installation_hash = ? AND day = ?',
      )
      .bind(installationHash, day)
      .first();
    if (dailyPrior) {
      return json(200, {
        ok: true,
        recorded: installationRecorded,
        open_recorded: false,
      });
    }

    // 按安装标识限流，避免同一安装在网络重试时制造大量请求；不同匿名安装不互相影响。
    if (!(await reserveRateLimit(request, `open-${installationHash}`))) {
      return json(429, { error: 'rate_limited' });
    }

    const opened = await env.DB
      .prepare(
        `INSERT OR IGNORE INTO telemetry_daily_opens_v1
          (installation_hash, day, opened_at)
         VALUES (?, ?, ?)`,
      )
      .bind(installationHash, day, now)
      .run();
    return json(200, {
      ok: true,
      recorded: installationRecorded,
      open_recorded: (opened.meta.changes ?? 0) === 1,
    });
  },

  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    await sendDailyReport(env, new Date(controller.scheduledTime));
  },
};

async function handleFeedback(
  payload: TelemetryPayload,
  request: Request,
  env: Env,
): Promise<Response> {
  const message = feedbackValue(payload.message, 1600);
  if (!message) return json(400, { error: 'invalid_feedback' });

  const webhook = env.DISCORD_WEBHOOK_URL ?? env.DISCORD_WEBHOOK;
  if (!webhook) return json(503, { error: 'service_unavailable' });
  if (!(await reserveRateLimit(request, 'feedback'))) {
    return json(429, { error: 'rate_limited' });
  }

  const installationId = stringValue(payload.installation_id, 40);
  const version = stringValue(payload.app?.version, 32) || 'Unknown';
  const build = stringValue(payload.app?.build, 32) || 'Unknown';
  const platform = stringValue(payload.app?.platform, 16).toLowerCase() || 'unknown';
  const os = stringValue(payload.system?.os, 80) || 'Unknown';
  const architecture = stringValue(payload.system?.architecture, 32) || 'Unknown';
  const locale = stringValue(payload.system?.locale, 32) || 'Unknown';
  const model = stringValue(payload.system?.model, 80) || 'Unknown';
  const now = new Date().toISOString();

  try {
    await notifyFeedback(webhook, {
      message,
      installationId: installationId || '未提供',
      version,
      build,
      platform,
      os,
      architecture,
      locale,
      model,
      now,
    });
    return json(200, { ok: true });
  } catch (_) {
    return json(502, { error: 'delivery_failed' });
  }
}

async function ensureSchema(db: D1Database): Promise<void> {
  await db.batch([
    db.prepare(
      `CREATE TABLE IF NOT EXISTS telemetry_installations_v1 (
        installation_hash TEXT PRIMARY KEY,
        app_version TEXT NOT NULL,
        build_number TEXT NOT NULL,
        platform TEXT NOT NULL,
        os_name TEXT NOT NULL,
        architecture TEXT NOT NULL,
        locale TEXT NOT NULL,
        model TEXT NOT NULL,
        first_seen TEXT NOT NULL
      )`,
    ),
    db.prepare(
      'CREATE INDEX IF NOT EXISTS telemetry_installations_v1_first_seen ON telemetry_installations_v1(first_seen)',
    ),
    db.prepare(
      `CREATE TABLE IF NOT EXISTS telemetry_daily_opens_v1 (
        installation_hash TEXT NOT NULL,
        day TEXT NOT NULL,
        opened_at TEXT NOT NULL,
        PRIMARY KEY (installation_hash, day)
      )`,
    ),
    db.prepare(
      'CREATE INDEX IF NOT EXISTS telemetry_daily_opens_v1_day ON telemetry_daily_opens_v1(day)',
    ),
    db.prepare(
      'CREATE INDEX IF NOT EXISTS telemetry_daily_opens_v1_opened_at ON telemetry_daily_opens_v1(opened_at)',
    ),
    db.prepare(
      `CREATE TABLE IF NOT EXISTS telemetry_daily_reports_v1 (
        report_day TEXT PRIMARY KEY,
        sent_at TEXT NOT NULL
      )`,
    ),
  ]);
}

async function sendDailyReport(env: Env, scheduledAt: Date): Promise<void> {
  const webhook = env.DISCORD_WEBHOOK_URL ?? env.DISCORD_WEBHOOK;
  if (!webhook) return;

  await ensureSchema(env.DB);

  // The cron runs at 00:00 UTC+8 (16:00 UTC), so report the completed UTC+8 day.
  const reportDay = shiftDateKey(utcPlus8DateKey(scheduledAt), -1);
  const nextDay = shiftDateKey(reportDay, 1);
  const lastSevenDays = shiftDateKey(reportDay, -6);
  const reportStart = localDayStartUtc(reportDay);
  const nextDayStart = localDayStartUtc(nextDay);
  const lastSevenDaysStart = localDayStartUtc(lastSevenDays);

  const alreadySent = await env.DB
    .prepare('SELECT report_day FROM telemetry_daily_reports_v1 WHERE report_day = ?')
    .bind(reportDay)
    .first();
  if (alreadySent) return;

  const [installations, newInstallations, yesterdayOpens, lastSevenOpens, platforms] =
    await env.DB.batch([
      env.DB.prepare('SELECT COUNT(*) AS total FROM telemetry_installations_v1'),
      env.DB
        .prepare(
          'SELECT COUNT(*) AS total FROM telemetry_installations_v1 WHERE first_seen >= ? AND first_seen < ?',
        )
        .bind(reportStart, nextDayStart),
      env.DB
        .prepare(
          'SELECT COUNT(*) AS total FROM telemetry_daily_opens_v1 WHERE opened_at >= ? AND opened_at < ?',
        )
        .bind(reportStart, nextDayStart),
      env.DB
        .prepare(
          'SELECT COUNT(*) AS total FROM telemetry_daily_opens_v1 WHERE opened_at >= ? AND opened_at < ?',
        )
        .bind(lastSevenDaysStart, nextDayStart),
      env.DB.prepare(
        'SELECT platform, COUNT(*) AS total FROM telemetry_installations_v1 GROUP BY platform ORDER BY total DESC',
      ),
    ]);

  const platformText = platforms.results.length
    ? platforms.results
        .map((row) => {
          const value = row as { platform?: string; total?: number };
          const platform = value.platform === 'ios' ? 'iOS' : value.platform === 'android' ? 'Android' : 'Unknown';
          return `${platform} ${value.total ?? 0}`;
        })
        .join(' · ')
    : 'No data';

  await notifyDailyReport(webhook, {
    reportDay,
    sentAt: formatUtcPlus8(new Date()),
    installations: countValue(installations.results[0]),
    newInstallations: countValue(newInstallations.results[0]),
    yesterdayOpens: countValue(yesterdayOpens.results[0]),
    lastSevenOpens: countValue(lastSevenOpens.results[0]),
    platformText,
  });

  await env.DB
    .prepare('INSERT OR IGNORE INTO telemetry_daily_reports_v1 (report_day, sent_at) VALUES (?, ?)')
    .bind(reportDay, new Date().toISOString())
    .run();
}

function countValue(row: unknown): number {
  const value = row as { total?: number } | undefined;
  return value?.total ?? 0;
}

function utcPlus8DateKey(value: Date): string {
  return new Date(value.getTime() + UTC_PLUS_8_OFFSET_MS).toISOString().slice(0, 10);
}

function shiftDateKey(day: string, days: number): string {
  const value = new Date(`${day}T00:00:00.000Z`);
  value.setUTCDate(value.getUTCDate() + days);
  return value.toISOString().slice(0, 10);
}

function localDayStartUtc(day: string): string {
  return new Date(new Date(`${day}T00:00:00.000Z`).getTime() - UTC_PLUS_8_OFFSET_MS)
    .toISOString();
}

function formatUtcPlus8(value: Date): string {
  return `${new Date(value.getTime() + UTC_PLUS_8_OFFSET_MS).toISOString().slice(0, 19).replace('T', ' ')} UTC+8`;
}

function isAdmin(request: Request, env: Env): boolean {
  const authorization = request.headers.get('authorization') ?? '';
  return Boolean(env.STATS_TOKEN) && authorization === `Bearer ${env.STATS_TOKEN}`;
}

async function hashInstallationId(installationId: string, pepper: string): Promise<string> {
  return sha256(`${pepper}:${installationId}`);
}

async function reserveRateLimit(request: Request, scope: string): Promise<boolean> {
  const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
  const source = await sha256(`yomiru-${scope}-v1:${ip}`);
  const key = new Request(`https://rate-limit.invalid/yomiru/${scope}/${source}`);
  if (await caches.default.match(key)) return false;
  await caches.default.put(
    key,
    new Response('1', { headers: { 'cache-control': 'max-age=300' } }),
  );
  return true;
}

async function sha256(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

function stringValue(value: unknown, maxLength: number): string {
  if (typeof value !== 'string') return '';
  const compact = value.replace(/[\u0000-\u001F\u007F]/g, ' ').trim().replace(/\s+/g, ' ');
  return compact.length <= maxLength ? compact : '';
}

function feedbackValue(value: unknown, maxLength: number): string {
  if (typeof value !== 'string') return '';
  const normalized = value
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '')
    .trim();
  if (normalized.length === 0 || normalized.length > maxLength) return '';
  return normalized;
}

async function notifyDiscord(
  webhook: string,
  event: {
    installationId: string;
    version: string;
    build: string;
    platform: string;
    os: string;
    architecture: string;
    locale: string;
    model: string;
    now: string;
  },
): Promise<void> {
  const platform = event.platform === 'ios' ? 'iOS' : 'Android';
  const response = await fetch(webhook, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      username: 'Yomiru',
      embeds: [
        {
          title: '🌷 Yomiru 有新人加入！',
          color: 0x57f287,
          fields: [
            {
              name: '版本',
              value: `${platform} ${event.version} (${event.build})`,
              inline: true,
            },
            {
              name: '系统标识',
              value: `\`${event.installationId}\``,
              inline: false,
            },
            {
              name: '系统',
              value: `${event.os} ${event.architecture} ${event.locale}`,
              inline: true,
            },
            {
              name: '设备',
              value: event.model,
              inline: true,
            },
          ],
          footer: { text: `Received at ${event.now} UTC` },
          timestamp: event.now,
        },
      ],
      allowed_mentions: { parse: [] },
    }),
  });
  if (!response.ok) throw new Error('Discord delivery failed');
}

async function notifyFeedback(
  webhook: string,
  event: {
    message: string;
    installationId: string;
    version: string;
    build: string;
    platform: string;
    os: string;
    architecture: string;
    locale: string;
    model: string;
    now: string;
  },
): Promise<void> {
  const platform = event.platform === 'ios' ? 'iOS' : 'Android';
  const message = event.message
    .replaceAll('@everyone', '@ everyone')
    .replaceAll('@here', '@ here');
  const response = await fetch(webhook, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      username: 'Yomiru',
      content: `<@${feedbackMentionUserId}>`,
      embeds: [
        {
          title: '📝 Yomiru 收到一条反馈',
          description: message,
          color: 0xffb347,
          fields: [
            {
              name: '版本',
              value: `${platform} ${event.version} (${event.build})`,
              inline: true,
            },
            {
              name: '系统标识',
              value: `\`${event.installationId}\``,
              inline: false,
            },
            {
              name: '系统',
              value: `${event.os} ${event.architecture} ${event.locale}`,
              inline: true,
            },
            {
              name: '设备',
              value: event.model,
              inline: true,
            },
          ],
          footer: { text: `Received at ${event.now} UTC` },
          timestamp: event.now,
        },
      ],
      allowed_mentions: { parse: [], users: [feedbackMentionUserId] },
    }),
  });
  if (!response.ok) throw new Error('Discord delivery failed');
}

async function notifyDailyReport(
  webhook: string,
  event: {
    reportDay: string;
    sentAt: string;
    installations: number;
    newInstallations: number;
    yesterdayOpens: number;
    lastSevenOpens: number;
    platformText: string;
  },
): Promise<void> {
  const response = await fetch(webhook, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      username: 'Yomiru',
      embeds: [
        {
          title: '📊 Yomiru 每日统计',
          description: [
            `Reporting period: **${event.reportDay} 00:00–24:00 UTC+8**`,
            `Sent at: **${event.sentAt}**`,
          ].join('\n'),
          color: 0x6c63ff,
          fields: [
            {
              name: 'Total installations',
              value: `**${event.installations}**`,
              inline: true,
            },
            {
              name: 'New installations',
              value: `**${event.newInstallations}**`,
              inline: true,
            },
            {
              name: 'Daily opens',
              value: `**${event.yesterdayOpens}**`,
              inline: true,
            },
            {
              name: 'Last 7 days',
              value: `**${event.lastSevenOpens}**`,
              inline: true,
            },
            {
              name: 'Platforms',
              value: event.platformText.replaceAll(' · ', '\n'),
              inline: false,
            },
          ],
          footer: { text: 'Anonymous telemetry · UTC+8' },
          timestamp: new Date().toISOString(),
        },
      ],
      allowed_mentions: { parse: [] },
    }),
  });
  if (!response.ok) throw new Error('Discord daily report failed');
}
