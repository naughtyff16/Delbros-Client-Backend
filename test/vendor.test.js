// Vendor portal: data grouped per PO, invoice upload; client sessions refused.
const { test, after, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./harness');
const vendorModel = require('../App/models/vendorModel');
const { ApiError } = require('../App/controllers/errorController');

after(h.stop);
afterEach(h.restore);

const vendorClient = async () => {
  const c = h.client();
  await h.signIn(c, { userId: 'U-000002', realm: 'VENDOR_PORTAL', clientCode: null, vendorId: 'V-001' });
  return c;
};
const FILE = '11111111-1111-4111-8111-111111111111';

test('GET /vendor/portal: lines, receipts and tranches per PO; booleans and empty lists', async () => {
  const c = await vendorClient();
  h.stub(vendorModel, 'data', async () => h.ok([
    [{ vendorId: 'V-001', name: 'Probe Parts', email: h.crypto.encrypt('ap@probe.test') }],
    [{ poNo: 'PO-1' }, { poNo: 'PO-2' }],
    [{ poNo: 'PO-1', partCode: 'P-1', invoiceable: 4 }],
    [{ poNo: 'PO-1', rrNo: 'RR-1', lines: null }],
    [{ id: 'VI-1', poNo: 'PO-1', invoiceNo: 'SI-1', invoiceDate: '2026-11-10', amount: 10, status: 'Rejected', resubmitted: 1, lines: null, history: null, fileName: 'si-1.pdf' }],
  ]));
  const r = await c.get('/vendor/portal');
  assert.equal(r.status, 200);
  assert.equal(r.body.vendor.email, 'ap@probe.test');
  const [p1, p2] = r.body.pos;
  assert.equal(p1.lineBalance[0].invoiceable, 4);
  assert.deepEqual(p1.receipts[0].lines, []);
  assert.deepEqual(p1.invoiceTranches.map((t) => t.id), ['VI-1']);
  assert.deepEqual(p2.lineBalance, []);
  assert.deepEqual(r.body.invoices[0], { id: 'VI-1', poNo: 'PO-1', invoiceNo: 'SI-1', invoiceDate: '2026-11-10', amount: 10, status: 'Rejected', resubmitted: true, lines: [], history: [], fileName: 'si-1.pdf' });
});

test('vendor routes refuse a client session', async () => {
  const c = h.client();
  await h.signIn(c);
  assert.equal((await c.get('/vendor/portal')).status, 403);
  assert.equal((await c.post('/vendor/invoices', {})).status, 403);
});

test('POST /vendor/invoices: only a valid file id and clean lines reach the procedure', async () => {
  const c = await vendorClient();
  const s = h.stub(vendorModel, 'uploadInvoice', async () => h.ok([[{ id: 'VI-2', poNo: 'PO-1', amount: 20000 }]], { o_vendor_invoice_id: 'VI-2' }));
  const r = await c.post('/vendor/invoices', { poNo: 'PO-1', invoiceNo: ' SI-2 ', invoiceDate: '2026-11-19', fileId: FILE, lines: [{ partCode: 'P-1', qty: '4' }], vendorId: 'V-999' });
  assert.equal(r.status, 201);
  assert.equal(r.body.id, 'VI-2');
  const [userId, v] = s.mock.calls[0].arguments;
  assert.equal(userId, 'U-000002'); // the vendor comes from the session, never from the body
  assert.deepEqual(v, { poNo: 'PO-1', invoiceNo: 'SI-2', invoiceDate: '2026-11-19', fileId: FILE, lines: [{ partCode: 'P-1', qty: 4 }], resubmitOf: null });
  await c.post('/vendor/invoices', { poNo: 'PO-1', invoiceNo: 'SI-3', invoiceDate: 'yesterday', fileId: '../etc/passwd', lines: 'x' });
  assert.deepEqual(s.mock.calls[1].arguments[1], { poNo: 'PO-1', invoiceNo: 'SI-3', invoiceDate: null, fileId: null, lines: [], resubmitOf: null });
});

test('excess invoicing refusal from the procedure → 422 with the line message', async () => {
  const c = await vendorClient();
  h.stub(vendorModel, 'uploadInvoice', async () => { throw new ApiError('EXCESS_INVOICE', 'Tyre: only 4 received and not yet invoiced', { lines: 'Tyre: only 4' }); });
  const r = await c.post('/vendor/invoices', { poNo: 'PO-1', invoiceNo: 'SI-9', invoiceDate: '2026-11-19', fileId: FILE, lines: [{ partCode: 'P-1', qty: 9 }] });
  assert.equal(r.status, 422);
  assert.equal(r.body.code, 'EXCESS_INVOICE');
  assert.deepEqual(r.body.fields, { lines: 'Tyre: only 4' });
});
