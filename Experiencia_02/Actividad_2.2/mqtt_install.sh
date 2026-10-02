#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Mosquitto MQTT installation and configuration
# Ubuntu / Debian
#
# - Installs Mosquitto
# - Creates MQTT username/password
# - Configures TCP listener on port 1883
# - Disables anonymous access
# - Fixes password-file permissions
# - Enables and starts Mosquitto
# ============================================================

MQTT_USER="${1:-esp32}"

MOSQUITTO_DIR="/etc/mosquitto"
PASSWORD_FILE="${MOSQUITTO_DIR}/passwd"
CONFIG_FILE="${MOSQUITTO_DIR}/conf.d/esp32.conf"

echo "============================================"
echo " Mosquitto MQTT setup"
echo "============================================"
echo
echo "MQTT user: ${MQTT_USER}"
echo

# ------------------------------------------------------------
# Must run as root
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run this script as root:"
    echo
    echo "  sudo $0 [mqtt_username]"
    exit 1
fi


# ------------------------------------------------------------
# Ask for MQTT password
# ------------------------------------------------------------

read -rsp "Enter MQTT password for '${MQTT_USER}': " MQTT_PASSWORD
echo

read -rsp "Confirm MQTT password: " MQTT_PASSWORD_CONFIRM
echo

if [[ "${MQTT_PASSWORD}" != "${MQTT_PASSWORD_CONFIRM}" ]]; then
    echo "ERROR: Passwords do not match."
    exit 1
fi

if [[ -z "${MQTT_PASSWORD}" ]]; then
    echo "ERROR: Password cannot be empty."
    exit 1
fi


# ------------------------------------------------------------
# Install Mosquitto
# ------------------------------------------------------------

echo
echo "[1/7] Updating package list..."

apt-get update


echo
echo "[2/7] Installing Mosquitto..."

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    mosquitto \
    mosquitto-clients


# ------------------------------------------------------------
# Stop broker while configuring
# ------------------------------------------------------------

echo
echo "[3/7] Stopping Mosquitto..."

systemctl stop mosquitto 2>/dev/null || true


# ------------------------------------------------------------
# Create password file
# ------------------------------------------------------------

echo
echo "[4/7] Creating MQTT password file..."

rm -f "${PASSWORD_FILE}"

# Avoid using mosquitto_passwd -b so that the password does not
# appear as a command-line argument.
printf '%s\n%s\n' \
    "${MQTT_PASSWORD}" \
    "${MQTT_PASSWORD}" \
    | mosquitto_passwd -c "${PASSWORD_FILE}" "${MQTT_USER}"


# ------------------------------------------------------------
# IMPORTANT: permissions
# ------------------------------------------------------------

chown root:mosquitto "${PASSWORD_FILE}"
chmod 640 "${PASSWORD_FILE}"


echo
echo "Password file:"
ls -l "${PASSWORD_FILE}"


# Verify that the mosquitto service account can read it
if sudo -u mosquitto test -r "${PASSWORD_FILE}"; then
    echo "OK: Mosquitto user can read password file."
else
    echo "ERROR: Mosquitto user cannot read password file."
    exit 1
fi


# ------------------------------------------------------------
# Configure listener
# ------------------------------------------------------------

echo
echo "[5/7] Creating Mosquitto configuration..."

cat > "${CONFIG_FILE}" <<EOF
# ============================================================
# ESP32 MQTT listener
# ============================================================

listener 1883

allow_anonymous false

password_file ${PASSWORD_FILE}
EOF


echo
echo "Configuration:"
echo "--------------------------------------------"
cat "${CONFIG_FILE}"
echo "--------------------------------------------"


# ------------------------------------------------------------
# Validate configuration
# ------------------------------------------------------------


# ------------------------------------------------------------
# Start Mosquitto and use the service startup as validation
# ------------------------------------------------------------

echo
echo "[6/7] Starting and validating Mosquitto..."

systemctl enable mosquitto

# Clear any previous "start-limit-hit" state
systemctl reset-failed mosquitto || true

if systemctl restart mosquitto; then
    echo "Mosquitto started successfully."
else
    echo
    echo "ERROR: Mosquitto failed to start."
    echo

    echo "=== systemd status ==="
    systemctl status mosquitto --no-pager -l || true

    echo
    echo "=== Mosquitto log ==="
    tail -n 50 /var/log/mosquitto/mosquitto.log || true

    echo
    echo "=== journalctl ==="
    journalctl -u mosquitto -n 50 --no-pager || true

    exit 1
fi


# ------------------------------------------------------------
# Verify service and listener
# ------------------------------------------------------------

echo
echo "[7/7] Verifying MQTT broker..."

if systemctl is-active --quiet mosquitto; then
    echo "OK: Mosquitto is running."
else
    echo "ERROR: Mosquitto is not running."
    exit 1
fi


if ss -ltn | grep -q ':1883 '; then
    echo "OK: MQTT port 1883 is listening."
else
    echo "WARNING: Port 1883 does not appear to be listening."
fi


# ------------------------------------------------------------
# Show listening socket
# ------------------------------------------------------------

echo "Listening sockets:"
ss -ltnp | grep ':1883' || true


# ------------------------------------------------------------
# Optional UFW configuration
# ------------------------------------------------------------

if command -v ufw >/dev/null 2>&1; then

    if ufw status | grep -q "Status: active"; then

        echo
        echo "UFW is active."
        echo "Opening TCP port 1883..."

        ufw allow 1883/tcp

    fi
fi


echo
echo "============================================"
echo " Local MQTT test"
echo "============================================"
echo
echo "Subscriber:"
echo
echo "  mosquitto_sub -h localhost -p 1883 \\"
echo "    -u ${MQTT_USER} -P 'PASSWORD' \\"
echo "    -t 'test/#' -v"
echo
echo "Publisher:"
echo
echo "  mosquitto_pub -h localhost -p 1883 \\"
echo "    -u ${MQTT_USER} -P 'PASSWORD' \\"
echo "    -t 'test/hello' -m 'Hello MQTT'"
echo

