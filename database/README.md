# Delbros Portal — database scripts (MySQL 8 / Amazon RDS)

Status: **draft for verification**. Written from the portal frontend (mock API v21). Not yet executed against a MySQL server.

## Run order
| # | File | Contents |
|---|---|---|
| 1 | `01_schema.sql` | Database `delbros_portal`, 71 tables, indexes, audit-protection triggers |
| 2 | `02_core.sql` | Shared functions/procedures: numbering, audit hash chain, caller check, notifications, outbox, workflow, BR-01 gate, entitlement, BR-14, BR-15 |
| 3 | `03_sp_auth.sql` | Sign-in, OTP, lockout, password change/reset, portal access requests |
| 4 | `04_sp_portal_common.sql` | Reference data, file metadata (files stored on the server), dashboard, notifications, feedback, return request |
| 5 | `05_sp_ewa.sql` | EWA options, list, details, create, cancel, extension, resend email |
| 6 | `06_sp_rescue.sql` | Rescue options, list, details, create, cancel |
| 7 | `07_sp_billing.sql` | Invoices, acknowledge, proof of payment, dispute, SOA, email SOA, hire coverage |
| 8 | `08_sp_ewallet_bond.sql` | E-wallet ledger, top-ups, cash bonds, refund preview, withdrawal |
| 9 | `09_sp_contracts.sql` | Contracts page, contract change requests |
| 10 | `10_sp_vendor.sql` | Vendor portal data, invoice upload |
| 11 | `11_sp_jobs.sql` | Scheduled jobs, email outbox worker |
| 12 | `20_seed_reference.sql` | Roles, settings, equipment types, branches (demo list — replace) |
| 12a | `30_sample_data.sql` | **Development / UAT only — never production.** Dummy data for every portal screen (see *Sample data* below) |
| 13 | `99_security.sql` | Least-privilege DB accounts (EXECUTE only for the API) |

## Sample data (development / UAT only)
`30_sample_data.sql` is **generated** by `sample/generate-sample-data.js` (`npm run sample-data`) because personal data must be
encrypted with the backend keys: the file is **tied to `PII_ENCRYPTION_KEY` / `PII_HASH_KEY` in `App/.env`** — regenerate it whenever
those keys change. Run it once, on an empty database, after `20_seed_reference.sql`. Dates are relative to the day it runs (Manila).
The generator also runs `sample/check-columns.js` (tables, columns, ENUM values, NOT NULL, lengths, primary keys, foreign-key order).
No separate `25_sample_masters.sql` is needed: the extra master rows (rate cards, parts, notification rules, staff users, support
contacts and the default Account Executive setting) are in the generated file.

It contains: 16 Delbros staff (Account Executives, Credit & Collection, Branch Generalists, Rescue, Treasury, Accounting, Procurement),
8 clients, 3 vendors, 13 portal users, 8 contracts with rates / rate history / requests, 32 chassis, 16 EWAs (Used, Active, Extension
Pending, Expired, Cancelled), gate passes OUT/IN with damage, rescues (completed with charges, dispatched, cancelled), 12 invoices
(paid, partially paid + overdue, unpaid, awaiting acknowledgment, repair, cancelled), receipts, memos, proof of payment, disputes,
e-wallets and top-ups, cash bonds with a refunded and a pending withdrawal, POs / receiving / vendor invoices, notifications, feedback,
an email delivery log (all Sent — nothing is queued for the worker) and number sequences set past the sample numbers.
Not included: audit-log rows (the hash chain starts at its genesis row), sessions, sign-in codes and reset links.

**Demo logins — password `Demo@2026` for every account** (the same accounts as the frontend demo box):

