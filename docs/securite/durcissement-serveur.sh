#!/usr/bin/env bash
# Durcissement du serveur Ubuntu (EC2 16.171.40.83) : SSH, pare-feu, fail2ban,
# MySQL limité à la machine, noyau anti-SYN-flood, swap, mises à jour auto.
#
# Usage, sur le serveur :
#   sudo bash durcissement-serveur.sh            # SSH seul ouvert
#   sudo OUVRIR_WEB=1 bash durcissement-serveur.sh   # + ports 80/443
#
# Idempotent : peut être relancé. Garder une session SSH ouverte pendant
# l'exécution et tester une NOUVELLE connexion avant de fermer la première.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Lancer avec sudo."; exit 1; }
OUVRIR_WEB="${OUVRIR_WEB:-0}"

echo "== Paquets"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq ufw fail2ban unattended-upgrades
dpkg-reconfigure -fnoninteractive unattended-upgrades

echo "== Swap (évite que MySQL soit tué faute de mémoire)"
if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
sysctl -qw vm.swappiness=10

echo "== Noyau : SYN cookies, anti-usurpation, pas de redirections"
cat > /etc/sysctl.d/99-durcissement.conf <<'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_fin_timeout = 15
vm.swappiness = 10
EOF
sysctl -q --system

echo "== SSH : clés uniquement, peu de tentatives, connexions lentes coupées"
cat > /etc/ssh/sshd_config.d/99-durcissement.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 20
MaxStartups 10:30:60
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowUsers ubuntu
EOF
sshd -t                                   # refuse de continuer si la config est invalide
systemctl reload ssh 2>/dev/null || systemctl reload sshd

echo "== fail2ban : bannit après 3 échecs, bannissement croissant"
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
findtime = 10m
maxretry = 3
backend = systemd

[sshd]
enabled = true
mode = aggressive

[recidive]
enabled = true
bantime = 1w
findtime = 1d
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

echo "== Pare-feu UFW"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw limit 22/tcp comment 'SSH, 6 connexions/30 s max par IP'
if [ "$OUVRIR_WEB" = 1 ]; then
  ufw allow 80/tcp comment 'HTTP'
  ufw allow 443/tcp comment 'HTTPS'
fi
ufw --force enable

echo "== MySQL : écoute locale seulement, réglages petite machine"
CONF_MYSQL=""
for d in /etc/mysql/mysql.conf.d /etc/mysql/mariadb.conf.d; do
  [ -d "$d" ] && CONF_MYSQL="$d/99-durcissement.cnf"
done
if [ -n "$CONF_MYSQL" ]; then
  cat > "$CONF_MYSQL" <<'EOF'
[mysqld]
bind-address = 127.0.0.1
local_infile = OFF
max_connections = 60
max_connect_errors = 20
wait_timeout = 600
# Petite instance (1-2 Go de RAM)
innodb_buffer_pool_size = 256M
performance_schema = OFF
EOF
  # mysqlx n'existe que sous MySQL (pas MariaDB)
  [ "${CONF_MYSQL#/etc/mysql/mysql.conf.d}" != "$CONF_MYSQL" ] && \
    printf 'mysqlx_bind_address = 127.0.0.1\n' >> "$CONF_MYSQL"
  systemctl restart mysql 2>/dev/null || systemctl restart mariadb

  echo "== Comptes MySQL (à vérifier : aucun hôte '%' ni utilisateur vide)"
  mysql -e "SELECT user, host, plugin, account_locked FROM mysql.user ORDER BY user;" || true
else
  echo "MySQL non trouvé dans /etc/mysql : étape ignorée."
fi

echo
echo "== Terminé. État :"
ufw status verbose
fail2ban-client status sshd
ss -tlnp
