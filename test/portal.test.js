// Portal area (dashboard, notifications, feedback, returns, contracts): routes → controllers with stubbed models.
const { test, after, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./harness');
const portalModel = require('../App/models/portalModel');
const contractModel = require('../App/models/contractModel');
const { ApiError } = require('../App/controllers/errorController');

after(h.stop);
afterEach(h.restore);

async function client() { const c = h.client(); await h.signIn(c); return c; }

// The 12 result sets of sp_portal_dashboard (minimal rows).
const DASH_SETS = () => [
  [{ clientCode: 'C-00123', clientName: 'Acme', clientStatus: 'Active', client: { clientCode: 'C-00123', status: 'Active', billingCycle: 'Weekly' },
    billing: { creditTermBasis: 'invoice_date', weeklyCycleStart: 'Friday' }, activeContracts: 2, nearestExpiry: '2027-06-30', oldestDueOverdue: 1, oldestDueInvoices: null,
    accountExecutive: { name: h.crypto.encrypt('Ana Reyes'), email: h.crypto.encrypt('ana@delbros.test'), mobile: null } }],
  [{ current: 0, total: 0 }], [], [], [{ held: 0, withdrawalPending: 0 }],
  [{ chassisNo: 'CH-1', canRequestReturn: 1 }], [{ gatePassNo: 'G1', crossBranch: 0, isForceInbound: 0, damage: null }], [{ code: 'CAV', name: 'Cavite' }],
  [{ rescueNo: 'RSC-1', urgent: 1 }], [{ euNo: 'EU-1', units: null }], [], [],
];

test('GET /portal/dashboard: client object, billing.weekly, booleans, activeContracts, decrypted AE', async () => {
  const c = await client();
  const s = h.stub(portalModel, 'dashboard', async () => h.ok(DASH_SETS()));
  const r = await c.get('/portal/dashboard');
  assert.equal(r.status, 200);
  assert.equal(s.mock.calls[0].arguments[0], 'U-000001'); // user id from the session, never from the request
  const d = r.body;
  assert.equal(d.client.status, 'Active');
  assert.deepEqual(d.billing.weekly, { start: 'Friday', end: 'Thursday', startIndex: 5, label: 'Friday–Thursday' });
  assert.deepEqual(d.activeContracts, { count: 2, nearestExpiry: '2027-06-30' });
  assert.equal(d.oldestDueOverdue, true);
  assert.deepEqual(d.oldestDueInvoices, []);
  assert.equal(d.cashBond.withdrawalPending, false);
  assert.equal(d.onHire[0].canRequestReturn, true);
  assert.equal(d.returns[0].crossBranch, false);
  assert.deepEqual(d.returns[0].damage, []);
  assert.equal(d.openRescues[0].urgent, true);
  assert.deepEqual(d.ewas[0].units, []);
  assert.equal(d.accountExecutive.name, 'Ana Reyes'); // PDPA: decrypted only in the response
  assert.equal(d.accountExecutive.email, 'ana@delbros.test');
});

test('portal routes refuse a vendor session and anonymous callers', async () => {
  assert.equal((await h.client().get('/portal/dashboard')).status, 401);
  const v = h.client();
  await h.signIn(v, { userId: 'U-000002', realm: 'VENDOR_PORTAL', clientCode: null, vendorId: 'V-001' });
  const r = await v.get('/portal/dashboard');
  assert.equal(r.status, 403);
  assert.equal(r.body.code, 'FORBIDDEN');
});

test('a procedure refusal maps to its HTTP status', async () => {
  const c = await client();
  h.stub(portalModel, 'dashboard', async () => { throw new ApiError('FORBIDDEN', 'Client access only.'); });
  const r = await c.get('/portal/dashboard');
  assert.equal(r.status, 403);
  assert.deepEqual({ code: r.body.code, message: r.body.message }, { code: 'FORBIDDEN', message: 'Client access only.' });
});

test('notifications: string ids, booleans; mark read passes the id (or null = all)', async () => {
  const c = await client();
  h.stub(portalModel, 'notifications', async () => h.ok([[{ id: 12, title: 't', read: 0, requiresAck: 1 }]]));
  const r = await c.get('/portal/notifications');
  assert.deepEqual(r.body.items[0], { id: '12', title: 't', read: false, requiresAck: true });
  const m = h.stub(portalModel, 'markRead', async () => h.ok());
  assert.equal((await c.post('/portal/notifications/read', { id: '12' })).status, 204);
  assert.equal((await c.post('/portal/notifications/read', {})).status, 204);
  assert.deepEqual(m.mock.calls.map((x) => x.arguments[1]), [12, null]);
});

test('feedback: submit returns 201 with the record; list wraps items', async () => {
  const c = await client();
  const s = h.stub(portalModel, 'feedbackSubmit', async () => h.ok([[{ id: 'FB-00001', rating: 4 }]], { o_feedback_id: 'FB-00001' }));
  const r = await c.post('/portal/feedback', { category: 'Service rating', rating: 4, topic: 'Rescue', subject: '', message: '' });
  assert.equal(r.status, 201);
  assert.equal(r.body.id, 'FB-00001');
  assert.deepEqual(s.mock.calls[0].arguments[1], { category: 'Service rating', subject: null, message: null, reference: null, rating: 4, topic: 'Rescue' });
  h.stub(portalModel, 'feedbackList', async () => h.ok([[{ id: 'FB-00001' }]]));
  assert.deepEqual((await c.get('/portal/feedback')).body, { items: [{ id: 'FB-00001' }] });
});

test('return request: required fields checked before the database; crossBranch boolean; notified list decrypted', async () => {
  const c = await client();
  const s = h.stub(portalModel, 'returnRequest', async () => h.ok([[{ requestNo: 'RTN-000001', chassisNo: 'CH-1', returnBranchCode: 'BTG', crossBranch: 1 }],
    [{ channel: 'Email', recipient: 'Account Executive', recipientName: h.crypto.encrypt('Ana Reyes'), to: h.crypto.encrypt('ana@delbros.test'), status: 'Queued' }]], { o_request_no: 'RTN-000001' }));
  const bad = await c.post('/portal/returns', { chassisNo: 'CH-1' });
  assert.equal(bad.status, 422);
  assert.deepEqual(Object.keys(bad.body.fields).sort(), ['preferredDate', 'returnBranchCode']);
  assert.equal(s.mock.callCount(), 0);
  const r = await c.post('/portal/returns', { chassisNo: 'CH-1', returnBranchCode: 'BTG', preferredDate: '2026-11-25' });
  assert.equal(r.status, 201);
  assert.equal(r.body.crossBranch, true);
  assert.equal(r.body.notified[0].recipientName, 'Ana Reyes');
  assert.equal(r.body.notified[0].to, 'ana@delbros.test');
});

test('contracts: result sets grouped per contract, covered as boolean', async () => {
  const c = await client();
  h.stub(contractModel, 'list', async () => h.ok([
    [{ contractNo: 'K-1' }, { contractNo: 'K-2' }],
    [{ contractNo: 'K-1', equipmentType: 'EQ1' }], [{ contractNo: 'K-2', version: 1 }], [{ contractNo: 'K-1', chassisNo: 'CH-1' }],
    [{ contractNo: 'K-1', code: 'CAV', covered: 1 }, { contractNo: 'K-1', code: 'MNL', covered: 0 }],
    [{ contractNo: 'K-2', id: 'CRQ-1' }], [], [{ contractNo: 'K-1', status: 'Signed' }],
  ]));
  const r = await c.get('/portal/contracts');
  assert.equal(r.status, 200);
  const [k1, k2] = r.body.items;
  assert.equal(k1.entitlement.length, 1);
  assert.equal(k1.onHireUnits[0].chassisNo, 'CH-1');
  assert.deepEqual(k1.branches.covered.map((b) => b.code), ['CAV']);
  assert.deepEqual(k1.branches.outside, ['MNL']);
  assert.equal(k1.branches.activity[0].covered, true);
  assert.equal(k2.requests[0].id, 'CRQ-1');
  assert.equal(k2.rateHistory.length, 1);
  assert.equal(k1.history[0].status, 'Signed');
});

test('contract change request: the contract number comes from the URL', async () => {
  const c = await client();
  const s = h.stub(contractModel, 'request', async () => h.ok([[{ id: 'CRQ-000002', kind: 'Renewal', contractNo: 'K-1' }]], { o_request_id: 'CRQ-000002' }));
  const r = await c.post('/portal/contracts/K-1/requests', { kind: 'Renewal', details: 'Renew for 12 months', termMonths: 12, contractNo: 'K-9' });
  assert.equal(r.status, 201);
  assert.equal(s.mock.calls[0].arguments[1], 'K-1');
  assert.deepEqual(s.mock.calls[0].arguments[2], { kind: 'Renewal', details: 'Renew for 12 months', termMonths: 12, changeArea: null, effectiveDate: null });
});
