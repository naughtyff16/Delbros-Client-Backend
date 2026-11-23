// "Request portal access" (public), the applicant's status check, and the reviewer's one-click approval link.
const config = require('../config');
const crypto = require('./cryptoController');
const mail = require('./mailController');
const authModel = require('../models/authModel');
const { getPolicy } = require('./authController');
const { downloadLink } = require('./fileController');
const { asyncHandler, respond } = require('./errorController');
const { RE, str, check, passwordProblem, source } = require('./helpers');
const log = require('../config/logger').getLogger('access'); // internal ids only — no personal data

// POST /access-requests
const create = asyncHandler(async (req, res) => {
  const b = req.body;
  const p = await getPolicy();
  const extras = String(p.registrationExtras || '').split(',').map((s) => s.trim());
  const f = {
    accountType: b.accountType === 'vendor' ? 'vendor' : 'client', companyName: str(b.clientName), tin: str(b.tin), branchCode: str(b.branchCode),
    address: str(b.address1), firstName: str(b.firstName), lastName: str(b.lastName), email: str(b.email).toLowerCase(), phone: str(b.phone),
    password: String(b.password || ''), documents: Array.isArray(b.documents) ? b.documents.filter((d) => RE.uuid.test(d)) : [], consent: b.consent === true,
  };
  const pwProblem = passwordProblem(f.password, p.passwordMinLength);
  check([
    ['clientName', f.companyName.length >= 2, 'Required'], ['branchCode', f.branchCode !== '', 'Choose a branch'], ['address1', f.address !== '', 'Required'],
    ['firstName', f.firstName !== '', 'Required'], ['lastName', f.lastName !== '', 'Required'], ['email', RE.email.test(f.email), 'Enter a valid email'],
    ['phone', RE.phPhone.test(f.phone), 'Enter a PH number, e.g. 0917 123 4567'], ['password', !pwProblem, pwProblem],
    ['tin', !extras.includes('tin') || /^\d{9,12}$/.test(f.tin.replace(/\D/g, '')), 'Enter the 9 to 12 digit TIN'],
    ['documents', !extras.includes('documents') || f.documents.length > 0, 'Attach at least one document'],
    ['consent', !extras.includes('consent') || f.consent, 'Please agree to the privacy notice'],
  ]);

  // PDPA: encrypt every personal field; blind indexes for the uniqueness checks.
  const token = crypto.randomToken(32);
  const fullName = `${f.firstName} ${f.lastName}`;
  const { out } = await authModel.accessRequestCreate({
    accountType: f.accountType, companyName: f.companyName, tin: crypto.encrypt(f.tin), tinHash: crypto.blindIndex('tin', f.tin), branchCode: f.branchCode, address: f.address,
    firstName: crypto.encrypt(f.firstName), lastName: crypto.encrypt(f.lastName), fullName: crypto.encrypt(fullName),
    email: crypto.encrypt(f.email), emailHash: crypto.blindIndex('email', f.email), phone: crypto.encrypt(f.phone),
    passwordHash: await crypto.hashPassword(f.password), documents: f.documents, consent: f.consent, approvalTokenHash: crypto.sha256(token), source: source(req),
  });

  log.info(`Access request ${out.o_reference} created: ${f.accountType} ${out.o_subject_id}, user ${out.o_user_id}, ${f.documents.length} document(s)`);
  // The reviewer gets the single-use approval link (the token is never stored in clear).
  const submittedAt = new Date();
  let reviewerStatus = 'Failed';
  if (out.o_reviewer_email) {
    const sent = await mail.sendDirect({ entityType: 'access_request', entityId: out.o_reference, event: 'access.review', audience: 'Delbros', label: out.o_reviewer_label,
      recipientNameEnc: out.o_reviewer_name, toEnc: out.o_reviewer_email, subject: `Approve portal access — ${f.companyName} (${out.o_reference})`,
      text: `${f.companyName} asked for ${f.accountType} portal access (${out.o_reference}).\nApprove or deny with this link (valid for 7 days, single use):\n${config.portalUrl}/access-approval/${token}` });
    reviewerStatus = sent ? 'Sent' : 'Failed';
  }
  if (!out.o_reviewer_email) log.warn(`Access request ${out.o_reference}: no reviewer email on file — approval link not sent`);
  // The applicant sees what they entered (their own data) and who was told — the reviewer by role only, never the reviewer's address.
  respond(res, { reference: out.o_reference, accountType: f.accountType, subjectId: out.o_subject_id, email: f.email, submittedAt,
    reviewer: { role: out.o_reviewer_label, name: out.o_reviewer_name }, companyName: f.companyName, tin: f.tin, branchCode: f.branchCode,
    contactName: fullName, phone: f.phone, documents: f.documents, status: 'Submitted',
    statusLabel: f.accountType === 'vendor' ? 'Pending Procurement approval' : 'Pending AE approval',
    notices: [
      { at: submittedAt, audience: f.accountType === 'vendor' ? 'Procurement' : 'Account Executive', channel: 'Email', to: out.o_reviewer_label,
        subject: `Approve portal access — ${f.companyName} (${out.o_reference})`, status: reviewerStatus },
      { at: submittedAt, audience: 'Applicant', channel: 'Email', to: f.email, subject: `We received your portal access request — ${out.o_reference}`, status: 'Queued' },
    ],
    // DEVELOPMENT ONLY (DEV_EXPOSE_CODES): the emailed approval link, for the portal demo box. Never logged.
    ...(config.devExposeCodes ? { devApprovalLink: `/access-approval/${token}` } : {}) }, 201);
});

// GET /access-requests/status?reference=&email=
const status = asyncHandler(async (req, res) => {
  const { sets } = await authModel.accessRequestStatus(str(req.query.reference), crypto.blindIndex('email', str(req.query.email)));
  respond(res, { ...sets[0][0], notices: sets[1] || [] });
});

// GET /access-approval/:token
const approvalGet = asyncHandler(async (req, res) => {
  const { sets } = await authModel.approvalGet(crypto.sha256(str(req.params.token)));
  const documents = await Promise.all((sets[1] || []).map(async ({ storagePath, ...d }) => ({
    ...d, downloadUrl: d.scanStatus === 'Clean' ? downloadLink(storagePath, d.fileName, req) : null })));
  const r = sets[0][0];
  const statusLabel = r.status === 'Approved' ? 'Approved' : r.status === 'Rejected' ? 'Denied' : r.accountType === 'vendor' ? 'Pending Procurement approval' : 'Pending AE approval';
  respond(res, { ...r, expired: !!r.expired, statusLabel, documents });
});

// POST /access-approval/:token
const approvalDecide = asyncHandler(async (req, res) => {
  const decision = req.body.decision === 'approve' ? 'approve' : 'deny';
  const { sets } = await authModel.approvalDecide(crypto.sha256(str(req.params.token)), decision, str(req.body.billingName) || null, str(req.body.reason) || null, 'One-click approval link (email)');
  log.info(`Access request ${sets[0][0].reference} ${sets[0][0].status} via approval link`);
  respond(res, sets[0][0]);
});

module.exports = { create, status, approvalGet, approvalDecide };
