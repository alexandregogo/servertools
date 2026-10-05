#!/usr/bin/env bash
set -Eeuo pipefail

readonly FTP_USER="ubuntu"
readonly VSFTPD_CONF="/etc/vsftpd.conf"
readonly CERT_FILE="/etc/ssl/certs/vsftpd-ubuntu.crt"
readonly KEY_FILE="/etc/ssl/private/vsftpd-ubuntu.key"
readonly USERLIST_FILE="/etc/vsftpd.userlist"
readonly PASSIVE_PORTS="40000:40100"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root (for example: sudo $0)." >&2
    exit 1
fi

if [[ "$(. /etc/os-release && echo "${ID}:${VERSION_ID}")" != "ubuntu:22.04" ]]; then
    echo "This script supports Ubuntu 22.04 only." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y vsftpd openssl

if ! id "${FTP_USER}" >/dev/null 2>&1; then
    echo "Required existing system user '${FTP_USER}' was not found." >&2
    exit 1
fi

readonly FTP_HOME="$(getent passwd "${FTP_USER}" | cut -d: -f6)"
if [[ -z "${FTP_HOME}" || "${FTP_HOME}" != /* ]]; then
    echo "Could not determine an absolute home directory for '${FTP_USER}'." >&2
    exit 1
fi
readonly FTP_ROOT="${FTP_HOME}/norao"
readonly UPLOAD_DIR="${FTP_ROOT}/uploads"

if [[ "$(passwd -S "${FTP_USER}" | awk '{print $2}')" != "P" ]]; then
    echo "The '${FTP_USER}' account has no usable password; set one for FTP login:"
    passwd "${FTP_USER}"
fi

install -d -o root -g root -m 0755 "${FTP_ROOT}"
install -d -o "${FTP_USER}" -g "${FTP_USER}" -m 0750 "${UPLOAD_DIR}"

if [[ -e "${VSFTPD_CONF}" ]]; then
    cp -a "${VSFTPD_CONF}" "${VSFTPD_CONF}.backup.$(date +%Y%m%d%H%M%S)"
fi

if [[ ! -s "${CERT_FILE}" || ! -s "${KEY_FILE}" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:3072 \
        -keyout "${KEY_FILE}" \
        -out "${CERT_FILE}" \
        -subj "/CN=$(hostname -f 2>/dev/null || hostname)"
    chmod 0600 "${KEY_FILE}"
    chmod 0644 "${CERT_FILE}"
fi

cat > "${VSFTPD_CONF}" <<EOF
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
userlist_enable=YES
userlist_deny=NO
userlist_file=/etc/vsftpd.userlist
write_enable=YES
local_umask=022
chroot_local_user=YES
local_root=${FTP_ROOT}
xferlog_enable=YES
connect_from_port_20=YES
pam_service_name=vsftpd
ssl_enable=YES
force_local_logins_ssl=YES
force_local_data_ssl=YES
ssl_sslv2=NO
ssl_sslv3=NO
ssl_tlsv1=NO
ssl_tlsv1_1=NO
ssl_tlsv1_2=YES
rsa_cert_file=/etc/ssl/certs/vsftpd-ubuntu.crt
rsa_private_key_file=/etc/ssl/private/vsftpd-ubuntu.key
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
EOF

printf '%s\n' "${FTP_USER}" > "${USERLIST_FILE}"
chmod 0644 "${USERLIST_FILE}"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow 21/tcp
    ufw allow "${PASSIVE_PORTS}/tcp"
fi

systemctl enable --now vsftpd
systemctl restart vsftpd

echo "vsftpd is installed and running."
echo "Connect to this host on port 21 using explicit FTPS and user ${FTP_USER}."
echo "FTP is confined to ${FTP_ROOT}; upload files to /uploads."
echo "Allow TCP ports 21 and ${PASSIVE_PORTS} in any external firewall."
echo "The server uses a self-signed certificate, so clients will need to trust it."
