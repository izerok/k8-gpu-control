#!/bin/bash
# Install the K8 Tune privileged helper on the target machine. Run with sudo.
set -e
cd "$(dirname "$0")"

if [ "$(id -u)" != "0" ]; then
    echo "run with sudo" >&2
    exit 1
fi

install -d -m 755 /usr/local/libexec
install -m 755 -o root -g wheel k8tuned.sh /usr/local/libexec/k8tuned.sh
install -m 644 -o root -g wheel local.k8tune.plist /Library/LaunchDaemons/local.k8tune.plist

install -d -m 777 /Users/Shared/K8Tune
if [ ! -f /Users/Shared/K8Tune/state.plist ]; then
    cat > /Users/Shared/K8Tune/state.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>profile</key>
    <string>balanced</string>
    <key>cap_mhz</key>
    <integer>1200</integer>
    <key>auto</key>
    <false/>
</dict>
</plist>
PLIST
    chmod 666 /Users/Shared/K8Tune/state.plist
fi

launchctl bootout system/local.k8tune 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/local.k8tune.plist

echo "installed. log: /var/log/k8tune.log"
echo "verify: sysctl debug.phx_pm_gfxclk debug.phx_pm_gfx_max"
