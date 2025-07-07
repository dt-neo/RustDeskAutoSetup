#!/usr/bin/env bash
# ---------------------------------------------------------------
# setup-rustdesk-unattended.sh
#
# Automates unattended RustDesk on Elementary OS 6.1 (LightDM):
#   • Proxy XAUTHORITY under /run/rustdesk
#   • systemd drop-ins for rustdesk.service
#   • LightDM greeter + session hook (seat0 detection fix)
#   • tmpfiles.d rule so /run/rustdesk survives reboot
#
# USAGE: sudo ./setup-rustdesk-unattended.sh
# ---------------------------------------------------------------

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root (sudo)." >&2
  exit 1
fi

echo "⏳  Preparing runtime directory …"
# /run is tmpfs → recreated every boot. tmpfiles.d will restore it later.
mkdir -p /run/rustdesk
chmod 755 /run/rustdesk

echo "⏳  Installing tmpfiles.d rule …"
cat > /etc/tmpfiles.d/rustdesk.conf <<'EOF'
d /run/rustdesk 0755 root root -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/rustdesk.conf

echo "⏳  Writing LightDM hook …"
/usr/bin/install -m 0755 /dev/stdin /usr/local/bin/rustdesk-hook.sh <<'EOF'
#!/usr/bin/env bash
# Safe proxy-Xauthority helper for RustDesk
set -u  # do NOT use -e so we never abort LightDM

MODE="$1"
PROXY=/run/rustdesk/xauthority
mkdir -p /run/rustdesk

if [ "$MODE" = "greeter" ]; then
    # copy greeter cookie
    cp -p /var/lib/lightdm/.Xauthority "$PROXY" 2>/dev/null || :
    chmod 600 "$PROXY" 2>/dev/null || :
    exit 0
fi

if [ "$MODE" = "user" ]; then
    USERNAME=$(loginctl list-sessions --no-legend \
               | awk '$4=="seat0" && $3!="lightdm" {print $3; exit}')
    REAL="/home/$USERNAME/.Xauthority"

    # wait up to 5 s for LightDM to create the user cookie
    for _ in {1..10}; do [ -f "$REAL" ] && break; sleep 0.5; done

    cp -p "$REAL" "$PROXY" 2>/dev/null || :
    chmod 600 "$PROXY" 2>/dev/null || :
fi
exit 0
EOF

echo "⏳  Enabling LightDM hook …"
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/10-rustdesk.conf <<'EOF'
[Seat:*]
greeter-setup-script=/usr/local/bin/rustdesk-hook.sh greeter
session-setup-script=/usr/local/bin/rustdesk-hook.sh user
EOF

echo "⏳  Adding systemd drop-ins for rustdesk.service …"
mkdir -p /etc/systemd/system/rustdesk.service.d

# env drop-in
cat > /etc/systemd/system/rustdesk.service.d/10-env.conf <<'EOF'
[Service]
Environment=DISPLAY=:0
Environment=XAUTHORITY=/run/rustdesk/xauthority
EOF

# override drop-in
cat > /etc/systemd/system/rustdesk.service.d/20-override.conf <<'EOF'
[Unit]
After=lightdm.service
Requires=lightdm.service

[Service]
Restart=always
RestartSec=5

ExecStart=
ExecStart=/usr/bin/rustdesk --service
EOF

echo "⏳  Reloading systemd and (re)starting RustDesk …"
systemctl daemon-reload
systemctl enable --now rustdesk.service

cat <<'DOC'

✅  Installation complete.

NEXT MANUAL STEPS (things this script cannot automate):
────────────────────────────────────────────────────────
1. **Permanent password** – Open the RustDesk GUI once and set
   *Settings → Security → Permanent Password*.  Without that the service
   will still ask for approval.

2. **Wayland must stay disabled** – Elementary already uses X11 on LightDM,
   but if you ever switch to GDM/Wayland this unattended method will not work.

3. **Firewall** – Allow UDP/TCP 21115 and TCP 21116 if you use UFW.

4. **Reboot now** – LightDM must restart to load the new greeter/session
   hooks.  Run:   sudo reboot
DOC
