#!/bin/bash
# Allow PgBouncer (and other Docker containers) to connect without password
echo "host all all 172.0.0.0/8 trust" >> /var/lib/postgresql/data/pg_hba.conf
psql -U "$POSTGRES_USER" -c "SELECT pg_reload_conf();"
