-- Demo/onboarding seed data for NMS dashboards.
-- Replace with real inventory; delete any row with DELETE FROM <table> WHERE name='...'
-- Safe to re-run (upserts).

-- ============ Devices (routers) ============
INSERT INTO routers (name, ip, vendor, device_role, ownership, is_pop, device_model, zone, device_group, custom_attributes, created_at) VALUES
('core-1', '10.10.10.1',  'MikroTik', 'Router', 'ISP',     TRUE,  'CCR2216',  'core',   'Router', '{"active_protocol":"routeros_api","device_group":"Router","pop":"dhaka-core"}', NOW() - INTERVAL '120 days'),
('core-2', '10.10.10.2',  'MikroTik', 'Router', 'ISP',     TRUE,  'CCR2116',  'core',   'Router', '{"active_protocol":"routeros_api","device_group":"Router","pop":"dhaka-core"}', NOW() - INTERVAL '120 days'),
('edge-dhaka',   '10.10.20.1', 'MikroTik', 'Router', 'ISP',     FALSE, 'CCR2004',  'edge',   'Router', '{"active_protocol":"routeros_api","device_group":"Router","pop":"dhaka-edge"}',  NOW() - INTERVAL '100 days'),
('edge-ctg',     '10.10.30.1', 'MikroTik', 'Router', 'ISP',     FALSE, 'CCR2004',  'edge',   'Router', '{"active_protocol":"routeros_api","device_group":"Router","pop":"ctg-edge"}',     NOW() - INTERVAL '100 days'),
('sw-core-1',    '10.10.10.10','Cisco',    'Switch', 'ISP',     FALSE, 'C9300',    'core',   'Switch', '{"active_protocol":"snmp","pop":"dhaka-core"}',                             NOW() - INTERVAL '90 days'),
('sw-agg-1',     '10.10.20.10','MikroTik', 'Switch', 'ISP',     FALSE, 'CRS328',   'edge',   'Switch', '{"active_protocol":"routeros_api","pop":"dhaka-edge"}',                        NOW() - INTERVAL '90 days'),
('olt-pop-a',    '10.10.40.1', 'BDCOM',    'OLT',    'ISP',     FALSE, 'P3310',    'access', 'OLT',    '{"active_protocol":"snmp","pop":"pop-a"}',                                   NOW() - INTERVAL '80 days'),
('olt-pop-b',    '10.10.40.2', 'BDCOM',    'OLT',    'ISP',     FALSE, 'P3310',    'access', 'OLT',    '{"active_protocol":"snmp","pop":"pop-b"}',                                   NOW() - INTERVAL '80 days')
ON CONFLICT (ip) DO NOTHING;

-- Clean up junk test rows
DELETE FROM routers WHERE name IN ('ljv;lzv', 's;jf');

-- ============ Subscribers ============
INSERT INTO customer_profiles (username, full_name, phone, address, package_name, monthly_fee, balance, next_billing_date, status) VALUES
('shihab',   'Shihab Uddin',   '01712345670', 'Dhanmondi, Dhaka', 'Fiber 100Mbps',    1200, 250,  NOW() + INTERVAL '10 days',  'Active'),
('rahim',    'Abdul Rahim',    '01712345671', 'Mirpur, Dhaka',    'Fiber 50Mbps',      800,  0,   NOW() + INTERVAL '12 days',  'Active'),
('karim',    'Karim Ahmed',    '01712345672', 'Uttara, Dhaka',    'Home 30Mbps',       600, -150, NOW() + INTERVAL '5 days',   'Active'),
('hasan',    'Hasan Mahmud',   '01712345673', 'Agrabad, Ctg',     'Fiber 100Mbps',    1200, 400,  NOW() + INTERVAL '15 days',  'Active'),
('nusrat',   'Nusrat Jahan',   '01712345674', 'Nasirabad, Ctg',   'Home 30Mbps',       600,  75,  NOW() + INTERVAL '8 days',   'Active'),
('jamal',    'Jamal Hossain',  '01712345675', 'Sylhet Sadar',     'Fiber 50Mbps',      800,  0,   NOW() + INTERVAL '20 days',  'Active'),
('farhana',  'Farhana Islam',  '01712345676', 'Bogra Sadar',      'Home 30Mbps',       600, 120,  NOW() + INTERVAL '3 days',   'Active'),
('mehedi',   'Mehedi Hasan',   '01712345677', 'Khulna Sadar',     'Fiber 100Mbps',    1200,  0,   NOW() + INTERVAL '2 days',   'Active'),
('sadia',    'Sadia Rahman',   '01712345678', 'Rajshahi Sadar',   'Home 30Mbps',       600,  -50, NOW() + INTERVAL '25 days',  'Active'),
('tanvir',   'Tanvir Ahmed',   '01712345679', 'Gulshan, Dhaka',   'Business 200Mbps', 3000, 1000, NOW() + INTERVAL '30 days',  'Active')
ON CONFLICT (username) DO NOTHING;

-- A few inactive/churned for realistic ratios
INSERT INTO customer_profiles (username, full_name, phone, address, package_name, monthly_fee, balance, next_billing_date, status) VALUES
('old-user-1', 'Old User One', '01712345680', 'Dhaka', 'Home 30Mbps', 600, 0, NOW() - INTERVAL '30 days', 'Inactive'),
('old-user-2', 'Old User Two', '01712345681', 'Dhaka', 'Home 30Mbps', 600, 0, NOW() - INTERVAL '30 days', 'Inactive')
ON CONFLICT (username) DO NOTHING;

-- ============ BGP sessions ============
INSERT INTO bgp_overview (router_name, local_as, peer_remote_as, peer_state, peer_uptime, uplink_iface, poll_status, updated_at) VALUES
('core-1',      'AS64500', 'AS64000', 'Established', INTERVAL '45 days',  'ether1', 'success', NOW()),
('core-1',      'AS64500', 'AS65001', 'Established', INTERVAL '30 days',  'ether2', 'success', NOW()),
('core-2',      'AS64500', 'AS65002', 'Established', INTERVAL '22 days',  'ether1', 'success', NOW()),
('edge-dhaka',  'AS64501', 'AS65003', 'Established', INTERVAL '60 days',  'sfp1',   'success', NOW()),
('edge-ctg',    'AS64502', 'AS65004', 'Established', INTERVAL '14 days',  'sfp1',   'success', NOW())
ON CONFLICT DO NOTHING;

-- ============ NAS ============
INSERT INTO nas (nasname, shortname, type, ports, secret, server, description) VALUES
('10.10.10.200', 'radius-1', 'other', 1812, 'nms-radius-secret', '10.10.10.50', 'Primary RADIUS NAS'),
('10.10.10.201', 'radius-2', 'other', 1812, 'nms-radius-secret', '10.10.10.50', 'Backup RADIUS NAS')
ON CONFLICT (nasname) DO NOTHING;

-- ============ Sites ============
INSERT INTO sites (name, address, contact_info) VALUES
('Dhaka Core',     'Level 3, DIT Building, Dhaka',        'admin@nms.local'),
('Dhaka Edge',     'Mirpur-10, Dhaka',                   'admin@nms.local'),
('Chittagong Edge','Agrabad, Chattogram',                'ctg@nms.local'),
('Sylhet Access',  'Sylhet Sadar, Sylhet',               'syl@nms.local')
ON CONFLICT (name) DO NOTHING;

SELECT 'seed done' AS status;
