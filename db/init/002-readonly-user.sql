-- ========================================================================
-- Read-only user for the outbox publisher service.
-- Can SELECT outbox tables and INSERT delivery tracking rows.
-- Cannot touch any other table or perform UPDATE/DELETE.
-- ========================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT FROM pg_catalog.pg_roles WHERE rolname = 'readonly_user'
    ) THEN
        CREATE ROLE readonly_user WITH LOGIN PASSWORD 'readonly_pass';
    END IF;
END
$$;

-- Outbox publisher needs to read pending events
GRANT SELECT ON outbox_events TO readonly_user;

-- Outbox publisher needs to read and write delivery tracking
GRANT SELECT ON outbox_delivery_log TO readonly_user;
GRANT INSERT ON outbox_delivery_log TO readonly_user;

-- Outbox publisher reads the derived view for health checks
GRANT SELECT ON outbox_events_current TO readonly_user;

-- RBAC tables (read-only access for permission checking)
GRANT SELECT ON rbac_roles TO readonly_user;
GRANT SELECT ON rbac_role_permissions TO readonly_user;
GRANT SELECT ON rbac_actor_roles TO readonly_user;

-- Consumer-side idempotency tracking
GRANT SELECT ON consumed_events TO readonly_user;
GRANT INSERT ON consumed_events TO readonly_user;

-- Audit log (read-only access for monitoring)
GRANT SELECT ON audit_log TO readonly_user;
