#!/bin/sh
# Runs as root (via the macOS admin prompt). $1 = folder holding juice-helper, $2 = user allowed to call it.
set -e
SRC="$1"
USER_NAME="$2"
LABEL=com.omar.juice.helper
BIN=/usr/local/libexec/juice-helper
PLIST=/Library/LaunchDaemons/$LABEL.plist

install -d -o root -g wheel -m 755 /usr/local/libexec
install -o root -g wheel -m 755 "$SRC/juice-helper" "$BIN"

install -d -o root -g wheel -m 755 "/Library/Application Support/Juice"
[ -f "/Library/Application Support/Juice/limit" ] || echo 80 > "/Library/Application Support/Juice/limit"
chmod 644 "/Library/Application Support/Juice/limit"

# Let this user run only these two subcommands without a password.
TMP=$(mktemp)
printf '%s ALL=(root) NOPASSWD: %s powermode *, %s setlimit *\n' "$USER_NAME" "$BIN" "$BIN" > "$TMP"
visudo -cf "$TMP" >/dev/null
install -o root -g wheel -m 440 "$TMP" /etc/sudoers.d/juice
rm -f "$TMP"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/Library/Logs/juice-helper.log</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootout system/$LABEL 2>/dev/null || true
launchctl bootstrap system "$PLIST"
