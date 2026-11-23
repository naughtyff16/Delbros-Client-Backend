// Finance endpoints (invoices, SOA, hire coverage, e-wallet, top-ups, cash bonds) — models stubbed, real routes and controllers.
const { test, after, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./harness');
const billingModel = require('../App/models/billingModel');
const ewalletModel = require('../App/models/ewalletModel');
const { ApiError } = require('../App/controllers/errorController');

after(h.stop);
afterEach(h.restore);

async function client() { const c = h.client(); await h.signIn(c); return c; }

test('GET /portal/invoices?view=all nests lines, receipts, credits, advices and disputes per invoice', async () => {
  const c = await client();
  const m = h.stub(billingModel, 'invoicesAll', async () => h.ok([
    [{ invoiceNo: 'INV-1', total: 112, balance: 62, hasHeld: 0, isLease: 1 }, { invoiceNo: 'INV-2', total: 50, balance: 0, hasHeld: 1, isLease: 0 }],
    [{ invoiceNo: 'INV-1', lineNo: 1, lineType: 'Lease', dateFrom: '2026-09-24', dateTo: '2026-09-30', amount: 100, held: 0 }],
    [{ invoiceNo: 'INV-1', receiptNo: 'OR-1', amount: 50, counted: 1 }],
    [{ invoiceNo: 'INV-2', memoNo: 'CM-1', amount: 50 }],
    [{ invoiceNo: 'INV-1', id: 'PA-000001', status: 'Submitted' }],
    [],
  ]));
  const r = await c.get('/portal/invoices?view=all');
  assert.equal(r.status, 200);
  assert.equal(m.mock.calls[0].arguments[0], 'U-000001');
  const [a, b] = r.body.items;
  assert.equal(a.isLease, true);
  assert.equal(b.hasHeld, true);
  assert.deepEqual(a.lines[0], { lineType: 'Lease', amount: 100, id: 'INV-1-1', from: '2026-09-24', to: '2026-09-30', held: false });
  assert.equal(a.payments[0].counted, true);
  assert.equal(a.payments[0].invoiceNo, undefined);
  assert.equal(b.credits[0].memoNo, 'CM-1');
  assert.equal(a.advices[0].id, 'PA-000001');
  assert.deepEqual(a.disputes, []);
});

test('GET /portal/invoices without view keeps the paged list', async () => {
  const c = await client();
  const m = h.stub(billingModel, 'invoices', async () => h.ok([[{ invoiceNo: 'INV-1' }], [{ total: 1, balanceTotal: 62 }]]));
  const r = await c.get('/portal/invoices?page=2&pageSize=5&paymentStatus=Overdue');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { items: [{ invoiceNo: 'INV-1' }], total: 1, balanceTotal: 62, page: 2, pageSize: 5 });
  assert.equal(m.mock.calls[0].arguments[1].paymentStatus, 'Overdue');
});

test('POST acknowledge returns the due date and who acknowledged', async () => {
  const c = await client();
  h.stub(billingModel, 'acknowledge', async () => h.ok([], { o_due_date: '2026-12-19' }));
  const r = await c.post('/portal/invoices/INV-1/acknowledge');
  assert.equal(r.status, 200);
  assert.equal(r.body.dueDate, '2026-12-19');
  assert.equal(r.body.acknowledgedVia, 'Client portal');
  assert.equal(r.body.acknowledgedBy, 'U-000001');
});

test('payment advice: only a UUID file id reaches the procedure; procedure field errors come back as 422', async () => {
  const c = await client();
  const m = h.stub(billingModel, 'paymentAdvice', async () => h.ok([], { o_advice_id: 'PA-000002' }));
  const ok = await c.post('/portal/invoices/INV-1/payment-advice', { amount: 62, paidOn: '2026-11-18', method: 'InstaPay', reference: 'R1', proofFileId: '../../etc/passwd' });
  assert.equal(ok.status, 201);
  assert.deepEqual(ok.body, { id: 'PA-000002', status: 'Submitted' });
  assert.equal(m.mock.calls[0].arguments[2].proofFileId, null);
  m.mock.restore();
  h.stub(billingModel, 'paymentAdvice', async () => { throw new ApiError('VALIDATION_FAILED', 'Check the highlighted fields.', { proofFile: 'Attach the proof' }); });
  const bad = await c.post('/portal/invoices/INV-1/payment-advice', { amount: 62 });
  assert.equal(bad.status, 422);
  assert.deepEqual(bad.body.fields, { proofFile: 'Attach the proof' });
});

test('GET /portal/soa returns JSON; ?format=csv downloads a CSV with the running balance', async () => {
  const c = await client();
  const sets = [
    [{ clientCode: 'C-00123', billingName: 'Acme, Inc.', periodFrom: '2026-10-01', periodTo: '2026-11-19', balanceBroughtForward: 0, closingBalance: 62, scopeNote: 'Scope', aging: { total: 62 } }],
    [{ date: '2026-10-01', docType: 'Invoice', docNo: 'INV-1', due: '2026-10-31', debit: 112, credit: 0, ref: 'Lease', runningBalance: 112 },
      { date: '2026-10-05', docType: 'Official receipt', docNo: 'OR-1', due: null, debit: 0, credit: 50, ref: 'Paid INV-1', runningBalance: 62 }],
    [{ memoNo: 'DM-1', amount: 300 }], [],
  ];
  h.stub(billingModel, 'soa', async () => h.ok(sets));
  const j = await c.get('/portal/soa');
  assert.equal(j.status, 200);
  assert.equal(j.body.header.aging.total, 62);
  assert.equal(j.body.rows[1].runningBalance, 62);
  assert.equal(j.body.notOnStatement[0].memoNo, 'DM-1');
  const csv = await c.get('/portal/soa?format=csv');
  assert.equal(csv.status, 200);
  assert.match(csv.headers.get('content-type'), /text\/csv/);
  assert.match(csv.headers.get('content-disposition'), /attachment; filename="SOA_C-00123_2026-11-19\.csv"/);
  assert.match(csv.body, /"Acme, Inc\."/);
  assert.match(csv.body, /OR-1,,0,50,Paid INV-1,62/);
});

