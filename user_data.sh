#!/bin/bash
# =============================================================================
# WordPress EC2 Bootstrap Script
# Amazon Linux 2023 | LAMP + WP-CLI + fail2ban + firewalld + CloudWatch Agent
# Secrets: fetched from AWS SSM Parameter Store at boot (never in plaintext)
# =============================================================================
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

# ─────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────

log()  { echo "=== $* ==="; }
ok()   { echo "    [OK] $*"; }
fail() { echo "    [FAIL] $*" >&2; exit 1; }
safe() { "$@" || true; }

# ─────────────────────────────────────────────
# NON-SENSITIVE CONFIG (injected by Terraform templatefile)
# ─────────────────────────────────────────────

DB_NAME="${db_name}"
DB_USER="${db_user}"
DOMAIN="${domain_name}"
WP_DIR="/var/www/html"
WP_ADMIN_USER="${wp_admin_user}"
WP_ADMIN_EMAIL="${wp_admin_email}"
AWS_REGION="${aws_region}"

# ─────────────────────────────────────────────
# [0/7] FETCH SECRETS FROM SSM PARAMETER STORE
# Passwords never touch disk, never appear in Terraform state,
# never appear in Git — fetched at runtime over encrypted AWS API.
# ─────────────────────────────────────────────

log "[0/7] Fetch secrets from SSM"

# AWS CLI is pre-installed on Amazon Linux 2023
# EC2 IAM role grants ssm:GetParameter on /wordpress/* (see ssm_parameters.tf)

DB_PASSWORD=$(aws ssm get-parameter \
  --name "/wordpress/db_password" \
  --with-decryption \
  --region "$AWS_REGION" \
  --query "Parameter.Value" \
  --output text) || fail "Cannot read /wordpress/db_password from SSM. Did you run scripts/put-ssm-params.sh?"

WP_ADMIN_PASS=$(aws ssm get-parameter \
  --name "/wordpress/wp_admin_password" \
  --with-decryption \
  --region "$AWS_REGION" \
  --query "Parameter.Value" \
  --output text) || fail "Cannot read /wordpress/wp_admin_password from SSM. Did you run scripts/put-ssm-params.sh?"

ok "Secrets fetched from SSM (not logged)"

# ─────────────────────────────────────────────
# [1/7] SYSTEM UPDATE
# ─────────────────────────────────────────────

log "[1/7] System update"
dnf update -y
ok "System updated"

# ─────────────────────────────────────────────
# [2/7] INSTALL LAMP STACK
# ─────────────────────────────────────────────

log "[2/7] Install LAMP stack"
dnf install -y \
  httpd \
  mariadb105-server \
  php php-mysqlnd php-fpm \
  php-xml php-mbstring php-gd php-curl \
  php-zip php-intl php-bcmath \
  fail2ban \
  firewalld

systemctl enable --now httpd mariadb
ok "LAMP stack installed and started"

# ─────────────────────────────────────────────
# [3/7] CONFIGURE MYSQL
# ─────────────────────────────────────────────

log "[3/7] Configure MySQL"

mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL

mysql -u root <<SQL
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

if mysql -u "$DB_USER" -p"$DB_PASSWORD" -e "USE \`$DB_NAME\`;" 2>/dev/null; then
  ok "MySQL configured — DB user verified"
else
  fail "MySQL DB user cannot connect — check credentials in SSM"
fi

# ─────────────────────────────────────────────
# [4/7] INSTALL WP-CLI (with integrity check)
# ─────────────────────────────────────────────

log "[4/7] Install WP-CLI"

WP_CLI_URL="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
WP_CLI_SHA_URL="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.sha512"

curl -sL "$WP_CLI_URL"     -o /tmp/wp-cli.phar
curl -sL "$WP_CLI_SHA_URL" -o /tmp/wp-cli.phar.sha512

cd /tmp
if sha512sum -c wp-cli.phar.sha512; then
  ok "WP-CLI checksum verified"
else
  fail "WP-CLI checksum mismatch — aborting for security"
fi

install -m 0755 /tmp/wp-cli.phar /usr/local/bin/wp
rm -f /tmp/wp-cli.phar /tmp/wp-cli.phar.sha512
cd /

wp --info --allow-root > /dev/null || fail "WP-CLI not functional after install"
ok "WP-CLI installed"

# ─────────────────────────────────────────────
# [5/7] INSTALL & CONFIGURE WORDPRESS
# ─────────────────────────────────────────────

log "[5/7] Install WordPress"

if wp core is-installed --path="$WP_DIR" --allow-root 2>/dev/null; then
  ok "WordPress already installed — skipping download"
else
  rm -f "$WP_DIR/index.html"
  wp core download --path="$WP_DIR" --allow-root

  if [ ! -f "$WP_DIR/wp-config.php" ]; then
    wp config create \
      --path="$WP_DIR" \
      --dbname="$DB_NAME" \
      --dbuser="$DB_USER" \
      --dbpass="$DB_PASSWORD" \
      --dbhost="localhost" \
      --allow-root
  fi

  wp core install \
    --path="$WP_DIR" \
    --url="https://$DOMAIN" \
    --title="$DOMAIN" \
    --admin_user="$WP_ADMIN_USER" \
    --admin_password="$WP_ADMIN_PASS" \
    --admin_email="$WP_ADMIN_EMAIL" \
    --skip-email \
    --allow-root

  wp option update siteurl "https://$DOMAIN" --path="$WP_DIR" --allow-root
  wp option update home    "https://$DOMAIN" --path="$WP_DIR" --allow-root

  if ! grep -q "CloudFront HTTPS proxy fix" "$WP_DIR/wp-config.php"; then
    cat >> "$WP_DIR/wp-config.php" <<'PHP'

