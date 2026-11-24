#!/bin/sh
# Runs as root (via the macOS admin prompt). Removes everything install-helper.sh added.
LABEL=com.omar.juice.helper
launchctl bootout system/$LABEL 2>/dev/null || true   # the daemon re-enables charging as it exits
sleep 1
rm -f /Library/LaunchDaemons/$LABEL.plist /usr/local/libexec/juice-helper /etc/sudoers.d/juice /Library/Logs/juice-helper.log
rm -rf "/Library/Application Support/Juice"
