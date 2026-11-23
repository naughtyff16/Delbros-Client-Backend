# Delbros portal — deployment on AWS (EC2 + RDS + SES)

The same setup is used for **UAT** and **Production**; only `App/.env`, the domain and the data differ.

```
https://portal.delbros.com  (UAT: https://uat-portal.delbros.com)
        │
        ▼
  EC2 (Amazon Linux 2023)
   ├─ Nginx :443  ── /            → portal build   /var/www/delbros-portal
   │              └─ /api/        → Node backend   127.0.0.1:4000 (pm2)
   ├─ /var/delbros/uploads        uploaded files (FILE_DIR)
   ├─ /var/delbros/logs           app.log / error.log, rolled by date and size (LOG_DIR)
   └─ /opt/delbros/backend/App/.env   all configuration and keys
        │                                   │
        ▼                                   ▼
  RDS for MySQL 8 (private)            Amazon SES (email)
```

## 1. AWS resources (per environment)

| Resource | Settings |
|---|---|
| **VPC** | Default VPC is enough. EC2 in a public subnet; RDS in private subnets (DB subnet group). |
| **EC2** | Amazon Linux 2023, t3.small (UAT) / t3.medium (Prod) to start; 30 GB gp3 **encrypted** EBS; Elastic IP. |
| **EC2 IAM role** | `ses:SendEmail` (SES) and `AmazonSSMManagedInstanceCore` (Session Manager login, no SSH key needed). No other AWS access. |
| **Security group – EC2** | Inbound 80, 443 from anywhere. SSH 22 only from the office IP (or none, using Session Manager). |
| **RDS for MySQL 8.0** | Private (no public access), encrypted, automated backups 7–35 days, Multi-AZ for Production. Parameter group: `time_zone=+00:00`, `log_bin_trust_function_creators=1`, `require_secure_transport=ON`. |
| **Security group – RDS** | Inbound 3306 **only from the EC2 security group**. |
| **SES** | Verify the domain `delbros.com` (DKIM, SPF, DMARC). Request production access (leave the sandbox) for Production; UAT may stay in the sandbox (sends only to verified addresses). |
| **DNS** | `portal.delbros.com` (UAT `uat-portal.delbros.com`) → A record → the Elastic IP. |
| **Backups of the server disk** | AWS Backup or Data Lifecycle Manager: daily EBS snapshot, keep 30 days. **Uploads and logs live only on this disk** — RDS backups do not include them. |

## 2. Database (RDS)
From a machine that can reach RDS (e.g. the EC2 server: `sudo dnf install -y mariadb105`):
```
mysql -h <rds-endpoint> -u admin -p --ssl < 01_schema.sql      # then 02 … 11, 20_seed_reference.sql
mysql -h <rds-endpoint> -u admin -p --ssl < 99_security.sql    # edit the passwords first (CHANGE_ME_…)
```
- Replace the demo branch list in `20_seed_reference.sql` with the real branches before loading.
- **UAT only (optional):** sample data — on the UAT server run `npm run sample-data` with the **UAT** keys in `App/.env`, load
  `30_sample_data.sql`, and copy `database/sample/files/*` into `/var/delbros/uploads/`. **Never load sample data in Production.**

## 3. Server software (once)
```
sudo dnf install -y nginx git
curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash - && sudo dnf install -y nodejs
sudo npm install -g pm2
sudo dnf install -y certbot python3-certbot-nginx
sudo useradd --system --home /opt/delbros delbros
sudo mkdir -p /opt/delbros /var/delbros/uploads /var/delbros/logs /var/www/delbros-portal
sudo chown -R delbros:delbros /opt/delbros /var/delbros
```

## 4. Backend
```
# copy Client_Portal_Backend to /opt/delbros/backend (without node_modules, logs, uploads)
cd /opt/delbros/backend && npm ci --omit=dev
cp App/.env.example App/.env && nano App/.env     # fill in (see below)
chmod 600 App/.env
sudo -u delbros pm2 start deploy/ecosystem.config.js && sudo -u delbros pm2 save
sudo env PATH=$PATH pm2 startup systemd -u delbros --hp /opt/delbros
curl http://127.0.0.1:4000/api/v1/health          # {"status":"ok"}
```
`App/.env` values that differ per environment:

| Variable | UAT | Production |
|---|---|---|
| `NODE_ENV` | `production` | `production` |
| `PORTAL_URL`, `CORS_ORIGINS` | `https://uat-portal.delbros.com` | `https://portal.delbros.com` |
| `DB_HOST`, `DB_PASSWORD`, `DB_SESSION_PASSWORD` | UAT RDS | Production RDS |
| `SESSION_SECRET`, `PII_ENCRYPTION_KEY`, `PII_HASH_KEY` | own keys (`npm run gen-keys`) | **own keys — never the UAT ones** |
| `SES_FROM_ADDRESS` | `no-reply@delbros.com` | `no-reply@delbros.com` |
| `DEV_EXPOSE_CODES` | `false` | `false` (ignored in production anyway) |

Same in both: `TRUST_PROXY=1`, `COOKIE_SECURE=true`, `COOKIE_SAMESITE=lax`, `DB_SSL=true`, `FILE_DIR=/var/delbros/uploads`,
`LOG_DIR=/var/delbros/logs`, `RUN_JOBS=true`, `AWS_REGION=ap-southeast-1`.

**Keys:** keep an offline copy of each environment's `PII_ENCRYPTION_KEY` and `PII_HASH_KEY` (e.g. in the company password
vault), separate from the database backups. Without them the personal data in that database cannot be read.

## 5. Frontend
```
# on a build machine: Client_Portal_Frontend
npm ci && npm run package:ec2          # → ../deploy/delbros-portal-web-<version>.zip
# on the server:
sudo unzip -o delbros-portal-web-<version>.zip -d /var/www/delbros-portal
sudo nano /var/www/delbros-portal/app-config.json   # "apiBaseUrl": "/api/v1", "showDemoLogins": false (UAT may use true), "showChangeLog": false
```

## 6. Nginx and HTTPS
```
sudo cp /opt/delbros/backend/deploy/nginx-delbros-portal.conf /etc/nginx/conf.d/delbros-portal.conf   # set the domain
sudo certbot --nginx -d portal.delbros.com      # free certificate, renews automatically
sudo nginx -t && sudo systemctl enable --now nginx && sudo systemctl reload nginx
```

## 7. Check
- `https://portal.delbros.com` opens the sign-in page; `https://portal.delbros.com/api/v1/health` → `{"status":"ok"}`.
- Sign in, upload a proof of payment, open a document; an email arrives (SES).
- `/var/delbros/logs/app.log` has request lines and **no personal data**; `error.log` is empty.

## Updates
- Backend: copy the new files, `npm ci --omit=dev`, run any changed SQL files (`03`–`11` are safe to re-run: they drop and
  recreate procedures), `pm2 reload delbros-portal-api`.
- Frontend: unzip the new build into `/var/www/delbros-portal` (keep `app-config.json`).

## Limits of this setup (accepted)
- One server per environment: no automatic failover; a restore from snapshot + RDS backup takes minutes to hours.
- Uploaded files are checked for type and size (real PDF / JPG / PNG content), **not virus-scanned**.
- Logs are on the server only (rolled by date and size, 100 files per log); read them with Session Manager / SSH.
