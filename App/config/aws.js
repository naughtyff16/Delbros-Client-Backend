// AWS client: Amazon SES only (email). On EC2 the SDK takes credentials from the instance IAM role (no keys in .env).
const { SESv2Client } = require('@aws-sdk/client-sesv2');
const config = require('./index');

module.exports = { ses: new SESv2Client({ region: config.aws.region }) };
