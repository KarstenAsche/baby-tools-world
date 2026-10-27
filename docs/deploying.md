## Deploying Baby Tools World on Ubuntu

This section records the setup used to run Baby Tools World on an Ubuntu 24.04 VPS. Django runs behind Gunicorn in Docker; Nginx is installed on the host and handles TLS. There is no domain name. The application is served from `https://<your-ip>:8000/`, with the admin at `/admin/`.

The setup was tested with Django 6.0.2, Python 3.12, Docker Compose and Nginx. The instructions below describe this server, not a generic production template. Replace the IP address, repository branch and local paths when deploying elsewhere.

### Request path

```text
Browser -> HTTPS :8000 -> host Nginx
                              |-- /static/ -> storage/staticfiles/
                              |-- /media/  -> storage/media/
                              `-- other requests -> 127.0.0.1:8001
                                                     -> Docker :8000
                                                     -> Gunicorn -> Django
                                                                   `-- SQLite volume
```

The Docker port is bound to the host's loopback address. It is not intended to be accessible from the Internet. Port 80 also handles Let's Encrypt HTTP-01 challenges.

### Server and repository

The deployed host uses Ubuntu, Docker, Docker Compose and host Nginx. These are observed versions, not minimum version requirements. Docker provides the Python runtime, so a Python virtual environment is not needed on the server.

Create an empty directory and clone the repository:

```bash
sudo mkdir -p /var/www/baby-tools-world
sudo chown "$(id -un):$(id -gn)" /var/www/baby-tools-world
cd /var/www/baby-tools-world

git clone git@github.com:KarstenAsche/baby-tools-world.git .
git switch --track origin/feature/add-product-tags
```

If the local branch already exists, use `git switch feature/add-product-tags`. Checking out this branch does not merge it into `main`.

The VPS uses a GitHub SSH key with a non-default filename. Its `~/.ssh/config` contains:

```sshconfig
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_25519
    IdentitiesOnly yes
```

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/config ~/.ssh/id_25519
ssh -T git@github.com
```

### Application configuration

The repository contains `Dockerfile`, `entrypoint.sh`, `compose.prod.yml`, `example.env`, `requirements.txt` and the Django project under `src/`.

The entrypoint supports two modes:

- `APP_ENV=development` starts Django's development server and applies existing migrations.
- `APP_ENV=production` runs `check --deploy`, collects static assets and starts Gunicorn.

An explicit command passed to the container is executed instead of starting the server. For example, `docker compose ... run --rm web python manage.py migrate` runs only the migration command.

`makemigrations` is not part of the entrypoint. Migration files are created during development, reviewed and committed with model changes. The server runs the committed migrations with `migrate`. This follows the workflow in [Django's migration documentation — The Commands](https://docs.djangoproject.com/en/6.0/topics/migrations/#the-commands). Django does not explicitly ban running `makemigrations` at container startup; keeping it out of startup is a deployment decision based on that workflow.

The image creates the `django` account (UID/GID `10001:10001`) and runs the application without root privileges. Bind-mounted folders and the database volume must therefore be writable by UID 10001.

`compose.prod.yml`:

```yaml
services:
  web:
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    ports:
      - "127.0.0.1:8001:8000"
    env_file:
      - .env.production
    environment:
      APP_ENV: production
      APP_PORT: "8000"
      SQLITE_PATH: /app/data/db.sqlite3
    volumes:
      - sqlite_data:/app/data
      - ./storage/media:/app/src/media
      - ./storage/staticfiles:/app/src/staticfiles

volumes:
  sqlite_data:
