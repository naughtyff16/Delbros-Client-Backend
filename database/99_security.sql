-- =====================================================================================================
-- 99_security.sql : database accounts (least privilege). Run as the RDS master user AFTER all other scripts.
-- Passwords are placeholders — generate real ones and keep them in AWS Secrets Manager, never in code or .env files.
--
--   portal_app     : the Express API on EC2. EXECUTE on procedures only — no direct table access, so a bug or
--                    injection in the API cannot read or change tables outside the procedures' rules.
--   portal_session : express-mysql-session store — the sessions table only.
--   portal_worker  : job / outbox worker — EXECUTE only (same procedures + jobs).
--   portal_readonly: reporting / support — SELECT only, no audit changes.
-- Procedures run with DEFINER rights (the account that created them), which is what lets portal_app use them
-- without table grants. audit_log UPDATE/DELETE is blocked for everyone by triggers.
-- =====================================================================================================
USE delbros_portal;

CREATE USER IF NOT EXISTS 'portal_app'@'%'      IDENTIFIED BY 'CHANGE_ME_IN_SECRETS_MANAGER_1' REQUIRE SSL;
CREATE USER IF NOT EXISTS 'portal_session'@'%'  IDENTIFIED BY 'CHANGE_ME_IN_SECRETS_MANAGER_2' REQUIRE SSL;
CREATE USER IF NOT EXISTS 'portal_worker'@'%'   IDENTIFIED BY 'CHANGE_ME_IN_SECRETS_MANAGER_3' REQUIRE SSL;
CREATE USER IF NOT EXISTS 'portal_readonly'@'%' IDENTIFIED BY 'CHANGE_ME_IN_SECRETS_MANAGER_4' REQUIRE SSL;

GRANT EXECUTE ON delbros_portal.* TO 'portal_app'@'%';
GRANT EXECUTE ON delbros_portal.* TO 'portal_worker'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON delbros_portal.sessions TO 'portal_session'@'%';
GRANT SELECT ON delbros_portal.* TO 'portal_readonly'@'%';

-- Restrict '%' to the VPC in production by creating the users for the EC2 subnet instead, e.g. 'portal_app'@'10.0.%'.
FLUSH PRIVILEGES;
