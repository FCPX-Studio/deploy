#!/bin/sh
# Runs once, when the postgres data volume is empty (docker-entrypoint-initdb.d), after 01-app-role.sh.
#
# DATA_API_DB_USER: DataAPI's login role (public, read-only). A member of catalog_reader, which the
# db migrations grant SELECT on the catalog tables only (Product, ProductVersion, ProductLicense).
# The tables don't exist yet at this point, so the grants themselves live in the migrations
# (db revision 0009). catalog_reader is created here too, so the membership can be granted now.
set -eu

psql -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    --set=reader_user="$DATA_API_DB_USER" \
    --set=reader_password="$DATA_API_DB_PASSWORD" <<'SQL'
CREATE ROLE catalog_reader NOLOGIN;
CREATE ROLE :"reader_user" LOGIN PASSWORD :'reader_password' IN ROLE catalog_reader;
SQL
