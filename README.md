README
Zabbix 7.2, PostgreSQL17, PHP8.3, Nginx

Install:

wget -O /tmp/install_zabbix_ru2.sh https://raw.githubusercontent.com/CTEPBEU/zabbix_ubuntu/refs/heads/main/install_zabbix_ru2.sh

chmod +x /tmp/install_zabbix_ru2.sh

sudo /tmp/install_zabbix_ru2.sh

Zabbix is one of the best monitoring tools, but its manual installation is still painful.
I’ve written a bash script that fully deploys Zabbix 7.2 on a fresh Ubuntu 24.04 system — with PostgreSQL, nginx, PHP 8.3, Russian localization, and a ready-to-use web interface. No steps from the manual, no manual configs — everything is automated.
This article breaks down the script, its logic, and key benefits.

Introduction
Zabbix is a powerful monitoring system, but deploying it can be tricky — especially if you want the latest version, PostgreSQL instead of MySQL, and a modern software stack. I got tired of running the same commands manually, so I wrapped everything into a single bash script.

This script:

Installs Zabbix 7.2, PostgreSQL 17, nginx, and PHP 8.3

Configures the database, web interface, locale, and permissions

Works on Ubuntu 24.04 and gets everything ready for login

What the Script Does
The script — available [via link / in the attachment] — performs the following:

1. Check & Prepare

Ensures it's running as root

Installs required dependencies (wget, curl, gnupg, etc.)

2. Add Repositories

PostgreSQL 17 from the official repository

Zabbix 7.2 for Ubuntu 24.04

3. Install Components

postgresql-17, zabbix-server-pgsql, zabbix-frontend-php, zabbix-agent2, nginx, php8.3-* modules

4. Configure Database

Generates a secure password

Creates Zabbix user and database

Imports schema and sets permissions

5. Configure Zabbix & PHP

Writes settings to zabbix_server.conf

Increases PHP limits and sets the timezone

6. Configure nginx & Web Interface

Creates an nginx config with PHP support

Sets permissions and generates zabbix.conf.php with Russian language enabled

7. Finalize

Restarts all services

Enables autostart

Sets OS-level Russian locale

Outputs login credentials
