// Harness smoke test: health, CSRF, auth guard, sign-in and session cookie.
const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./harness');

after(h.stop);

test('health answers without a session', async () => {
  const r = await h.client().get('/health');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { status: 'ok' });
});

test('POST without the CSRF token is refused', async () => {
  const r = await h.client().post('/auth/logout', {}, { noCsrf: true });
  assert.equal(r.status, 403);
  assert.equal(r.body.code, 'CSRF_FAILED');
});

test('portal routes need a session; sign-in gives one', async () => {
  const c = h.client();
  assert.equal((await c.get('/portal/notifications')).status, 401);
  await h.signIn(c);
  const portalModel = require('../App/models/portalModel');
  h.stub(portalModel, 'notifications', async () => h.ok([[{ id: 1, title: 'Hello', read: 0 }]]));
  const r = await c.get('/portal/notifications');
  h.restore();
  assert.equal(r.status, 200);
  assert.equal(r.body.items[0].title, 'Hello');
});

test('a client session cannot open vendor routes', async () => {
  const c = h.client();
  await h.signIn(c);
  const r = await c.get('/vendor/portal');
  assert.equal(r.status, 403);
});
