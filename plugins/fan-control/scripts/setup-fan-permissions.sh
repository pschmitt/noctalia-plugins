#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Fan Control permissions setup.
#
# Lets the plugin control the fan at runtime WITHOUT root, and without handing
# that capability to every process on the machine. Covers both backends this
# plugin supports — whichever one is actually present on this machine is the
# one that ends up mattering, so both are always set up:
#
#   thinkpad_acpi (/proc/acpi/ibm/fan):
#     1. enables fan_control=1 (needed for manual control) via a
#        plugin-specific file in /etc/modprobe.d,
#     2. installs a udev rule giving the fan_ctl group write access to
#        /proc/acpi/ibm/fan on every module bind.
#
#   hwmon PWM (dell-smm-hwmon's chip name "dell_smm", the gpd_fan module's
#   chip name "gpdfan", or any chip name passed as an extra argument — the
#   same names the plugin's "Extra hwmon chip name" setting accepts):
#     installs a udev rule giving the fan_ctl group write access to that
#     hwmon device's pwm*/pwm*_enable files on every bind.
#
# In both cases: creates the `fan_ctl` group and adds you to it (mode 0664,
# group-owned — never world-writable).
#
# Usage:  sudo ./setup-fan-permissions.sh [extra-hwmon-chip-name ...]
# Idempotent -- safe to re-run.
#
# Afterwards: log out and back in so the group membership applies. A reboot (or
# module reload) is additionally needed if thinkpad_acpi's fan_control was just
# enabled.
# ---------------------------------------------------------------------------
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Error: run as root, e.g. sudo $0" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [ -z "${TARGET_USER}" ]; then
  echo "Error: could not determine the target user (run via sudo, not as raw root)." >&2
  exit 1
fi
EXTRA_HWMON_NAMES=("$@")

GROUP_NAME=fan_ctl
THINKPAD_FAN_PATH=/proc/acpi/ibm/fan
THINKPAD_MODPROBE_FILE=/etc/modprobe.d/99-noctalia-fan-control.conf
THINKPAD_RULE_FILE=/etc/udev/rules.d/99-noctalia-fan-control-thinkpad.rules
HWMON_RULE_FILE=/etc/udev/rules.d/99-noctalia-fan-control-hwmon.rules

if [ ! -w "$(dirname "${THINKPAD_RULE_FILE}")" ]; then
  echo "Cannot write to $(dirname "${THINKPAD_RULE_FILE}") -- this looks like an" >&2
  echo "immutable /etc (e.g. NixOS, where udev rules are generated from system" >&2
  echo "config). See this plugin's README.md for the declarative NixOS setup" >&2
  echo "instead." >&2
  exit 1
fi

CHGRP_BIN="$(command -v chgrp)"
CHMOD_BIN="$(command -v chmod)"
SH_BIN="$(command -v sh)"

echo "Creating group '${GROUP_NAME}' (if missing) and adding ${TARGET_USER}..."
getent group "${GROUP_NAME}" >/dev/null || groupadd "${GROUP_NAME}"
usermod -aG "${GROUP_NAME}" "${TARGET_USER}"

# --- thinkpad_acpi -----------------------------------------------------------

echo "Writing ${THINKPAD_MODPROBE_FILE}..."
echo "options thinkpad_acpi fan_control=1" >"${THINKPAD_MODPROBE_FILE}"

echo "Writing ${THINKPAD_RULE_FILE}..."
cat >"${THINKPAD_RULE_FILE}" <<EOF
ACTION=="add|bind", SUBSYSTEM=="platform", DRIVER=="thinkpad_acpi", RUN+="${CHGRP_BIN} ${GROUP_NAME} ${THINKPAD_FAN_PATH}", RUN+="${CHMOD_BIN} 0664 ${THINKPAD_FAN_PATH}"
EOF

if [ -f "${THINKPAD_FAN_PATH}" ]; then
  chgrp "${GROUP_NAME}" "${THINKPAD_FAN_PATH}"
  chmod 0664 "${THINKPAD_FAN_PATH}"
fi

# --- hwmon PWM ---------------------------------------------------------------

echo "Writing ${HWMON_RULE_FILE}..."
{
  for name in dell_smm gpdfan "${EXTRA_HWMON_NAMES[@]}"; do
    # $$f (not $f): udev's rule-value parser treats a bare "$name" as one of
    # its own substitutions and rejects anything it doesn't recognize, so the
    # literal '$' the shell needs has to be escaped for udev as '$$'.
    echo "SUBSYSTEM==\"hwmon\", ATTR{name}==\"${name}\", RUN+=\"${SH_BIN} -c 'for f in /sys/%p/pwm*; do ${CHGRP_BIN} ${GROUP_NAME} \"\$\$f\"; ${CHMOD_BIN} 0664 \"\$\$f\"; done'\""
  done
} >"${HWMON_RULE_FILE}"

for d in /sys/class/hwmon/hwmon*; do
  [ -e "${d}/name" ] || continue
  n="$(cat "${d}/name" 2>/dev/null || true)"
  for name in dell_smm gpdfan "${EXTRA_HWMON_NAMES[@]}"; do
    if [ "${n}" = "${name}" ]; then
      shopt -s nullglob
      for f in "${d}"/pwm*; do
        chgrp "${GROUP_NAME}" "${f}"
        chmod 0664 "${f}"
      done
      shopt -u nullglob
    fi
  done
done

echo "Reloading udev rules..."
udevadm control --reload-rules
udevadm trigger --action=bind --subsystem-match=platform
udevadm trigger --action=bind --subsystem-match=hwmon

echo
echo "Done. Log out and back in so your new '${GROUP_NAME}' membership applies."
if [ ! -f /sys/module/thinkpad_acpi/parameters/fan_control ] \
   || [ "$(cat /sys/module/thinkpad_acpi/parameters/fan_control)" != "Y" ]; then
  echo "If this is a ThinkPad: reboot (or reload thinkpad_acpi) to apply"
  echo "fan_control=1; until then, changing the fan level will fail."
fi
