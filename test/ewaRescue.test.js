// EWA + rescue controllers: validation refusals, PDPA encryption before the model, realm guard, response shapes.
const { test, after, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./harness');
const ewaModel = require('../App/models/ewaModel');
const rescueModel = require('../App/models/rescueModel');

after(h.stop);
afterEach(h.restore);

const ENC = /^enc:v1:/;
const listRow = (euNo, extra = {}) => ({
  euNo, clientCode: 'C-00123', clientName: 'Acme', branchCode: 'MNL', contractNo: 'C-2026-001', status: 'Active', createdAt: new Date('2026-11-19T01:00:00Z'),
  driverName: h.crypto.encrypt('Juan Dela Cruz'), driverLicenseNo: h.crypto.encrypt('N01-23-456789'), createdByName: h.crypto.encrypt('Ana Reyes'),
  units: [{ equipmentType: '40FT', qty: 2, usedChassis: [] }], gatePasses: null, extensions: null, extension: null,
  delivery: [{ id: 2, at: '2026-11-19 01:00:02.000000', channel: 'Email', audience: 'Client', recipient: 'Company email', recipientName: null, to: h.crypto.encrypt('ops@acme.example'), status: 'Sent', resend: 0 },
             { id: 1, at: '2026-11-19 01:00:01.123456', channel: 'Email', audience: 'Delbros', recipient: 'Account Executive', recipientName: h.crypto.encrypt('Mia Santos'), to: h.crypto.encrypt('mia@delbros.example'), status: 'Sending', resend: 1 }],
  ...extra,
});
const ewaBody = { contractNo: 'C-2026-001', branchCode: 'MNL', trucker: 'Fast Haul', truckPlateNo: 'nab  5678', driverName: 'Juan Dela Cruz', driverLicenseNo: 'n01-23-456789', units: [{ equipmentType: '40FT', qty: 2 }] };

test('EWA create: blank driver/truck fields → 422 MISSING_DRIVER_TRUCK_INFO with the form field names', async () => {
  const c = h.client(); await h.signIn(c);
  const create = h.stub(ewaModel, 'create', async () => h.ok());
  const r = await c.post('/portal/ewa', { ...ewaBody, trucker: '', driverName: ' ' });
  assert.equal(r.status, 422);
  assert.equal(r.body.code, 'MISSING_DRIVER_TRUCK_INFO');
  assert.deepEqual(r.body.fields, { trucker: 'Required', driverName: 'Required' });
  assert.equal(create.mock.callCount(), 0);
});

test('EWA create: LTO format refusals → 422 VALIDATION_FAILED on truckPlateNo / driverLicenseNo', async () => {
  const c = h.client(); await h.signIn(c);
  const r = await c.post('/portal/ewa', { ...ewaBody, truckPlateNo: '12345', driverLicenseNo: 'ABC' });
  assert.equal(r.status, 422);
  assert.equal(r.body.code, 'VALIDATION_FAILED');
  assert.deepEqual(Object.keys(r.body.fields).sort(), ['driverLicenseNo', 'truckPlateNo']);
});

test('EWA create: driver name and licence reach the model encrypted, with the licence blind index; response is the decrypted list row', async () => {
  const c = h.client(); await h.signIn(c);
  let seen;
  h.stub(ewaModel, 'create', async (userId, e) => { seen = { userId, e }; return h.ok([], { o_eu_no: 'EU-000781' }); });
  h.stub(ewaModel, 'list', async (userId, q) => { assert.equal(q.q, 'EU-000781'); return h.ok([[listRow('EU-000781')], [{ total: 1 }]]); });
  const r = await c.post('/portal/ewa', ewaBody);
  assert.equal(r.status, 201);
  assert.equal(seen.userId, 'U-000001');
  assert.match(seen.e.driverName, ENC);
  assert.match(seen.e.driverLicenseNo, ENC);
  assert.equal(seen.e.driverLicenseHash, h.crypto.blindIndex('licence', 'N01-23-456789'));
  assert.equal(seen.e.truckPlateNo, 'NAB 5678');
  assert.equal(r.body.euNo, 'EU-000781');
  assert.equal(r.body.driverName, 'Juan Dela Cruz');
  assert.equal(r.body.createdByName, 'Ana Reyes');
  assert.deepEqual(r.body.gatePasses, []);
  assert.deepEqual(r.body.extensions, []);
  // Delivery log: sorted by message id, 'Sending' shown as Queued, resend boolean, nested SQL datetimes → ISO UTC, names decrypted.
  assert.deepEqual(r.body.delivery.map((d) => [d.id, d.status, d.resend, d.at, d.recipientName, d.to]), [
    [1, 'Queued', true, '2026-11-19T01:00:01.123Z', 'Mia Santos', 'mia@delbros.example'],
    [2, 'Sent', false, '2026-11-19T01:00:02.000Z', null, 'ops@acme.example'],
  ]);
});

test('EWA list: paging parameters and a licence search by blind index', async () => {
  const c = h.client(); await h.signIn(c);
  let q;
  h.stub(ewaModel, 'list', async (userId, x) => { q = x; return h.ok([[listRow('EU-000001')], [{ total: 1 }]]); });
  const r = await c.get('/portal/ewa?page=2&pageSize=100&q=N01-23-456789&status=Expired');
  assert.equal(r.status, 200);
  assert.deepEqual([q.page, q.pageSize, q.status], [2, 100, 'Expired']);
  assert.equal(q.qLicenceHash, h.crypto.blindIndex('licence', 'N01-23-456789'));
  assert.equal(r.body.total, 1);
  assert.equal(r.body.items[0].units[0].qty, 2);
});

test('EWA cancel returns the updated row; procedure refusals keep their HTTP status', async () => {
  const c = h.client(); await h.signIn(c);
  h.stub(ewaModel, 'cancel', async () => h.ok());
  h.stub(ewaModel, 'list', async () => h.ok([[listRow('EU-000781', { status: 'Cancelled' })], [{ total: 1 }]]));
  const r = await c.post('/portal/ewa/EU-000781/cancel', { reason: 'wrong truck' });
  assert.equal(r.status, 200);
  assert.equal(r.body.status, 'Cancelled');
  h.restore(); await h.signIn(c);
  const { ApiError } = require('../App/controllers/errorController');
  h.stub(ewaModel, 'extension', async () => { throw new ApiError('INVALID_STATE', 'Only expired EWAs can be extended.'); });
  const x = await c.post('/portal/ewa/EU-000781/extension', { reason: 'late' });
  assert.equal(x.status, 409);
  assert.equal(x.body.code, 'INVALID_STATE');
});

test('EWA options: entitlement grouped as the New EWA dialog reads it; availability per branch', async () => {
  const c = h.client(); await h.signIn(c);
  h.stub(ewaModel, 'options', async () => h.ok([
    [{ blocked: null, clientName: 'Acme', validityHours: 24, walletNotice: null, accountExecutive: { name: null, email: null }, creditContact: null }],
    [{ contractNo: 'C-2026-001', class: 'A', unitQty: 10, onHire: 3, pending: 2, contractRemaining: 5, types: [{ equipmentType: '40FT', entitled: null, onHire: 3, pending: 2, remaining: 5 }] }],
    [{ code: 'MNL', name: 'Manila' }, { code: 'CEB', name: 'Cebu' }],
    [{ branchCode: 'MNL', equipmentType: '40FT', available: 4 }],
    [{ name: h.crypto.encrypt('Juan Dela Cruz'), licence: h.crypto.encrypt('N01-23-456789'), lastUsed: new Date() }], [],
  ]));
  const r = await c.get('/portal/ewa/options');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.contracts[0].entitlement, { unitQty: 10, onHire: 3, pending: 2, contractRemaining: 5, types: [{ equipmentType: '40FT', entitled: null, onHire: 3, pending: 2, remaining: 5 }] });
  assert.deepEqual(r.body.availability, { MNL: { '40FT': 4 }, CEB: {} });
  assert.equal(r.body.accountExecutive, null);
  assert.equal(r.body.drivers[0].licence, 'N01-23-456789');
});