test('POST /portal/soa/email returns the statement number and recipients', async () => {
  const c = await client();
  const m = h.stub(billingModel, 'soaEmail', async () => h.ok([[{ soaNo: 'SOA-2026-00004' }], [{ recipient: 'Your email', to: 'x', status: 'Queued' }], []]));
  const r = await c.post('/portal/soa/email', { from: '2026-10-01', copyBilling: true });
  assert.equal(r.status, 200);
  assert.equal(r.body.soaNo, 'SOA-2026-00004');
  assert.equal(r.body.recipients.length, 1);
  assert.deepEqual(m.mock.calls[0].arguments.slice(1, 4), ['2026-10-01', null, true]);
});

test('GET /portal/hire-coverage derives the status per unit', async () => {
  const c = await client();
  h.stub(billingModel, 'hireCoverage', async () => h.ok([[{ unitId: 'A', missingDays: ['2026-10-02'] }, { unitId: 'B', billedTwiceDays: ['2026-10-03'] }, { unitId: 'C' }]]));
  const r = await c.get('/portal/hire-coverage');
  assert.deepEqual(r.body.items.map((x) => x.status), ['Gap', 'Billed twice', 'Every day invoiced once']);
});

test('GET /portal/ewallet?all=1 asks the procedure for the whole ledger (page size 0)', async () => {
  const c = await client();
  const m = h.stub(ewalletModel, 'ledger', async () => h.ok([[{ balance: 100, billingEntity: 'NAK' }], [{ id: 'EWT-1', postedByTreasury: 1 }, { id: 'EWT-2', postedByTreasury: 0 }], [{ total: 2 }]]));
  const r = await c.get('/portal/ewallet?all=1');
  assert.equal(r.status, 200);
  assert.equal(m.mock.calls[0].arguments[1].pageSize, 0);
  assert.deepEqual(r.body.items.map((x) => x.postedByTreasury), [true, false]);
  assert.equal(r.body.pageSize, 2);
  assert.ok(r.body.payee.bank !== undefined);
  await c.get('/portal/ewallet?pageSize=5');
  assert.equal(m.mock.calls[1].arguments[1].pageSize, 5);
});

test('top-up: duplicate reference refused with 409 and the field', async () => {
  const c = await client();
  h.stub(ewalletModel, 'topupCreate', async () => { throw new ApiError('DUPLICATE', 'A top-up with reference R1 was already sent.', { reference: 'Already used on another request' }); });
  const r = await c.post('/portal/topups', { amount: 1000, reference: 'R1' });
  assert.equal(r.status, 409);
  assert.equal(r.body.fields.reference, 'Already used on another request');
});

test('cash bonds: booleans normalised; withdrawal returns 201; refused codes keep their status', async () => {
  const c = await client();
  h.stub(ewalletModel, 'cashBonds', async () => h.ok([[{ id: 'CB-1', preview: { contractEnded: false } }], [{ id: 'CBW-1', bondId: 'CB-1', earlyException: 1, steps: null }]]));
  const r = await c.get('/portal/cash-bonds');
  assert.equal(r.body.withdrawals[0].earlyException, true);
  assert.deepEqual(r.body.withdrawals[0].steps, []);
  h.stub(ewalletModel, 'refundPreview', async () => h.ok([[{ bondId: 'CB-1', refundable: 10, contractEnded: 0 }]]));
  assert.equal((await c.get('/portal/cash-bonds/CB-1/refund-preview')).body.contractEnded, false);
  const w = h.stub(ewalletModel, 'withdrawal', async () => h.ok([], { o_withdrawal_id: 'CBW-2' }));
  const ok = await c.post('/portal/cash-bonds/CB-1/withdrawals', { amount: 5, reason: 'End', earlyException: true });
  assert.equal(ok.status, 201);
  assert.deepEqual(ok.body, { id: 'CBW-2', status: 'Pending' });
  assert.deepEqual(w.mock.calls[0].arguments[2], { amount: 5, reason: 'End', earlyException: true });
  w.mock.restore();
  h.stub(ewalletModel, 'withdrawal', async () => { throw new ApiError('BR14_CONTRACT_ACTIVE', 'Contract C-1 is Active.'); });
  assert.equal((await c.post('/portal/cash-bonds/CB-1/withdrawals', { amount: 5, reason: 'x' })).status, 409);
});

test('finance routes need a client session (vendor refused, anonymous 401)', async () => {
  assert.equal((await h.client().get('/portal/invoices?view=all')).status, 401);
  const v = h.client();
  await h.signIn(v, { userId: 'U-000002', realm: 'VENDOR_PORTAL', clientCode: null, vendorId: 'V-001' });
  for (const p of ['/portal/invoices?view=all', '/portal/soa', '/portal/ewallet?all=1', '/portal/cash-bonds']) assert.equal((await v.get(p)).status, 403, p);
});
