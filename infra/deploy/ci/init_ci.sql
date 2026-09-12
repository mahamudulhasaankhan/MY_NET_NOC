-- CI seed data for Playwright E2E tests.
-- Schema is created by the engine's golang-migrate migration
-- (backend/migrations/000001_init_schema.up.sql) at engine startup,
-- so this script only inserts rows and must match the production columns.

INSERT INTO users (username, password_hash, two_factor_enabled, name, role, access_level, idle_timeout_minutes)
VALUES ('shihab', '$2y$10$PfmBkfnZ84rcD2cx.4XaN.RAjYG7aM7inNOWnzifZjKmioM1MFbzS', FALSE, 'CI User', 'super-user', 'full', 480)
ON CONFLICT (username) DO NOTHING;

INSERT INTO feature_configs (feature_id, enabled, allow_auto_shutdown, allowed_roles) VALUES ('dashboard', TRUE, TRUE, 'admin'), ('devices', TRUE, TRUE, 'admin')
ON CONFLICT (feature_id) DO NOTHING;

INSERT INTO routers (name, ip, device_role, custom_attributes)
VALUES ('ci-router-1', '192.0.2.1', 'Router', '{"active_protocol":"ping"}')
ON CONFLICT DO NOTHING;

INSERT INTO sites (name) VALUES ('CI Site')
ON CONFLICT DO NOTHING;

INSERT INTO bgp_overview (router_name, router_ip, local_as, peer_remote_as, peer_state)
VALUES ('ci-router-1', '192.0.2.1', '64512', '65000', 'Established')
ON CONFLICT DO NOTHING;

INSERT INTO nas (nasname, shortname, type, ports, secret)
VALUES ('ci-nas', 'CI-NAS', 'cisco', 1812, 'ci-secret')
ON CONFLICT DO NOTHING;
