# Self-Hosted Supabase & Infrastructure Stack

This repository contains a complete Docker Compose setup for self-hosting Supabase, along with a suite of auxiliary services including Nginx (HTTP/3), Authelia (SSO), Mailserver, and a custom Watchdog for backups and monitoring.

## 📋 Prerequisites

*   **OS:** Linux (Ubuntu/Debian recommended) or Windows WSL.
*   **Domain:** A valid domain name (e.g., `example.com`).
*   **Ports:** Ensure ports `80` (HTTP), `443` (HTTPS/QUIC), and `25/465/587` (SMTP) are open on your firewall.
*   **Git:** To clone this repository.

## 🚀 Quick Start

### 1. DNS Configuration
Before starting, create **A Records** pointing to your server's IP for the following subdomains:

*   `@` (root, e.g., `regrade.net`)
*   `api` (Supabase API & Kong)
*   `auth` (Supabase GoTrue)
*   `studio` (Supabase Dashboard - Protected by Authelia)
*   `mail` (Mailserver)
*   `dev` (Development environment)
*   `regradeit` (Secondary app, if used)

### 2. Initialization
We use a helper script to generate secrets, configure Docker, and set up the environment.

1.  Run the initialization script:
    ```bash
    ./scripts/init.sh
    ```
2.  **Follow the prompts:**
    *   **Domain:** Enter your root domain (e.g., `regrade.net`).
    *   **Dashboard Creds:** **Important:** The username and password you enter here will become your **initial Authelia login** to access the Supabase Studio.
    *   **SMTP:** Setup passwords for the internal mailserver.
    *   **Telegram:** (Optional) Enter Bot Token and Chat ID for system alerts/backups.
    *   **Rclone:** Select "yes" if you want to configure Dropbox backups immediately.

### 3. Start the Stack
Once `init.sh` completes, start the services:

```bash
docker compose up -d
```

> **Note:** The first startup may take a few minutes as Nginx negotiates SSL certificates via Certbot and Authelia generates its configuration.

---

## 🔐 Access & Security (Authelia)

The **Supabase Studio** (`studio.yourdomain.com`) is protected behind **Authelia SSO**.

### Admin Access
The default admin user is created **automatically** on the first boot using the `DASHBOARD_USERNAME` and `DASHBOARD_PASSWORD` you provided in the `.env` file (via `init.sh`).

Simply navigate to `https://studio.yourdomain.com` and log in with those credentials.

### Adding Additional Users
If you need to grant access to other team members without sharing the admin credentials, use the registration script:

```bash
./scripts/authelia_register.sh
```
*   Enter a **Username**, **Email**, and **Password**.
*   This will hash the password and append the new user to `volumes/authelia/config/users.yml`.
*   The Authelia container picks up changes to this file automatically (watched).

---

## 🛠 Service Architecture

### Core Supabase
*   **Postgres (v17):** Primary database.
*   **Studio:** The dashboard UI.
*   **Kong:** API Gateway handling routes.
*   **GoTrue (Auth):** User management.
*   **Realtime/Storage/Functions:** Standard Supabase features.

### Infrastructure & Security
*   **Nginx:** configured for **HTTP/3 (QUIC)** and automatic Let's Encrypt SSL management.
*   **Authelia:** Provides protection for the Studio and internal tools. Configuration is auto-generated from `.env` on startup.
*   **Mailserver:** Self-hosted Postfix/Dovecot stack.
*   **Firewall Agent:** A custom Go application (`apps/firewall-agent`) that syncs DB whitelists to `nftables`.

### Monitoring & Backups (Watchdog)
A custom `watchdog` container runs inside the stack:
*   **Backups:** Automatically dumps the Postgres DB, compresses it, and uploads it to Dropbox (via Rclone) based on the cron schedule in `apps/watchdog/cron.d/watchdog`.
*   **Health Checks:** Monitors Docker containers and alerts via Telegram if services die.
*   **Log Watcher:** Greps DB logs for "FATAL" or "CORRUPTION" errors.
*   **Disk Watcher:** Alerts if disk space runs low.

---

## 📂 Volume Management

Data is persisted in the `./volumes` directory. **Do not delete this directory** unless you intend to wipe the server.

*   `volumes/db/data17`: Main Database files.
*   `volumes/storage`: File storage (images/assets).
*   `volumes/nginx`: SSL Certificates and configs.
*   `volumes/mail`: Email data.
*   `volumes/authelia/config`: Stores `users.yml` and the SQLite database.

---

## 🔧 Maintenance Scripts

The `scripts/` folder contains useful utilities:

| Script | Description |
| :--- | :--- |
| `init.sh` | **Setup:** Generates `.env`, installs Docker, configures Rclone. |
| `authelia_register.sh` | **User Mgmt:** Adds **additional** users to the SSO provider. |
| `rclone_setup.sh` | **Backups:** Interactively configures the Rclone remote (Dropbox). |
| `platform-overrides.sh` | **WSL:** Adjusts volumes automatically if running on Windows Subsystem for Linux. |
| `reset.sh` | **Danger:** Stops containers and **wipes** all data/volumes. Use with caution. |
| `dump-files.mjs` | **Debug:** Creates a text dump of all non-binary files for debugging/LLM context. |

---

## 📧 Mail Server

The stack includes a full mail server (`docker-mailserver`).
*   **Configuration:** Handled in `volumes/mail`.
*   **Accounts:** The primary account is created automatically based on the `SMTP_USER` and `SMTP_PASS` provided during `init.sh`.
*   **DKIM/SPF:** Keys are generated in `volumes/mail/config`. You must add the generated DNS TXT records to your domain provider for email deliverability.

## ⚠️ Troubleshooting

1.  **502 Bad Gateway:** Usually means a container is still starting up. Check logs:
    ```bash
    docker compose logs -f studio
    # or
    docker compose logs -f kong
    ```
2.  **SSL Issues:** Check the Nginx/Certbot logs:
    ```bash
    docker compose logs -f nginx
    docker compose logs -f certbot
    ```
3.  **Database Connection:** Ensure `volumes/db/data17` permissions are correct. The `init.sh` script attempts to handle permissions, but `sudo` may be required on some systems.