/* CloudFront HTTPS proxy fix */
if ( isset( $_SERVER['HTTP_CLOUDFRONT_FORWARDED_PROTO'] ) &&
     $_SERVER['HTTP_CLOUDFRONT_FORWARDED_PROTO'] === 'https' ) {
    $_SERVER['HTTPS'] = 'on';
}
define( 'FORCE_SSL_ADMIN', true );
PHP
  fi

  ok "WordPress installed"
fi

chmod 640 "$WP_DIR/wp-config.php"
chown -R apache:apache "$WP_DIR"
find "$WP_DIR" -type d -exec chmod 755 {} \;
find "$WP_DIR" -type f -exec chmod 644 {} \;
chmod 640 "$WP_DIR/wp-config.php"

wp core is-installed --path="$WP_DIR" --allow-root \
  || fail "WordPress installation check failed"
ok "WordPress installation verified"

# ─────────────────────────────────────────────
# [5b/7] CONFIGURE APACHE
# ─────────────────────────────────────────────

log "[5b/7] Configure Apache"

cat > /etc/httpd/conf.d/wordpress.conf <<'APACHECONF'
<VirtualHost *:80>
    ServerName localhost
    DocumentRoot /var/www/html

    <Directory /var/www/html>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch "^(wp-config\.php|xmlrpc\.php|\.htaccess|\.env)$">
        Require all denied
    </FilesMatch>

    <Directory /var/www/html/wp-content/uploads>
        <FilesMatch "\.php$">
            Require all denied
        </FilesMatch>
    </Directory>

    ErrorLog  /var/log/httpd/wordpress-error.log
    CustomLog /var/log/httpd/wordpress-access.log combined
</VirtualHost>
APACHECONF

httpd -t || fail "Apache config syntax error"
systemctl restart httpd
ok "Apache configured"

# ─────────────────────────────────────────────
# [6/7] HARDEN: fail2ban + firewalld
# ─────────────────────────────────────────────

log "[6/7] Hardening: fail2ban + firewalld"

cat > /etc/fail2ban/jail.d/custom.conf <<'F2B'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled  = true

[apache-auth]
enabled  = true
maxretry = 10

[apache-badbots]
enabled  = true

[apache-noscript]
enabled  = true
F2B

systemctl enable --now fail2ban
ok "fail2ban configured"

systemctl enable --now firewalld
safe firewall-cmd --permanent --set-default-zone=public
safe firewall-cmd --permanent --add-service=http
safe firewall-cmd --permanent --add-service=ssh
safe firewall-cmd --permanent --remove-service=https
firewall-cmd --reload
ok "firewalld configured (ports: 80, 22)"

# ─────────────────────────────────────────────
# [7/7] CLOUDWATCH AGENT
# ─────────────────────────────────────────────

log "[7/7] Install CloudWatch Agent"

dnf install -y amazon-cloudwatch-agent

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWA'
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "cwagent"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/httpd/wordpress-access.log",
            "log_group_name": "/ec2/wordpress/access",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/httpd/wordpress-error.log",
            "log_group_name": "/ec2/wordpress/error",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/user-data.log",
            "log_group_name": "/ec2/wordpress/user-data",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/fail2ban.log",
            "log_group_name": "/ec2/wordpress/fail2ban",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "WordPress/EC2",
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
        "metrics_collection_interval": 60,
        "totalcpu": true
      },
      "disk": {
        "measurement": ["used_percent", "inodes_free"],
        "resources": ["/"],
        "metrics_collection_interval": 60
      },
      "mem": {
        "measurement": ["mem_used_percent", "mem_available"],
        "metrics_collection_interval": 60
      },
      "swap": {
        "measurement": ["swap_used_percent"],
        "metrics_collection_interval": 60
      }
    }
  }
}
CWA

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

systemctl is-active --quiet amazon-cloudwatch-agent \
  || fail "CloudWatch Agent failed to start"
ok "CloudWatch Agent running"

# ─────────────────────────────────────────────
# FINAL HEALTH CHECK
# ─────────────────────────────────────────────

log "Final health check"

CHECKS_PASSED=0
CHECKS_TOTAL=5

check() {
  local name="$1"; shift
  if "$@" &>/dev/null; then
    ok "$name"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
  else
    echo "    [WARN] $name — check failed (non-fatal)"
  fi
}

check "Apache running"            systemctl is-active httpd
check "MariaDB running"           systemctl is-active mariadb
check "fail2ban running"          systemctl is-active fail2ban
check "CloudWatch Agent running"  systemctl is-active amazon-cloudwatch-agent
check "WordPress installed"       wp core is-installed --path="$WP_DIR" --allow-root

echo ""
echo "============================================"
echo " Bootstrap complete: $CHECKS_PASSED/$CHECKS_TOTAL checks passed"
echo " Site:       https://$DOMAIN"
echo " Logs:       /var/log/user-data.log"
echo " CloudWatch: /ec2/wordpress/*"
echo " Secrets:    AWS SSM /wordpress/*"
echo "============================================"
