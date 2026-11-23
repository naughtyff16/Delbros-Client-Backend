// PDPA — encryption / decryption of personal data, blind indexes, token hashing and passwords.
//
// Personal data is encrypted HERE, before it reaches MySQL, with AES-256-GCM (authenticated encryption):
//   stored value = "enc:<keyVersion>:<iv base64url>:<auth tag base64url>:<ciphertext base64url>"
// The key lives only in the backend (App/.env → PII_ENCRYPTION_KEY). The database never sees it.
//
// Encrypted values cannot be searched, so values the database must look up (email at sign-in, TIN, driver
// licence) also get a blind index: HMAC-SHA256 with a SEPARATE key (PII_HASH_KEY) over a normalised value.
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const config = require('../config');

const PREFIX = 'enc:';
const ALGO = 'aes-256-gcm';

function loadKey(b64, name) {
  const key = Buffer.from(b64, 'base64');
  if (key.length !== 32) throw new Error(`${name} must be 32 bytes, base64-encoded (run: npm run gen-keys)`);
  return key;
}
const keys = { [config.crypto.keyVersion]: loadKey(config.crypto.encryptionKey, 'PII_ENCRYPTION_KEY') };
if (config.crypto.oldKeyVersion && config.crypto.oldEncryptionKey) keys[config.crypto.oldKeyVersion] = loadKey(config.crypto.oldEncryptionKey, 'PII_OLD_ENCRYPTION_KEY');
const hashKey = loadKey(config.crypto.hashKey, 'PII_HASH_KEY');

/** Encrypt one personal-data value. Empty / null → null (nothing is stored). */
function encrypt(plain) {
  if (plain === undefined || plain === null) return null;
  const text = String(plain);
  if (text === '') return null;
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv(ALGO, keys[config.crypto.keyVersion], iv);
  const data = Buffer.concat([cipher.update(text, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `${PREFIX}${config.crypto.keyVersion}:${iv.toString('base64url')}:${tag.toString('base64url')}:${data.toString('base64url')}`;
}

const isEncrypted = (v) => typeof v === 'string' && v.startsWith(PREFIX);

/** Decrypt one value. Plain values pass through unchanged (e.g. a setting value that was never encrypted). */
function decrypt(value) {
  if (!isEncrypted(value)) return value;
  const [, version, ivB64, tagB64, dataB64] = value.split(':');
  const key = keys[version];
  if (!key) throw new Error(`No encryption key for version ${version}`);
  const decipher = crypto.createDecipheriv(ALGO, key, Buffer.from(ivB64, 'base64url'));
  decipher.setAuthTag(Buffer.from(tagB64, 'base64url'));
  return Buffer.concat([decipher.update(Buffer.from(dataB64, 'base64url')), decipher.final()]).toString('utf8');
}

/** Decrypt every encrypted string inside a procedure result (rows, nested JSON objects, arrays). */
function decryptDeep(value) {
  if (isEncrypted(value)) {
    try { return decrypt(value); } catch { return '[unreadable]'; } // wrong / missing key — never crash a whole response
  }
  if (Array.isArray(value)) return value.map(decryptDeep);
  if (value && typeof value === 'object' && !(value instanceof Date) && !Buffer.isBuffer(value)) {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = decryptDeep(v);
    return out;
  }
  return value;
}

// Normalisation for blind indexes: the same person always gives the same hash.
const normalise = {
  email: (v) => String(v).trim().toLowerCase(),
  tin: (v) => String(v).replace(/\D/g, '').slice(0, 9),            // first 9 digits — the BIR branch code is ignored
  licence: (v) => String(v).trim().toUpperCase().replace(/\s+/g, ''),
};
/** HMAC-SHA256 blind index (64 hex chars) for lookups and uniqueness checks. */
function blindIndex(kind, value) {
  if (value === undefined || value === null || String(value).trim() === '') return null;
  const n = normalise[kind](value);
  if (!n) return null;
  return crypto.createHmac('sha256', hashKey).update(`${kind}:${n}`).digest('hex');
}

/** SHA-256 of a token / OTP code — only the hash goes to the database. */
const sha256 = (v) => crypto.createHash('sha256').update(String(v)).digest('hex');
const randomToken = (bytes = 24) => crypto.randomBytes(bytes).toString('hex');
const randomDigits = (n = 6) => Array.from(crypto.randomBytes(n), (b) => String(b % 10)).join('');
const maskEmail = (email) => {
  const e = String(email || '');
  const at = e.indexOf('@');
  return at > 1 ? `${e[0]}***${e.slice(at)}` : '***';
};

// Passwords: bcrypt (one-way hash, never decryptable).
const hashPassword = (plain) => bcrypt.hash(plain, config.bcryptRounds);
const verifyPassword = (plain, hash) => (hash ? bcrypt.compare(String(plain || ''), hash) : Promise.resolve(false));
// Used when the account does not exist, so a failed sign-in takes the same time either way.
const DUMMY_HASH = bcrypt.hashSync('timing-equaliser', 10);

module.exports = { encrypt, decrypt, decryptDeep, isEncrypted, blindIndex, sha256, randomToken, randomDigits, maskEmail, hashPassword, verifyPassword, DUMMY_HASH };
