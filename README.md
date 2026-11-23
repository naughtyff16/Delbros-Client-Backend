# Delbros Portal — backend (Node.js + Express + MySQL)

API for the Client & Vendor Portal frontend. All database reads and writes go through the stored procedures in
`database/`; the endpoints are listed in `docs/API_Sheet.xlsx`.

## Folder structure
```
server.js                  start the API (and the background jobs when RUN_JOBS=true)
App/
  .env                     all environment variables (never commit; template: .env.example)
  app.js                   Express app: helmet, CORS, JSON, MySQL sessions, routes, error handler
  config/                  configuration
    index.js               reads App/.env
    db.js                  MySQL pool + session-store settings
    aws.js                 Amazon SES client (email)
    releaseContacts.json   support contacts and pay-to bank accounts per billing entity
  controllers/             all logic
    cryptoController.js    PDPA encryption / decryption (AES-256-GCM), blind index (HMAC), passwords (bcrypt)
    authController.js      sign-in, email code, session, CSRF, password change / reset
    accessController.js    request portal access, status, one-click approval
    fileController.js      uploads stored on the server (FILE_DIR), content check, signed download links
    portalController.js    reference data, dashboard, notifications, feedback, returns
    ewaController.js  rescueController.js  billingController.js  ewalletController.js
    contractController.js  vendorController.js
    mailController.js      email sending (SES), outbox worker
    jobController.js       timers: EWA expiry, auto hold, contract expiry, email outbox
    errorController.js     error format, HTTP status per error code, response (decrypts personal data)
    helpers.js             input format checks, paging
  models/                  database access — one file per module; procedure.js runs a stored procedure
  routes/                  URL → controller (index.js mounts everything under /api/v1)
database/                  MySQL scripts (run in file-name order); sample/ = sample-data generator (30_sample_data.sql)
test/                      backend unit tests (npm test)
deploy/                    EC2 deployment guide (DEPLOY.md), Nginx site, pm2 process file
docs/API_Sheet.xlsx        API sheet
```

## PDPA — how personal data is protected
- **Encrypted in the backend, before it reaches MySQL** (`controllers/cryptoController.js`): names, emails, phones, TINs,
  driver names and licences, rescue scene contacts, email addresses. AES-256-GCM with a random IV per value; the stored
  value looks like `enc:v1:<iv>:<tag>:<data>`. A changed value fails to decrypt (tamper detection).
- **The key is only in the backend** (`PII_ENCRYPTION_KEY` in `App/.env`, file permissions 600). The database, its backups and
  anyone with database access see only ciphertext.
- **Decrypted only for the response** (`respond()` in `errorController.js`) to the signed-in user, after the stored procedure has
  checked that the record belongs to them.
- **Lookups without decrypting**: blind indexes (`HMAC-SHA256` with a second key `PII_HASH_KEY`) for sign-in email, "one email /
  one TIN per company" and driver-licence search.
- Passwords: bcrypt (one-way). Sign-in codes and reset / approval tokens: only their SHA-256 is stored.
- Emails and notifications contain no personal data in their text; the outbox stores the address encrypted and the sender
  decrypts it only when sending.
- Key rotation: set the new key as `PII_ENCRYPTION_KEY` with a new `PII_KEY_VERSION`, keep the old one in
  `PII_OLD_ENCRYPTION_KEY` / `PII_OLD_KEY_VERSION` so existing rows still decrypt; re-encrypt rows with a one-off script.
- **Back up the keys separately from the database.** Without `PII_ENCRYPTION_KEY` the personal data cannot be recovered.

## Logs (log4js)
- Files in `logs/` (setting `LOG_DIR`): **`app.log`** = info, warnings and errors; **`error.log`** = errors only.
- **Rolled by date and by size**: a new file starts at midnight **and** whenever the current file reaches `LOG_MAX_SIZE_MB`
  (allowed 2–5, default 5). Rolled files are named by date and part number and compressed:
  `app.2026-11-19.1.log.gz`, `app.2026-11-19.2.log.gz`, … The oldest are deleted once there are more than `LOG_MAX_FILES` /
  `LOG_MAX_ERROR_FILES` (100 each ≈ up to 500 MB uncompressed per log). In development the same lines also go to the console.
  Configuration: `App/config/logger.js`.
- What is logged: one line per request (request id, method, path, status, time, internal user id); sign-in results and lockouts;
  password changes and resets; every created record (EWA, rescue, top-up, proof of payment, dispute, withdrawal, contract request,
  return request, vendor invoice, access request); uploads; emails sent / failed; background-job results; slow or failed stored
  procedures; unexpected errors with their stack (the browser only gets the request id as reference).