```

The named volume persists SQLite data across ordinary container replacement. It is not a backup. Media and static files are bind-mounted because Nginx serves them from the host. See [Docker Compose volumes](https://docs.docker.com/reference/compose-file/volumes/).

In `settings.py`, the database filename can be overridden with `SQLITE_PATH`:

```python
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": os.getenv("SQLITE_PATH", str(BASE_DIR / "db.sqlite3")),
    }
}
```

Production also requires `DEBUG=false`, a unique `DJANGO_SECRET_KEY`, the server IP in `ALLOWED_HOSTS`, and secure session/CSRF cookies. Since Nginx terminates TLS, Django uses `SECURE_PROXY_SSL_HEADER` only in production; Nginx must set `X-Forwarded-Proto` itself rather than trust an incoming client header. See the [Django deployment checklist](https://docs.djangoproject.com/en/6.0/howto/deployment/checklist/) and [SECURE_PROXY_SSL_HEADER](https://docs.djangoproject.com/en/6.0/ref/settings/#secure-proxy-ssl-header).

### Secrets and persistent storage

Create `.env.production` on the VPS. It is not kept in Git:

```bash
cd /var/www/baby-tools-world
python3 -c 'import secrets; print(secrets.token_urlsafe(64))'
nano .env.production
```

```dotenv
DEBUG=false
ALLOWED_HOSTS=<your-ip>
DJANGO_SECRET_KEY=REPLACE_WITH_A_FRESH_RANDOM_KEY
AUTHOR=Karsten Asche
```

Use the generated key in the real file; never paste a real key into documentation. The IP in `ALLOWED_HOSTS` has no scheme and no port. `APP_ENV`, `APP_PORT` and `SQLITE_PATH` are already supplied by Compose.

```bash
chmod 600 .env.production
mkdir -p storage/media storage/staticfiles
```

Ensure `.gitignore` excludes at least `.env.production`, `storage/` and SQLite database files. Also exclude these from the Docker build context. `*.env` does **not** match `.env.production`; add `.env.*` explicitly to `.dockerignore`:

```dockerignore
.git
.venv
.env
.env.*
*.env
backups/
storage/
src/db.sqlite3
src/media/
src/staticfiles/
**/__pycache__/
*.pyc
```

If an image was built while a real secret was included in its build context, inspect image history/layers as appropriate and rotate exposed credentials. An ignore rule added afterwards does not remove data from old images.

For a *new, empty* SQLite volume, set ownership before running migrations:

```bash
docker volume create baby-tools-world_sqlite_data
docker run --rm --user root \
  -v baby-tools-world_sqlite_data:/data \
  alpine:3.22 chown -R 10001:10001 /data

sudo chown -R 10001:10001 storage/media storage/staticfiles
```

Do not recreate an existing volume to fix permissions; doing so could lose the database. On the original VPS, these permissions were changed only after a SQLite backup had passed an integrity check.

### Build and start

```bash
cd /var/www/baby-tools-world

docker compose -f compose.prod.yml config --quiet
docker compose -f compose.prod.yml build web

docker compose -f compose.prod.yml run --rm --no-deps web \
  python manage.py makemigrations --check --dry-run

docker compose -f compose.prod.yml run --rm --no-deps web \
  python manage.py migrate

docker compose -f compose.prod.yml up -d web
```

Check the service and its account:

```bash
docker compose -f compose.prod.yml ps
docker compose -f compose.prod.yml logs --tail=40 web
docker compose -f compose.prod.yml exec web id
```

The container should report `uid=10001(django) gid=10001(django)`. Gunicorn listens on port 8000 **inside** Docker; Compose publishes it only at `127.0.0.1:8001` on the host.

Before enabling the reverse proxy, the internal application can be checked with:

```bash
curl -I -H 'Host: <your-ip>' http://127.0.0.1:8001/
curl -I -H 'Host: <your-ip>' http://127.0.0.1:8001/admin/
```

### Nginx and IP-address certificate

Nginx already served a default website on port 80 from `/var/www/html`. The HTTP-01 challenge directory was prepared there:

```bash
sudo mkdir -p /var/www/html/.well-known/acme-challenge
printf 'acme-test\n' | sudo tee /var/www/html/.well-known/acme-challenge/test.txt
curl -i http://<your-ip>/.well-known/acme-challenge/test.txt
```

A local `200 OK` does not by itself establish that the challenge URL is reachable from outside the VPS. Port 80 must also be reachable by Let's Encrypt.

Certbot was installed from Snap because the IP-certificate workflow needs a current version supporting `--ip-address`:

```bash
sudo snap install core
sudo snap refresh core
sudo snap install --classic certbot
# Only when the symlink does not already exist:
sudo ln -s /snap/bin/certbot /usr/local/bin/certbot
certbot --version
```

A staging certificate can be used for an initial validation test, but it is not trusted by browsers. The trusted certificate was requested **without** `--staging`:

```bash
sudo certbot certonly \
  --preferred-profile shortlived \
  --webroot \
  --webroot-path /var/www/html \
  --ip-address <your-ip>

