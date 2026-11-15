#!/bin/sh
# Runs once, when the postgres data volume is empty (docker-entrypoint-initdb.d).
#
# Two roles:
#   POSTGRES_USER  owns the schema; used only by db-migrate (env/db-migrate.env)
#   APP_DB_USER    used by the services: read/write rows, cannot create or alter tables
#
# ALTER DEFAULT PRIVILEGES applies to every table POSTGRES_USER creates later,
# so tables added by future migrations are granted automatically.
set -eu

psql -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    --set=app_user="$APP_DB_USER" \
    --set=app_password="$APP_DB_PASSWORD" <<'SQL'
CREATE ROLE :"app_user" LOGIN PASSWORD :'app_password';
GRANT USAGE ON SCHEMA public TO :"app_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO :"app_user";
SQL