- **PDPA — never logged**: request bodies, query strings, names, emails, phones, TINs, licences, addresses, passwords, sign-in codes,
  tokens, ciphertext and client IP addresses. Code logs only internal ids (U-000012, EU-000781, TU-000005…), and every line also passes
  through a filter (`sanitize()` in `logger.js`) that replaces anything looking like an email, phone, TIN, licence, hash or ciphertext
  with `[email]`, `[phone]`, `[number]`, `[licence]`, `[hash]`, `[encrypted]` — including inside MySQL error messages.
- On the EC2 server: `LOG_DIR=/var/delbros/logs` (included in the daily EBS snapshot).

## Run locally (with sample data)
1. MySQL 8 (local, port 3306): run `database/01_schema.sql` … `11_sp_jobs.sql`, `20_seed_reference.sql`, then `30_sample_data.sql`
   (sample data — development/UAT only; logins and what each account shows: `database/README.md`). Create the DB accounts with
   `99_security.sql` (locally drop `REQUIRE SSL` since `DB_SSL=false`) and put their passwords in `App/.env`.
   `30_sample_data.sql` contains data encrypted with the keys in `App/.env` — after changing the keys run `npm run sample-data`.
2. `npm install`, then `npm run dev` → http://localhost:4000/api/v1/health
3. Frontend (Client_Portal_Frontend): `public/app-config.json` → `"apiBaseUrl": "http://localhost:4000/api/v1"`, then `npm run dev`
   → http://localhost:5174. Sign in with e.g. `client@abclogistics.ph` / `Demo@2026`; the email sign-in code appears in the demo box
   because `DEV_EXPOSE_CODES=true` (development only). Set `apiBaseUrl` to `""` to go back to the in-browser mock.
4. Development: `DEV_EXPOSE_CODES=true` (ignored when `NODE_ENV=production`) and a blank `SES_FROM_ADDRESS` (emails logged by
   subject, not sent). Uploads go to `FILE_DIR` (`uploads/`); copy `database/sample/files/*` there for the sample documents.

Browser flow: `GET /api/v1/auth/csrf` first, then send `X-CSRF-Token` on every POST/PUT, with cookies (`credentials: 'include'`).

## Tests
- Backend: `npm test` — 52 unit tests (node:test) on the real Express routes and controllers with the stored-procedure models stubbed
  (no database needed): auth, access requests, files, portal, contracts, vendor, EWA, rescue, billing, e-wallet.
- Frontend: `npm test` — the portal API client against a scripted fetch (URLs, CSRF, error mapping, shapes the screens read) plus the
  existing mock tests; `remote.test.ts` fails if a portal call has no backend implementation.
- End to end (frontend client → backend → MySQL with the sample data): start the backend, then in Client_Portal_Frontend
  `LIVE_API_URL=http://localhost:4000/api/v1 npx vitest run src/lib/api-client/remote/live.integration.test.ts` (11 tests: sign-in
  refusals, one-time code, dashboard, lists, finance, create/cancel EWA, validation fields, feedback, sign-out, hold client, vendor).

## Deploy (AWS: EC2 + RDS + SES only) — same setup for UAT and Production
Step by step: **`deploy/DEPLOY.md`** (Nginx site: `deploy/nginx-delbros-portal.conf`, pm2: `deploy/ecosystem.config.js`).
- **EC2** (one per environment): Nginx serves the portal build and forwards `/api` to Node (pm2) on the same domain; HTTPS with a
  Let's Encrypt certificate. Uploaded files in `FILE_DIR`, logs in `LOG_DIR`, configuration and keys in `App/.env` (chmod 600).
  IAM instance role: `ses:SendEmail` only. Daily EBS snapshots (files and logs are on this disk).
- **RDS for MySQL 8**: private, encrypted, automated backups; `time_zone=+00:00`, `log_bin_trust_function_creators=1`,
  `require_secure_transport=ON`. Only the EC2 security group can reach port 3306.
- **SES**: verified domain (DKIM/SPF/DMARC), production access for Production.
- Not used: S3, GuardDuty, SMS, Secrets Manager, load balancer, Amplify, CloudWatch. Uploads are checked for real PDF / JPG / PNG
  content and size, not virus-scanned.

## Not built yet (simple version)
- Emails are plain text; the SOA PDF attachment and the EWA full-detail email layout are not rendered yet.
- Staff-app endpoints (approvals, gate, billing run, Treasury confirmation) are outside this backend.
- Uploads are capped at 5 MB (the vendor screen says 10 MB) and accept PDF/JPG/PNG (the rescue photo picker also offers HEIC).
- No SMS: urgent rescues alert the dispatchers by email (subject starts with URGENT).
