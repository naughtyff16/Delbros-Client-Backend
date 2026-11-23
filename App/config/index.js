// All configuration comes from App/.env (or real environment variables on EC2). Nothing secret is hard-coded.
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

const env = process.env;
const required = (key) => {
  const v = env[key];
  if (v === undefined || v === '') throw new Error(`Missing environment variable ${key} (see App/.env.example)`);
  return v;
};
const bool = (v, d = false) => (v === undefined || v === '' ? d : ['1', 'true', 'yes'].includes(String(v).toLowerCase()));
const int = (v, d) => (v === undefined || v === '' ? d : parseInt(v, 10));

module.exports = {
  env: env.NODE_ENV || 'development',
  isProduction: env.NODE_ENV === 'production',
  port: int(env.PORT, 4000),
  apiPrefix: '/api/v1',
  trustProxy: int(env.TRUST_PROXY, 0),
  portalUrl: (env.PORTAL_URL || '').replace(/\/$/, ''),
  corsOrigins: (env.CORS_ORIGINS || '').split(',').map((s) => s.trim()).filter(Boolean),

  db: {
    host: required('DB_HOST'),
    port: int(env.DB_PORT, 3306),
    database: required('DB_NAME'),
    user: required('DB_USER'),
    password: required('DB_PASSWORD'),
    ssl: bool(env.DB_SSL, true),
    poolSize: int(env.DB_POOL_SIZE, 10),
  },
  sessionDb: {
    user: env.DB_SESSION_USER || env.DB_USER,
    password: env.DB_SESSION_PASSWORD || env.DB_PASSWORD,
  },

  session: {
    secret: required('SESSION_SECRET'),
    cookieName: env.SESSION_COOKIE_NAME || 'dlb.sid',
    idleMinutes: int(env.SESSION_IDLE_MINUTES, 15),
    cookieSecure: bool(env.COOKIE_SECURE, true),
    sameSite: env.COOKIE_SAMESITE || 'lax',
    // mysql = sessions table (production); memory = automated tests only
    store: env.SESSION_STORE === 'memory' ? 'memory' : 'mysql',
  },

  // DEVELOPMENT ONLY: return the emailed sign-in code / reset token / approval link in the API response so the portal's
  // demo box can show them without a mail server. Always off when NODE_ENV=production.
  devExposeCodes: env.NODE_ENV !== 'production' && bool(env.DEV_EXPOSE_CODES, false),

  // PDPA — personal data encryption. Keys stay in the backend; the database only ever sees ciphertext.
  crypto: {
    keyVersion: env.PII_KEY_VERSION || 'v1',
    encryptionKey: required('PII_ENCRYPTION_KEY'),
    hashKey: required('PII_HASH_KEY'),
    oldKeyVersion: env.PII_OLD_KEY_VERSION || '',
    oldEncryptionKey: env.PII_OLD_ENCRYPTION_KEY || '',
  },

  bcryptRounds: int(env.BCRYPT_ROUNDS, 12),

  // Amazon SES (email). On EC2 the SDK takes credentials from the instance IAM role — no AWS keys in .env.
  aws: {
    region: env.AWS_REGION || 'ap-southeast-1',
    sesFrom: env.SES_FROM_ADDRESS || '',
  },

  // Uploaded files are stored on this server: FILE_DIR/<purpose>/<yyyy-mm>/<uuid>.<ext> (absolute path, or relative to the project).
  // Keep FILE_DIR outside the web root and include it in the server backups (EBS snapshots).
  files: {
    dir: path.resolve(__dirname, '..', '..', env.FILE_DIR || 'uploads'),
    maxMb: 5,
    linkSeconds: int(env.FILE_LINK_SECONDS, 300),   // lifetime of a signed download link
  },
  jobs: { enabled: bool(env.RUN_JOBS, false) },

  // log4js — files in LOG_DIR (relative to the project folder): app.log (info and above), error.log (errors only)
  log: {
    level: env.LOG_LEVEL || 'info',
    dir: env.LOG_DIR || 'logs',
    // new file every day AND whenever a file reaches maxSizeMb (2–5 MB); maxFiles = rolled files kept before the oldest is deleted
    maxSizeMb: Math.min(5, Math.max(2, Number(env.LOG_MAX_SIZE_MB) || 5)),
    maxFiles: int(env.LOG_MAX_FILES, 100),
    maxErrorFiles: int(env.LOG_MAX_ERROR_FILES, 100),
    slowProcedureMs: int(env.LOG_SLOW_PROCEDURE_MS, 2000),
  },
};