sudo certbot certificates
```

The certificate paths on this VPS are:

```text
/etc/letsencrypt/live/<your-ip>/fullchain.pem
/etc/letsencrypt/live/<your-ip>/privkey.pem
```

The Nginx server block is stored at `/etc/nginx/sites-available/baby-tools-world`:

```nginx
server {
    listen 8000 ssl;
    server_name <your-ip>;

    ssl_certificate /etc/letsencrypt/live/<your-ip>/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/<your-ip>/privkey.pem;

    location /media/ {
        alias /var/www/baby-tools-world/storage/media/;
    }

    location /static/ {
        alias /var/www/baby-tools-world/storage/staticfiles/;
    }

    location / {
        proxy_pass http://127.0.0.1:8001;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

The proxy overwrites `X-Forwarded-Proto` with `https` because this listener accepts TLS only. Check that Nginx can read both the mounted static/media folders and their parent directories.

```bash
sudo ln -s /etc/nginx/sites-available/baby-tools-world \
  /etc/nginx/sites-enabled/baby-tools-world
sudo nginx -t
sudo systemctl reload nginx
```

Test the public endpoint:

```bash
curl -I https://<your-ip>:8000/
curl -I https://<your-ip>:8000/admin/
curl -I https://<your-ip>:8000/admin
curl -I --max-time 5 http://<your-ip>:8000/
```

The observed responses were `200 OK` for the homepage, an admin login redirect for unauthenticated requests, `301 Location: /admin/` for `/admin`, and `400 Bad Request` for plain HTTP sent to the TLS-only port. The last response is not an HTTP-to-HTTPS redirect.

### Certificate renewal

The issued IP certificate is short-lived (about 160 hours). Certbot's Snap installation created a renewal timer. Both the timer and a simulated renewal were tested:

```bash
sudo systemctl list-timers --all | grep -i certbot
sudo certbot renew --dry-run
```

Nginx must reload after a successful renewal. The deploy hook is stored at `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`:

```sh
#!/bin/sh
set -eu

# Load renewed certificates after checking the Nginx configuration.
nginx -t 2>&1
systemctl reload nginx
```

```bash
sudo chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
sudo certbot renew --dry-run --run-deploy-hooks
sudo /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
echo "Exit code: $?"
```

The simulated renewal succeeded and the direct hook test returned exit code `0`. Check future renewals periodically; the short certificate lifetime leaves little room for a broken timer or HTTP-01 challenge.

### Django administrator

For a new database, create an admin account in the running container:

```bash
docker compose -f compose.prod.yml exec web python manage.py createsuperuser
```

The admin login is at `https://<your-ip>:8000/admin/`. Keep the password out of scripts and Git.

### Updating the VPS

Make and test changes locally, commit them to the deployment branch and push to GitHub. On the server:

```bash
cd /var/www/baby-tools-world
git status --short
git pull --ff-only

docker compose -f compose.prod.yml build web
docker compose -f compose.prod.yml run --rm --no-deps web \
  python manage.py makemigrations --check --dry-run
docker compose -f compose.prod.yml run --rm --no-deps web \
  python manage.py migrate
docker compose -f compose.prod.yml up -d --force-recreate web

docker compose -f compose.prod.yml ps
docker compose -f compose.prod.yml logs --tail=40 web
curl -I https://<your-ip>:8000/
```

For day-to-day checks:

```bash
# Follow application logs.
docker compose -f compose.prod.yml logs -f web

# Django configuration checks.
docker compose -f compose.prod.yml exec web python manage.py check
docker compose -f compose.prod.yml exec web python manage.py check --deploy

# Check account and mounted directories.
docker compose -f compose.prod.yml exec web id
docker compose -f compose.prod.yml exec web ls -ld /app/data /app/src/media /app/src/staticfiles
```

Do not run `docker compose down -v` against this deployment. The `-v` flag removes named volumes, including the SQLite database volume.

### Known limitations

`python manage.py check --deploy` still reports two warnings: `security.W004` (HSTS disabled) and `security.W008` (Django's own `SECURE_SSL_REDIRECT` disabled). On this VPS, the public Nginx listener accepts TLS on port 8000 and rejects plain HTTP with a `400`; it does not redirect HTTP to HTTPS. HSTS and redirect behavior were left unchanged, rather than marking the warnings as resolved. Review these choices before reusing the configuration for another deployment.

### Documentation

- [Django 6.0 deployment checklist](https://docs.djangoproject.com/en/6.0/howto/deployment/checklist/)
- [Django 6.0 migrations — The Commands](https://docs.djangoproject.com/en/6.0/topics/migrations/#the-commands)
- [Docker Compose file reference](https://docs.docker.com/reference/compose-file/)
- [Gunicorn deployment](https://docs.gunicorn.org/en/stable/deploy.html)
- [Certbot documentation](https://eff-certbot.readthedocs.io/)