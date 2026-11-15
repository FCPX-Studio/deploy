# deploy

The FCPX Studio stack on the VPS: Caddy, Postgres, Redis, the db migrations and every service, in one `docker-compose.yml`.

No code is built here. Each repo publishes its own image to GHCR, and this repo defines how they run together.

```
db repo         git tag v0.1.1 ──CI──> ghcr.io/fcpx-studio/db-migrate:v0.1.1     (DB_MIGRATE_TAG in .env)
AuthAPI repo    push to main  ──CI──> ghcr.io/fcpx-studio/auth-api:latest + :sha-<commit>
                                └──── ssh: docker compose pull auth-api && up -d auth-api
deploy repo     push to main  ──CI── rsync + ssh ──> VPS: docker compose pull && up -d
```

Libraries (`db`, `events`) are released with git tags, because services pin them in `requirements.txt`.
Services are not: every push to main is deployed.

## Layout

```
docker-compose.yml
Caddyfile               # HTTPS + routing: /auth/* -> auth-api, /events/* -> event-api
redis.conf              # AOF on, noeviction (streams are the queue)
postgres/init/          # runs once on an empty volume: creates the services' role
.env.example            # SITE_ADDRESS + image tags          -> .env on the VPS
env/*.env.example       # one per service                    -> env/*.env on the VPS
.github/workflows/deploy.yml
```

`.env` and `env/*.env` hold secrets and only exist on the VPS (gitignored, never uploaded by CI).

## Start order

```
postgres (healthy) ──> db-migrate (alembic upgrade head, exits 0) ──> auth-api, event-api, paddlesync, emailtalker
redis (healthy) ─────────────────────────────────────────────────────┘
```

If a migration fails, no service starts: `docker compose logs db-migrate`.

## Database roles

| Role            | Used by    | Can                                  |
|-----------------|------------|--------------------------------------|
| `POSTGRES_USER` | db-migrate | owns the schema, creates/alters tables |
| `APP_DB_USER`   | services   | SELECT / INSERT / UPDATE / DELETE only |

Tables created by later migrations are granted to `APP_DB_USER` automatically (default privileges).
The role is created by `postgres/init/01-app-role.sh`, which Postgres only runs on an **empty** data volume.

## Releasing

| What changed            | Do                                                                     |
|-------------------------|------------------------------------------------------------------------|
| A service               | Push to its main: its workflow builds the image and restarts it on the VPS |
| The schema (db repo)    | Tag db, set `DB_MIGRATE_TAG` in `~/deploy/.env`, run this repo's Deploy workflow (Actions → Deploy → Run workflow). Then bump the db tag in each service's `requirements.txt` |
| This repo               | Push to main: deploys automatically                                    |

`DB_MIGRATE_TAG` must always be at least the highest db tag pinned by a service (expand → contract, see the db README).

### Rolling back a service

Every image is also published as `:sha-<commit>` (see the package page on GHCR). On the VPS:

```bash
cd ~/deploy
echo 'AUTH_API_TAG=sha-abc1234' >> .env
docker compose up -d auth-api
```

Remove that line once the fix is pushed, otherwise the next deploy keeps running the old image.

### Adding a pending service

`paddlesync` and `emailtalker` are in the `pending` profile until their image exists. To enable one:
1. Copy AuthAPI's `Dockerfile` and `.github/workflows/deploy.yml` into its repo, and change `IMAGE` and `SERVICE`.
2. Give it access to the org secrets (`DB_REPO_TOKEN`, `VPS_*`).
3. Fill `env/<service>.env` on the VPS.
4. Push the service to main: publishes the first image (its deploy job fails, the service isn't defined on the VPS yet).
5. Remove its `profiles` line here and push this repo: pulls the image and starts the service.

Pushing this repo before the image exists fails the Deploy workflow (`docker compose pull` can't find the image).

## First-time setup

### 1. GitHub

- **db and service repos:** the workflows push images with the built-in `GITHUB_TOKEN`. In the org settings, *Packages* must allow members to create packages.
- **Organization secrets** (FCPX-Studio → Settings → Secrets and variables → Actions), each shared with the repos that need it:

  | Secret            | Repos            | Value                                                                 |
  |-------------------|------------------|-----------------------------------------------------------------------|
  | `DB_REPO_TOKEN`   | services         | fine-grained token, *Contents: Read-only* on `FCPX-Studio/db` and `FCPX-Studio/events` |

  and, shared with `deploy` and every service:

  | Secret            | Value                                                                 |
  |-------------------|-----------------------------------------------------------------------|
  | `VPS_HOST`        | VPS IP or hostname                                                    |
  | `VPS_USER`        | the Linux user that runs docker (in the `docker` group)               |
  | `VPS_SSH_KEY`     | private key of a key pair made for CI: `ssh-keygen -t ed25519 -f deploy_key -N ""` |
  | `VPS_KNOWN_HOSTS` | output of `ssh-keyscan -t ed25519 <VPS_HOST>`                         |

### 2. VPS

```bash
# CI key: allow it to log in
cat deploy_key.pub >> ~/.ssh/authorized_keys

# rsync is used by the Deploy workflow
sudo apt install -y rsync

# Pull private images from GHCR: a classic token with only read:packages
# (fine-grained tokens don't work with GHCR). Skip if the packages are public.
docker login ghcr.io -u <github-username>

# Secrets
mkdir -p ~/deploy/env && cd ~/deploy
# copy .env.example and env/*.env.example from this repo, drop the .example suffix, fill them in
chmod 600 .env env/*.env
```

Generate passwords with `openssl rand -base64 32 | tr -d '/+='` (no characters that need URL quoting).
The same values appear in several files: `POSTGRES_*` ↔ `db-migrate.env`, `APP_DB_*` ↔ each service's `DB_*`, `REDIS_PASSWORD` everywhere.

### 3. Switch over from the old AuthAPI stack

The old `AuthAPI/docker-compose.yml` holds ports 80/443, so stop it first:

```bash
cd ~/AuthAPI && docker compose down
```

Then run the Deploy workflow, or by hand: `cd ~/deploy && docker compose pull && docker compose up -d`.

This stack starts its own, empty Postgres. If the old Postgres on `internal-db-network` holds data you need, dump it first (`pg_dump --data-only`) and restore it after db-migrate has created the tables.

## Everyday commands (on the VPS, in `~/deploy`)

```bash
docker compose ps
docker compose logs -f auth-api
docker compose run --rm db-migrate current        # current schema revision
docker compose exec postgres psql -U admin fcpxstudio_db
docker compose up -d                              # apply .env / env/*.env changes
```