test('rescue create: scene contact checked, then encrypted before the model; response is the list row', async () => {
  const c = h.client(); await h.signIn(c);
  const bad = await c.post('/portal/rescue', { chassisNo: 'CH-1', sceneContactName: '', sceneContactPhone: '12' });
  assert.equal(bad.status, 422);
  assert.deepEqual(Object.keys(bad.body.fields).sort(), ['sceneContactName', 'sceneContactPhone']);
  let seen;
  h.stub(rescueModel, 'create', async (u, r) => { seen = r; return h.ok([], { o_rescue_no: 'RSC-000043', o_warning: null }); });
  h.stub(rescueModel, 'list', async () => h.ok([[{ rescueNo: 'RSC-000043', status: 'Requested', urgent: 1, isOpen: 1, canCancel: 1, chargeable: 1, oneWayKm: null,
    sceneContactName: h.crypto.encrypt('Pedro'), timeline: [{ id: 2, status: 'Verified', at: '2026-11-19 02:00:00.000000' }, { id: 1, status: 'Requested', at: '2026-11-19 01:00:00.000000' }],
    costLines: null, photos: null, notified: null, hire: { gatePassNo: null } }], [{ total: 1 }]]));
  const r = await c.post('/portal/rescue', { chassisNo: 'CH-1', locationText: 'NLEX', incident: 'flat', sceneContactName: 'Pedro', sceneContactPhone: '0917 123 4567', urgent: true,
    photos: ['11111111-2222-4333-8444-555555555555', 'not-a-uuid'] });
  assert.equal(r.status, 201);
  assert.match(seen.sceneContactName, ENC);
  assert.match(seen.sceneContactPhone, ENC);
  assert.deepEqual(seen.photos, ['11111111-2222-4333-8444-555555555555']);
  assert.equal(r.body.sceneContactName, 'Pedro');
  assert.equal(r.body.urgent, true);
  assert.equal(r.body.isOpen, true);
  assert.deepEqual(r.body.timeline, [{ status: 'Requested', at: '2026-11-19T01:00:00.000Z' }, { status: 'Verified', at: '2026-11-19T02:00:00.000Z' }]);
  assert.deepEqual([r.body.photos, r.body.costLines, r.body.notified, r.body.hire], [[], [], [], null]);
});

test('EWA and rescue routes are client-portal only', async () => {
  const c = h.client(); await h.signIn(c, { realm: 'VENDOR_PORTAL', userId: 'U-000009', clientCode: null, vendorId: 'V-001' });
  assert.equal((await c.get('/portal/ewa')).status, 403);
  assert.equal((await c.post('/portal/rescue', {})).status, 403);
  assert.equal((await h.client().get('/portal/rescue')).status, 401);
});
