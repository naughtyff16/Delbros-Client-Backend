// Email (Amazon SES). Addresses are stored encrypted and decrypted only here,
// at the moment of sending.
const { SendEmailCommand } = require('@aws-sdk/client-sesv2');
const config = require('../config');
const aws = require('../config/aws');
const crypto = require('./cryptoController');
const authModel = require('../models/authModel');
const jobModel = require('../models/jobModel');
const log = require('../config/logger').getLogger('mail'); // internal ids only — no personal data

async function sendEmail({ to, subject, text }) {
  if (!config.aws.sesFrom) {
    if (config.isProduction) throw new Error('SES_FROM_ADDRESS is not set');
    log.info(`[development] email not sent (SES_FROM_ADDRESS empty): "${subject}"`); // body may hold a code or link — never logged
    return 'dev-log';
  }
  const r = await aws.ses.send(new SendEmailCommand({
    FromEmailAddress: config.aws.sesFrom,
    Destination: { ToAddresses: [to] },
    Content: { Simple: { Subject: { Data: subject, Charset: 'UTF-8' }, Body: { Text: { Data: text, Charset: 'UTF-8' } } } },
  }));
  return r.MessageId;
}

/**
 * Send an email that carries a secret (sign-in code, reset link, approval link) straight away — it is never stored —
 * then record the delivery (without the secret) in the outbox log. toEnc may be ciphertext or a plain settings address.
 */
async function sendDirect({ entityType, entityId, event, audience, label, recipientNameEnc = null, toEnc, subject, text }) {
  const to = crypto.decrypt(toEnc);
  let status = 'Sent'; let providerId = null; let error = null;
  try { providerId = await sendEmail({ to, subject, text }); } catch (e) { status = 'Failed'; error = String(e.message).slice(0, 900); log.error(`Direct email failed: ${event} ${entityType} ${entityId}`, e); }
  if (status === 'Sent') log.info(`Direct email sent: ${event} ${entityType} ${entityId}`);
  await authModel.recordDirectEmail({ entityType, entityId, event, audience, label, recipientName: recipientNameEnc,
    to: crypto.isEncrypted(toEnc) ? toEnc : crypto.encrypt(toEnc), subject, status, providerId, error });
  return status === 'Sent';
}

// Plain-text body for a queued message. Procedures never put personal data in subject/body; the greeting
// uses the decrypted recipient name.
function render(m) {
  const name = m.recipientName ? crypto.decrypt(m.recipientName) : null;
  const lines = [name ? `Hello ${name},` : 'Hello,', '', m.body || `Reference: ${m.entityId}.`, '',
    `Sign in to the Delbros portal for the details: ${config.portalUrl}`, '', '— Delbros Leasing (automatic message, please do not reply)'];
  return { subject: m.subject || `Delbros notification — ${m.entityId}`, text: lines.join('\n') };
}

/** Outbox worker: claim queued messages, decrypt the address, send, record Sent / Failed (the procedure retries). */
async function processOutbox(batch = 25) {
  const { sets } = await jobModel.outboxClaim(batch);
  const seen = new Set();
  const claimed = (sets[0] || []).length; let sent = 0; let failed = 0;
  for (const m of sets[0] || []) {
    try {
      const to = crypto.decrypt(m.toAddress);
      const dedupeKey = `${m.entityType}|${m.entityId}|${m.eventType}|${m.channel}|${String(to).toLowerCase()}|${m.attempts}`;
      if (seen.has(dedupeKey)) { await jobModel.outboxMark(m.messageId, true, 'duplicate-skipped', null); continue; } // same address twice in one event
      seen.add(dedupeKey);
      const { subject, text } = render(m);
      const providerId = await sendEmail({ to, subject, text });
      await jobModel.outboxMark(m.messageId, true, providerId, null);
      sent++;
    } catch (e) {
      failed++;
      log.error(`Outbox message ${m.messageId} (${m.channel} ${m.eventType} ${m.entityType} ${m.entityId}, attempt ${m.attempts}) failed`, e);
      await jobModel.outboxMark(m.messageId, false, null, String(e.message).slice(0, 900));
    }
  }
  if (claimed) log.info(`Outbox: ${claimed} claimed, ${sent} sent, ${failed} failed`);
}

module.exports = { sendEmail, sendDirect, processOutbox };
