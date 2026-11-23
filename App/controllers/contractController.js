// Contracts page and renewal / amendment / termination requests.
const contractModel = require('../models/contractModel');
const { asyncHandler, respond } = require('./errorController');
const { str, opt, num, date, source } = require('./helpers');
const log = require('../config/logger').getLogger('contracts'); // internal ids only — no personal data

const uid = (req) => req.session.userId;
const yes = (v) => v === true || v === 1 || v === '1';

// GET /portal/contracts — result sets 2–8 are grouped under each contract.
const list = asyncHandler(async (req, res) => {
  const [contracts, entitlement, rateHistory, onHire, branches, requests, bonds, history] = (await contractModel.list(uid(req))).sets;
  const of = (rows, no) => rows.filter((r) => r.contractNo === no);
  respond(res, { items: contracts.map((c) => {
    const activity = of(branches, c.contractNo).map((b) => ({ ...b, covered: yes(b.covered) }));
    return { ...c, entitlement: of(entitlement, c.contractNo), rateHistory: of(rateHistory, c.contractNo), onHireUnits: of(onHire, c.contractNo),
      branches: { covered: activity.filter((b) => b.covered), activity, outside: activity.filter((b) => !b.covered).map((b) => b.code) },
      requests: of(requests, c.contractNo), bonds: of(bonds, c.contractNo), history: of(history, c.contractNo) };
  }) });
});

const request = asyncHandler(async (req, res) => {
  const b = req.body;
  const { sets } = await contractModel.request(uid(req), str(req.params.contractNo), { kind: str(b.kind), details: str(b.details), termMonths: num(b.termMonths),
    changeArea: opt(b.changeArea), effectiveDate: date(b.effectiveDate) }, source(req));
  log.info(`Contract ${sets[0][0].kind} request ${sets[0][0].id} on ${sets[0][0].contractNo} user=${uid(req)}`);
  respond(res, sets[0][0], 201);
});

module.exports = { list, request };