| Portal | Email | What it shows |
|---|---|---|
| Client | `client@abclogistics.ph` | ABC Logistics — data on every screen: 6 units on hire (one under rescue, one with a return requested), EWAs in every status, invoices (overdue / unpaid / awaiting acknowledgment / repair / paid / cancelled), e-wallet *near minimum*, cash bonds (held, withdrawal pending, refunded), 2 contracts (one expiring in 35 days with a renewal request) |
| Client | `billing@abclogistics.ph` | Second active ABC user (submitted PA-000002 and a feedback) |
| Client | `client@pacificmovers.ph` | Pacific Movers — **on hold** (invoice > 30 days past due): signs in, EWA and rescue blocked; e-wallet negative |
| Client | `ops@southernhaulers.ph` | Southern Haulers (CDO, Nakamura billing) — **Allow Online = No**: EWA restricted; no e-wallet yet |
| Client | `rico@northstar.ph` | Northstar — **not accredited** (sign-in refused, accreditation at Credit & Collection) |
| Client | `tess@islandlink.ph` | Islandlink — **access request pending** (PAR-000004; status page works with this email) |
| Client | `j.cruz@abclogistics.ph` | **Inactive** portal user |
| Client | `dispatch@visayasfreight.ph` | **Locked** for 25 minutes after the script runs (5 failed sign-ins) |
| Client | `finance@baysidehaulage.ph` | Bayside — contract **ended**, nothing owed, cash bond ₱25,000 **refundable** (withdrawal) |
| Client | `ops@metrocontainer.ph` | Metro Container — e-wallet **below minimum**: rescue accepted with a warning |
| Vendor | `vendor@tirepro.ph` | Tire Pro Supply — POs (partially received / received / issued), receiving reports, invoices Paid / Rejected / resubmitted Under Review |
| Vendor | `sales@luzonbrake.ph` | **Not accredited** supplier |
| Vendor | `orders@metropaint.ph` | **Inactive** supplier |

Reviewer's one-click approval link for PAR-000004 (development only):
`<portal>/access-approval/sample0approval0token0islandlink0000000000000000000000000000000001`

Sample files (proofs, photos, vendor invoices): the generator also writes placeholder PDF / JPG files to `database/sample/files/` —
copy that folder's contents into `FILE_DIR` (`uploads/` locally, `/var/delbros/uploads` on the server) so their downloads work.

## RDS parameter group (before running)
- `time_zone = +00:00` (all timestamps UTC; Manila dates computed as UTC+8)
- `log_bin_trust_function_creators = 1` (needed to create the stored functions)
- `require_secure_transport = ON`

## Conventions
- Every procedure called by the API takes `p_user_id` from the server session and checks the portal (`sp_ctx_user`): **refuse unless the realm is explicitly allowed**.
- Write procedures return `o_err_code / o_err_msg / o_err_fields` (NULL code = success); the controller maps codes to HTTP status (see `docs/API_Sheet.xlsx`, sheet *Error codes*).
- Node handles: password hashing (bcrypt), OTP / reset / approval tokens (only SHA-256 hashes stored), file storage on the server and signed download links, sending email (SES) from `message_outbox`.
- Money `DECIMAL(15,2)`; timestamps `DATETIME(3)` UTC; business dates `DATE` (Manila).

## PDPA — personal data encryption
- Personal data columns (names, emails, phones, TINs, driver names / licences, scene contacts, branch managers, email addresses)
  hold **AES-256-GCM ciphertext** (`enc:v1:<iv>:<tag>:<data>`) written by the Node backend. The key is only in the backend `.env`.
- Lookups use **HMAC-SHA256 blind indexes** computed by the backend: `users.email_hash` (sign-in), `*.email_hash` / `*.tin_hash`
  (one email / one TIN per company), `ewas.driver_license_hash` (drivers used before, licence search).
- Procedures may store, copy and return ciphertext, but never concatenate, compare or search it. Format checks on personal
  fields (phone, licence) are done in Node before encryption. Notification and email texts contain no personal data.
- Portal user IDs are generated (`U-000001`), never the email address.
- Losing the key = losing the data: the key is in the backend `App/.env`; keep an offline copy (company password vault), separate from the database backups.
