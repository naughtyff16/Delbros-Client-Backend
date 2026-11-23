// Vendor portal (10_sp_vendor.sql).
const { call, ERR, ERR_F } = require('./procedure');

module.exports = {
  data: (userId) => call('sp_vendor_portal_data', [userId], ERR),
  uploadInvoice: (userId, v, src) => call('sp_vendor_invoice_upload', [userId, v.poNo, v.invoiceNo, v.invoiceDate, v.fileId, v.lines, v.resubmitOf, src], ['o_vendor_invoice_id', ...ERR_F]),
};
