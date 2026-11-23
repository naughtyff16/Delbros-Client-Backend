// Express application: security headers, CORS for the portal, JSON body, MySQL-backed sessions, routes, errors.
const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const session = require('express-session');
const MySQLStore = require('express-mysql-session')(session);
const config = require('./config');
const { sessionStoreOptions } = require('./config/db');
const routes = require('./routes');
const { notFound, errorHandler } = require('./controllers/errorController');
const { getLogger } = require('./config/logger');

const log = getLogger('http');
const app = express();
app.disable('x-powered-by');
if (config.trustProxy) app.set('trust proxy', config.trustProxy); // behind the ALB: real client IP, secure cookies

// Request id (also returned in X-Request-Id and in 500 errors) + one log line per request.
// PDPA: only method, route path (tokens in the URL are replaced), status, time and the internal user id — no body,
// no query string, no IP address.
const SECRET_PATHS = [[/\/(reset-password|access-approval)\/[^/?]+/, '/$1/[token]']];
app.use((req, res, next) => {
  req.id = require('crypto').randomUUID().slice(0, 8);
  res.setHeader('X-Request-Id', req.id);
  const started = process.hrtime.bigint();
  res.on('finish', () => {
    if (req.path.endsWith('/health')) return;
    let p = req.originalUrl.split('?')[0];
    for (const [re, rep] of SECRET_PATHS) p = p.replace(re, rep);
    const ms = Number(process.hrtime.bigint() - started) / 1e6;
    const line = `${req.id} ${req.method} ${p} ${res.statusCode} ${ms.toFixed(0)}ms user=${req.session?.userId || '-'}`;
    if (res.statusCode >= 500) log.error(line); else if (res.statusCode >= 400) log.warn(line); else log.info(line);
  });
  next();
});

app.use(helmet());
app.use(cors({
  origin: (origin, cb) => cb(null, !origin || config.corsOrigins.includes(origin)),
  credentials: true,
  allowedHeaders: ['Content-Type', 'X-CSRF-Token'],
  methods: ['GET', 'POST', 'PUT', 'OPTIONS'], // PUT: file upload (PUT /files/:id/content)
}));
app.use(express.json({ limit: '200kb' }));

app.use(session({
  name: config.session.cookieName,
  secret: config.session.secret,
  store: config.session.store === 'memory' ? new session.MemoryStore() : new MySQLStore(sessionStoreOptions),
  resave: false,
  saveUninitialized: false,
  rolling: true, // every request restarts the idle timer
  cookie: { httpOnly: true, secure: config.session.cookieSecure, sameSite: config.session.sameSite, maxAge: config.session.idleMinutes * 60 * 1000 },
}));

app.use(config.apiPrefix, routes);
app.use(notFound);
app.use(errorHandler);

module.exports = app;
