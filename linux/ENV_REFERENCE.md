---
doc_type: reference
owner: "@devops-team"
last_reviewed: 2026-08-04
source_paths:
    - .env.example
    - .env.secrets.example
    - config/
    - app/
    - Modules/
stability: active
---

# Treescout — Environment Variable Reference

Full catalog of every key in `.env.example`, derived from a code audit (every key traced to its actual consumer, or lack thereof) rather than from comments alone. Compiled 2026-08-04 after discovering `TICKET_URL`/`KB_URL` were undocumented but load-bearing, and that a chunk of `.env.example` dated back to modules removed months earlier.

**Where a value goes:** `Secret` column marks whether a key belongs in `.env` (structural config — hosts, usernames, IDs, feature flags) or `.env.secrets` (passwords/API secrets — injected into containers via Docker Compose `env_file:`, which sets real OS env vars that always win over anything in `.env` per phpdotenv's "never overwrite an already-set var" behavior). See `deployment/README.md` for the full mechanism.

---

## Action1 (RMM integration)

| Key | Consumer | Purpose | Required | Secret |
|---|---|---|---|---|
| `ACTION1_REGION` | `Modules/Action1/Config/action1.php:35`, `BaseAction1Service.php` | API region (us/eu/ap) | Optional (default `us`) | N |
| `ACTION1_SYNC_CLIENT_ID` | `Modules/Action1/Config/action1.php:51` | OAuth2 "Sync" (read-only) role client ID | Required if Action1 used | N |
| `ACTION1_SYNC_CLIENT_SECRET` | `Modules/Action1/Config/action1.php:52` | OAuth2 "Sync" role secret | Required if Action1 used | **Y** |
| `ACTION1_AUTOMATION_RUNNER_CLIENT_ID` | `Modules/Action1/Config/action1.php:55` | OAuth2 "AutomationRunner" role client ID | Required if Action1 used | N |
| `ACTION1_AUTOMATION_RUNNER_CLIENT_SECRET` | `Modules/Action1/Config/action1.php:56` | OAuth2 "AutomationRunner" role secret | Required if Action1 used | **Y** |
| `ACTION1_SCRIPT_MANAGER_CLIENT_ID` | `Modules/Action1/Config/action1.php:59` | OAuth2 "ScriptManager" role client ID | Required if Action1 used | N |
| `ACTION1_SCRIPT_MANAGER_CLIENT_SECRET` | `Modules/Action1/Config/action1.php:60` | OAuth2 "ScriptManager" role secret | Required if Action1 used | **Y** |
| `ACTION1_ENTERPRISE_ORG_ID` | `Action1ManageService.php:159` | Org UUID for custom-script CRUD | Required for script manager | N |
| `ACTION1_WEBHOOK_SECRET` | `Action1WebhookController.php:138` | Verifies inbound Action1 webhook signature | Required for webhook feature | **Y** |
| `ACTION1_DIAGNOSTIC_CALLBACK_URL` | `Modules/Action1/Config/action1.php:122`, `RmmBridgeService.php:493` | Public base URL the CMD diagnostic script posts results to | Optional (falls back to `app.url`) | N |
| `ACTION1_DIAGNOSTIC_WEBHOOK_SECRET` | `VerifyDiagnosticCallbackSignature.php:28` | HMAC secret verifying diagnostic phone-home callback | Required for diagnostic feature | **Y** |
| `ACTION1_TEST_ENDPOINT_NAME` | `Admin/ResilienceController.php:139` | Admin connectivity-canary probe endpoint name | Optional (real ops feature, not a test fixture) | N |
| `ACTION1_TEST_GROUP_NAME` | `Admin/ResilienceController.php:141` | Admin connectivity-canary probe group | Optional | N |
| `ACTION1_TEST_ORG_ID` | `Admin/ResilienceController.php:139,281,816,854` | Admin connectivity-canary probe org UUID | Optional | N |
| `ACTION1_API_RATE_LIMIT` | `config/services.php:56` (declared, never read) | Meant to cap Action1 API calls/hour | **Needs review** — real limits are hardcoded in `Action1Service.php` | N |
| `ACTION1_DEBUG` | `Modules/Action1/Config/action1.php:105` (declared, never read) | Meant as a debug-logging toggle | **Needs review** | N |
| `ACTION1_SYNC_INTERVAL_HOURS` | `Modules/Action1/Config/action1.php:95` (declared, never read) | Meant to set default sync cadence | **Needs review** — actual interval is DB-backed (`Option` model, editable in UI) | N |

## Admin / Agent / Finance / Reporter seed users

Seeded by `database/seeders/UserSeeder.php`, gated by `SEED_SCAFFOLD_USERS` (not previously documented — found via the seeder itself).

| Key | Consumer | Purpose | Required | Secret |
|---|---|---|---|---|
| `ADMIN_EMAIL` | `config/app.php:18`, `UserSeeder.php:21`, also used for deployment-admin detection | Primary admin account email | Has default, should be set | N |
| `ADMIN_FIRST_NAME` / `ADMIN_LAST_NAME` | `config/app.php:220-221` | Admin seed-user name | Optional | N |
| `ADMIN_PASSWORD` | `config/app.php:222` | Admin seed-user password | Optional (default exists) | **Y** |
| `AGENT_EMAIL` / `AGENT_FIRST_NAME` / `AGENT_LAST_NAME` | `config/app.php:225-227` | Default support-agent seed user | Optional | N |
| `AGENT_PASSWORD` | `config/app.php:228` | Agent seed-user password | Optional | **Y** |
| `FINANCE_EMAIL` / `FINANCE_FIRST_NAME` / `FINANCE_LAST_NAME` | `config/app.php:231-233` | Default finance-role seed user | Optional | N |
| `FINANCE_PASSWORD` | `config/app.php:234` | Finance seed-user password | Optional | **Y** |
| `REPORTER_EMAIL` / `REPORTER_FIRST_NAME` / `REPORTER_LAST_NAME` | `config/app.php:237`, `UserSeeder.php` | Default "reporter" role seed user | Optional | N |
| `REPORTER_PASSWORD` | `UserSeeder.php` | Reporter seed-user password | Optional | **Y** |

## App core

| Key | Consumer | Purpose | Required | Secret |
|---|---|---|---|---|
| `APP_KEY` | `config/app.php:122` | Laravel encryption key | **Required** (framework core) | **Y** |
| `APP_ENV` | `config/app.php:31`, `bootstrap/app.php:66` | Environment name | **Required** | N |
| `APP_DEBUG` | `config/app.php:44` | Debug mode | **Required** | N |
| `APP_URL` | `config/app.php:69`; feeds `TICKET_URL`/`KB_URL` defaults, mail EHLO domain, public disk URL | Base app URL | **Required** | N |
| `APP_NAME` | `config/app.php:16`; seeds Redis/cache/session key prefixes | App name | Optional | N |
| `APP_TIMEZONE` / `APP_LOCALE` / `APP_FALLBACK_LOCALE` / `APP_FAKER_LOCALE` | `config/app.php` | i18n/timezone | Optional | N |
| `APP_MAINTENANCE_DRIVER` | `config/app.php:144` | `php artisan down` driver | Optional | N |
| `APP_BUILD_COMMIT` / `APP_SOURCE_BRANCH` / `APP_SOURCE_REPO` | `config/app.php:191-193`, `SystemController.php` | Build/version info shown on System page | Optional | N |
| `APP_GITHUB_API_TOKEN` | `config/app.php:194`, `ModulesController.php:1792` | GitHub API token for module-update/version-check UI | Optional (degrades gracefully) | **Y** |
| `TICKET_URL` | `config/app.php:74`, `SetContextUrl.php` | Semantic alias for the ticketing interface root | Optional (falls back to `APP_URL`) | N |
| `KB_URL` | `config/app.php:75`, `SetContextUrl.php`, `AppServiceProvider.php:152` | Dedicated Knowledge Base hostname — see middleware note below | Optional (falls back to `APP_URL/kb`) | N |

**`TICKET_URL`/`KB_URL` mechanism:** `app/Http/Middleware/SetContextUrl.php` parses `KB_URL`'s host. A request arriving on that host gets its root URL forced to `KB_URL` (so generated links stay on the KB subdomain); a request on any *other* host hitting a `/kb*` path gets a 302 redirect to the KB host. Leave both unset and KB pages just live at `APP_URL/kb` with no redirect behavior — safe default for single-domain deployments.

## Broadcasting / Cache / DB / Filesystem / Session / Queue

| Key | Consumer | Purpose | Required | Secret |
|---|---|---|---|---|
| `BROADCAST_CONNECTION` | `config/broadcasting.php:18` | Broadcasting driver (reverb) | Required for realtime | N |
| `CACHE_STORE` | `config/cache.php:18` | Cache driver | Required (default `database`) | N |
| `CACHE_PREFIX` | `config/cache.php:106` | Cache key prefix | Optional | N |
| `DB_CONNECTION` / `DB_HOST` / `DB_PORT` / `DB_DATABASE` / `DB_USERNAME` | `config/database.php` | DB connection | **Required** | N |
| `DB_PASSWORD` | `config/database.php` | DB connection password | **Required** | **Y** |
| `FILESYSTEM_DISK` | `config/filesystems.php:16` | Default storage disk | Required | N |
| `QUEUE_CONNECTION` | `config/queue.php:16` | Queue driver | Required (default `database`) | N |
| `MIGRATION_JOB_TIMEOUT` | `config/queue.php:98` (`long-running` connection `retry_after`) | Retry-after window for the long-running queue | Optional (default 86400s). Doc-comment says "Email Migration" — stale, that module's gone, but `GoogleAdmin`'s `SyncGoogleChromebooksJob`/`SyncGoogleUsersJob` still use this connection | N |
| `RATE_LIMITER_DRIVER` | `config/services.php:50` | App rate-limiter backend | Optional (default `redis`) | N |
| `REDIS_CLIENT` | `config/database.php:160` | phpredis vs predis | Optional | N |
| `REDIS_HOST` / `REDIS_PORT` | `config/database.php`, `config/reverb.php` | Redis connection | Required if using Redis | N |
| `REDIS_PASSWORD` | `config/database.php`, `config/reverb.php` | Redis auth | Optional/required depending on deployment | **Y** |
| `SESSION_DRIVER` | `config/session.php:21` | Session backend | Required (default `database`) | N |
| `SESSION_LIFETIME` / `SESSION_PATH` / `SESSION_DOMAIN` | `config/session.php` | Session TTL/cookie scope | Optional | N |
| `SESSION_ENCRYPT` / `SESSION_SECURE_COOKIE` | `config/session.php` | Session security flags | Optional/recommended in prod | N |
| `TRUSTED_PROXIES` | `bootstrap/app.php:30`, `config/app.php:56` | Reverse-proxy CIDR trust list | Optional (default `*`) | N |
| `DEFAULT_FOLLOW_UP_DAYS` | `config/app.php:206`, `Conversation.php:550` | Default days-until-follow-up | Optional (default 3) | N |
| `CIRCUIT_BREAKER_THRESHOLD` / `CIRCUIT_BREAKER_TIMEOUT` | `config/services.php:88-89`, `CircuitBreakerService.php` | External-call circuit breaker tuning | Optional | N |
| `ACTIVITY_LOGGER_ENABLED` | `config/activitylog.php:8` | Kill switch for activity logging | Optional (default true) | N |
| `ACTIVITY_LOGGER_DELETE_RECORDS_OLDER_THAN_DAYS` | `config/activitylog.php:14` | Retention window | Optional (default 30) | N |
| `LOG_CHANNEL` / `LOG_STACK` / `LOG_LEVEL` / `LOG_DEPRECATIONS_CHANNEL` | `config/logging.php` | Logging config | Required/optional (framework core) | N |
| `CLIENT_PORTAL_WEBSOCKET_ENABLED` | `Modules/ClientPortal/config/clientportal.php:30` (declared, never read) | Meant to toggle portal websocket features | **Needs review** | N |
| `CLIENT_SESSION_LIFETIME` | `Modules/ClientPortal/config/clientportal.php:20` (declared, never read) | Meant to set portal session lifetime | **Needs review** | N |

## Google (SSO login + GoogleAdmin Workspace API)

Two distinct feature areas share the `GOOGLE_*` prefix — SSO login (`config/services.php`) and Workspace Directory API access (`Modules/GoogleAdmin/Config/google.php`). Per-domain Workspace credentials are increasingly DB-driven (see `GoogleDomainResolver`); these env vars are the legacy global fallback.

| Key | Consumer | Purpose | Required | Secret |
|---|---|---|---|---|
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` / `GOOGLE_REDIRECT_URI` | `config/services.php:36-38` | OAuth2 app credentials (Socialite) | Required for Google SSO | Secret is **Y**, ID/redirect N |
| `GOOGLE_ADMIN_EMAILS` | `config/services.php:39`, `SocialAuthController.php:50` | Emails allowed to log in as admin via Google | Optional/security-relevant | N |
| `GOOGLE_ALLOWED_DOMAINS` | `config/services.php:40`, `SocialAuthController.php:59` | Domains allowed to log in via Google SSO | Optional | N |
| `GOOGLE_ADMIN_EMAIL` | `Modules/GoogleAdmin/Config/google.php:20`, `GoogleDomainResolver.php:87` | Global-fallback Workspace super-admin email for domain-wide delegation | Required for GoogleAdmin sync (legacy single-domain fallback) | N |
| `GOOGLE_DOMAIN` | `Modules/GoogleAdmin/Config/google.php:24`, `GoogleWorkspaceService.php` | Global-fallback Workspace domain | Required (legacy fallback, live) | N |
| `GOOGLE_CREDENTIALS_PATH` | `Modules/GoogleAdmin/Config/google.php:18` | Path to service-account JSON | Required for GoogleAdmin sync unless fully DB-driven | **Y** (path to a secret file) |
| `GOOGLE_API_RATE_LIMIT` | `Modules/GoogleAdmin/Config/google.php:26` (live, 8 consumers) — a *separate* declaration at `config/services.php:52` is dead | Caps Google Workspace API calls/hour | Optional | N |
| `GOOGLE_CUSTOMER_ID` | `Modules/GoogleAdmin/Config/google.php:22` (declared, never read) | Meant as global Workspace customer ID | **Needs review** — actual values are per-domain in the `google_admin_configs` DB table | N |
| `GOOGLE_PUSH_NOTIFICATION_URL` | `Modules/GoogleAdmin/Config/google.php:30` (declared, never read) | Meant as the webhook callback URL registered with Google | **Needs review** — actual URL is admin-entered via form | N |
| `GOOGLE_WEBHOOK_SECRET` | `Modules/GoogleAdmin/Config/google.php:28` (declared, never read) | Meant to authenticate inbound Google push webhooks | **Needs review** — actual auth is per-channel DB-stored tokens (`X-Goog-Channel-Token`) | N |

## IMAP (global default mailbox-fetch account)

Most mailboxes are configured per-mailbox via the Settings UI/DB; these are the fallback/default account.

| Key | Consumer | Purpose | Required | Secret |
|---|---|---|---|---|
| `IMAP_HOST` | `config/imap.php:40` | IMAP server host | Required if used | N |
| `IMAP_PORT` | `config/imap.php:41` | IMAP port | Optional (default 993) | N |
| `IMAP_PROTOCOL` | `config/imap.php:42` | imap/pop3/nntp | Optional | N |
| `IMAP_ENCRYPTION` | `config/imap.php:43` | ssl/tls/none | Optional | N |
| `IMAP_VALIDATE_CERT` | `config/imap.php:44` | TLS cert validation | Optional (default true) | N |
| `IMAP_USERNAME` | `config/imap.php:45` | IMAP auth username | Required if used | N |
| `IMAP_PASSWORD` | `config/imap.php:46` | IMAP auth password | Required if used | **Y** |
| `IMAP_DEFAULT_ACCOUNT` | `config/imap.php:26` | Default account name | Optional | N |

## Mail

| Key | Consumer | Purpose | Required | Secret |
|---|---|---|---|---|
| `MAIL_MAILER` | `config/mail.php:17`, `SettingsController.php` | Transport driver | Required (default `log`) | N |
| `MAIL_HOST` | `config/mail.php:44` | SMTP host | Required for real delivery | N |
| `MAIL_PORT` | `config/mail.php:45` | SMTP port | Optional (default 2525) | N |
| `MAIL_USERNAME` | `config/mail.php:47` | SMTP auth username | Optional | N |
| `MAIL_PASSWORD` | `config/mail.php:47` | SMTP auth password | Optional | **Y** |
| `MAIL_SCHEME` | `config/mail.php:42` | tls/ssl — the actual encryption knob | Optional | N |
| `MAIL_FROM_ADDRESS` | `config/mail.php:112` | Default from-address | Required for outbound branding | N |
| `MAIL_FROM_NAME` | `config/mail.php:113` | Default from-name | Optional (default "Example") | N |
| `MAIL_ENCRYPTION` | Written by `SettingsController.php` Settings UI, never read back by `config/mail.php` (which uses `MAIL_SCHEME` instead) | — | **Needs review** — UI writes a key the app doesn't consume | N |

## Reverb (WebSockets) / Vite

| Key | Consumer | Purpose | Required | Secret |
|---|---|---|---|---|
| `REVERB_APP_ID` | `config/reverb.php`, `config/broadcasting.php` | Reverb app identifier | Required for broadcasting | N |
| `REVERB_APP_KEY` | same; also feeds `VITE_REVERB_APP_KEY` (frontend build-time) | Reverb app key (client auth) — **must stay in `.env`**, not `.env.secrets`, or `npm run build` won't see it | Required | N |
| `REVERB_APP_SECRET` | same | Server-side signing secret | Required | **Y** |
| `REVERB_HOST` / `REVERB_PORT` / `REVERB_SCHEME` | `config/reverb.php` | Public hostname/port/scheme clients connect to | Required | N |
| `REVERB_SERVER_HOST` / `REVERB_SERVER_PORT` / `REVERB_SERVER_PATH` | `config/reverb.php:32-34` | Bind address for the Reverb server process itself | Required for server process | N |
| `VITE_REVERB_APP_KEY` / `VITE_REVERB_HOST` / `VITE_REVERB_PORT` / `VITE_REVERB_SCHEME` | `resources/js/echo.js`, `Modules/ClientPortal/resources/js/portal-websocket.js` | Client-side Echo/Reverb connection config, baked in at Vite build time | Required for realtime UI (degrades gracefully if missing — `echo.js` explicitly checks) | N |
| `VITE_APP_NAME` | none found | — | **Needs review** — vestigial Laravel scaffold default; app name is actually driven server-side via `APP_NAME`/`config('app.name')` in Blade | N |

---

## Removed 2026-08 (dead code — zero consumers anywhere)

An entire "2026-06 strategic rollback" (commit `6c686a2f8`) removed `Modules/Payment`, `Modules/PIB`, `Modules/ContractManager`, `Modules/EmailMigration`, and `Modules/DeploymentManager`. These 26 keys configured those modules and have zero remaining consumers in `app/`, `Modules/`, or `config/`:

- **Payment/Helcim (21):** `HELCIM_ACCOUNT_ID`, `HELCIM_API_TOKEN`, `HELCIM_WEBHOOK_SECRET`, `PAYMENT_ALLOW_MULTIPLE_METHODS`, `PAYMENT_AUTO_PROCESS_ENABLED`, `PAYMENT_AUTO_RECONCILE`, `PAYMENT_CARD_EXPIRING_DAYS`, `PAYMENT_DAYS_BEFORE_DUE`, `PAYMENT_EXPIRE_CHECK_ENABLED`, `PAYMENT_LOG_ALL_REQUESTS`, `PAYMENT_MAX_RETRY_ATTEMPTS`, `PAYMENT_NOTIFY_FAILED`, `PAYMENT_NOTIFY_SUCCESS`, `PAYMENT_REFUNDS_ENABLED`, `PAYMENT_REFUND_REQUIRE_APPROVAL`, `PAYMENT_REFUND_WINDOW_DAYS`, `PAYMENT_REQUIRE_DEFAULT`, `PAYMENT_REQUIRE_MANUAL_REVIEW`, `PAYMENT_REQUIRE_SIGNATURE`, `PAYMENT_RETRY_FAILED_HOURS`, `PAYMENT_SEND_RECEIPTS`
- **EmailMigration (1):** `EMAIL_MIGRATION_STUCK_THRESHOLD`
- **DeploymentManager/TSDM (4):** `TSDM_GITHUB_STATIC_PAT`, `TSDM_GIT_PROVIDER`, `TSDM_IP_PINNING`, `TSDM_OTAC_TTL_HOURS`

There is currently **no payment gateway of any kind** wired into the app — `Modules/SoftwareSubscriptions` is the only remaining billing-adjacent module and has no gateway dependency. Confirmed by `database/migrations/2026_06_12_000001_prune_deleted_module_tables.php` (drops the corresponding tables) and `tests/Architecture/BillingPaymentTypeCoverageGuardTest.php` (explicitly documents the rollback).

## Needs review (declared, but nothing reads the resulting config value)

Different failure mode than the removed-module keys above — these still have a live `env()` declaration in some `config/*.php` file, just nothing downstream reads the config key it populates. Removing them means also touching application code, not just deployment tooling, so they're flagged here rather than deleted:

`ACTION1_API_RATE_LIMIT`, `ACTION1_DEBUG`, `ACTION1_SYNC_INTERVAL_HOURS`, `CLIENT_PORTAL_WEBSOCKET_ENABLED`, `CLIENT_SESSION_LIFETIME`, `GOOGLE_CUSTOMER_ID`, `GOOGLE_PUSH_NOTIFICATION_URL`, `GOOGLE_WEBHOOK_SECRET`, `MAIL_ENCRYPTION`, `VITE_APP_NAME`.

(`GOOGLE_API_RATE_LIMIT` is *not* in this list — one of its two config declarations is dead, but the env var itself is live via a separate `Modules/GoogleAdmin/Config/google.php` path.)
