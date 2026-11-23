// MySQL connection pool (API account: EXECUTE on procedures only) and the session-store options.
const mysql = require('mysql2/promise');
const config = require('./index');

const pool = mysql.createPool({
  host: config.db.host,
  port: config.db.port,
  database: config.db.database,
  user: config.db.user,
  password: config.db.password,
  ssl: config.db.ssl ? { rejectUnauthorized: true } : undefined, // RDS: add the AWS RDS CA bundle if your Node build does not trust it
  connectionLimit: config.db.poolSize,
  charset: 'utf8mb4',
  timezone: 'Z',             // the database stores UTC
  dateStrings: ['DATE'],     // business dates stay 'YYYY-MM-DD' (Manila); DATETIME → JS Date (UTC)
  decimalNumbers: true,      // DECIMAL(15,2) money → JS number
  supportBigNumbers: true,
});

// express-mysql-session options — uses the separate portal_session account and the sessions table from 01_schema.sql.
const sessionStoreOptions = {
  host: config.db.host,
  port: config.db.port,
  database: config.db.database,
  user: config.sessionDb.user,
  password: config.sessionDb.password,
  ssl: config.db.ssl ? { rejectUnauthorized: true } : undefined,
  createDatabaseTable: false,
  clearExpired: true,
  checkExpirationInterval: 15 * 60 * 1000,
  schema: { tableName: 'sessions', columnNames: { session_id: 'session_id', expires: 'expires', data: 'data' } },
};

module.exports = { pool, sessionStoreOptions };
