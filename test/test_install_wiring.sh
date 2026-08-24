#!/bin/sh
# Static assertions on install.sh / uninstall.sh wiring. No device needed.
set -eu
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $1" >&2; exit 1; }

# --- LCD (default off) ---
# pillow is installed --nodeps (libfreetype clash with gl-sdk4-screen-large), so
# the shared libs it needs must be listed explicitly. Missing libtiff6 is issue #3.
# The dep recipe moved into src/sbin/mudimodem-lcddeps so the install path and the
# post-FOTA self-heal path cannot drift (that drift is what killed the panel after
# the 4.10 upgrade). Assert against the script that owns it, not install.sh.
grep -q 'libtiff6' src/sbin/mudimodem-lcddeps   || fail "mudimodem-lcddeps must install libtiff6 (pillow --nodeps dep; issue #3)"
grep -q 'mudimodem-lcddeps install' install.sh  || fail "install.sh must delegate LCD dep install to mudimodem-lcddeps"
grep -q 'src/lcd/mudi.py' install.sh            || fail "install.sh does not deploy mudi.py"
grep -q 'src/lcd/mudi-watch.py' install.sh      || fail "install.sh does not deploy mudi-watch.py"
grep -q 'src/lcd/mudi.init' install.sh          || fail "install.sh does not deploy mudi.init"
grep -q 'src/lcd/mudi-watch.init' install.sh    || fail "install.sh does not deploy mudi-watch.init"
grep -q 'src/lcd/mudi.config' install.sh        || fail "install.sh does not seed mudi.config"
# default OFF: installer must NOT enable/start the mudi service
grep -q '/etc/init.d/mudi enable' install.sh    && fail "install.sh must NOT enable mudi (default off)"
grep -q '/etc/init.d/mudi start'  install.sh    && fail "install.sh must NOT start mudi (default off)"
for p in /usr/bin/mudi.py /usr/bin/mudi-watch.py /etc/init.d/mudi /etc/init.d/mudi-watch; do
  grep -q "$p" install.sh || fail "install.sh missing sysupgrade entry: $p"
done
grep -q '/etc/init.d/gl_screen start' uninstall.sh || fail "uninstall.sh must restore gl_screen"
grep -q '/usr/bin/mudi.py' uninstall.sh            || fail "uninstall.sh must remove mudi.py"
grep -qE 'rm.*etc/config/mudi' uninstall.sh        && fail "uninstall.sh must NOT delete user config /etc/config/mudi"

# --- selfupdate + version (previous leaks) ---
grep -q 'src/sbin/mudimodem-selfupdate' install.sh || fail "install.sh must install selfupdate"
grep -q '/usr/sbin/mudimodem-selfupdate' uninstall.sh || fail "uninstall.sh must remove selfupdate"
grep -q '/etc/mudimodem/version.json' install.sh      || fail "install.sh must place version.json"
grep -q '/etc/mudimodem/version.json' uninstall.sh    || fail "uninstall.sh must list version.json (sysupgrade de-register)"

# --- speedtest (parity with deploy.sh) ---
grep -q 'src/views/mudimodem-speedtest.js' install.sh || fail "install.sh must install speedtest chunk"
grep -q 'src/menu/mudimodem-speedtest.json' install.sh || fail "install.sh must install speedtest menu"
grep -q 'tools/mudimodem-speedtest.py' install.sh || fail "install.sh must install speedtest runner"
grep -q 'src/sbin/mudimodem-speedtestd' install.sh || fail "install.sh must install speedtestd"
grep -q '/www/views/gl-sdk4-ui-mudimodem-speedtest.common.js.gz' uninstall.sh || fail "uninstall must remove speedtest chunk"
grep -q '/usr/sbin/mudimodem-speedtestd' uninstall.sh || fail "uninstall must remove speedtestd"
grep -q 'mudimodem-speedtestd stop' uninstall.sh || fail "uninstall must stop speedtestd before remove"

# --- battery tab (lazy chunk; parity with deploy.sh — was missing, broke curl install) ---
grep -q 'src/views/mudimodem-battery.js' install.sh || fail "install.sh must install battery chunk"
grep -q '/www/views/gl-sdk4-ui-mudimodem-battery.common.js.gz' install.sh || fail "install.sh must register battery chunk in sysupgrade"
grep -q '/www/views/gl-sdk4-ui-mudimodem-battery.common.js.gz' uninstall.sh || fail "uninstall must remove battery chunk"

# --- install destinations must exist as sources ---
# shellcheck disable=SC2016
srcs=$(grep -E '^\s*(gz_install|cp_install)\s+' install.sh | awk '{print $2}')
for s in $srcs; do
  [ -f "$s" ] || fail "install source missing: $s"
done

# --- install/uninstall path parity ---
# Extract install sysupgrade paths and uninstall FILES paths; every install path
# except intentional keeps must appear in uninstall.
install_paths=$(awk '/registering files/,/^echo "  done"/' install.sh \
  | grep -E '^\s*/' | tr -d ' \\' | sed 's/;.*//')
uninstall_paths=$(awk '/^FILES="/,/^"/' uninstall.sh | grep -E '^\s*/' | tr -d ' ')

for p in $install_paths; do
  # /etc/config/mudi is never in sysupgrade list from the loop above (only
  # written conditionally) — if it ever appears, uninstall must keep it.
  echo "$uninstall_paths" | grep -qxF "$p" \
    || fail "install sysupgrade path missing from uninstall FILES: $p"
done

# No accidental enable of LCD on install
grep -E '/etc/init\.d/mudi(-watch)? (enable|start)' install.sh \
  && fail "install must not enable/start mudi services" || true

# --- A/B FOTA persist (e5800 uses /lib/upgrade/keep.d, not sysupgrade.conf) ---
# abfota_update cats keep.d and copies only /etc /usr /lib /bin /sbin /data /var.
# /www is silently dropped, so view chunks must live under /usr/share/mudimodem.
[ -f src/upgrade/keep.d/mudimodem ] || fail "missing src/upgrade/keep.d/mudimodem"
[ -f src/nginx/mudimodem.conf ]     || fail "missing src/nginx/mudimodem.conf"

grep -qxF '/lib/upgrade/keep.d/mudimodem' src/upgrade/keep.d/mudimodem \
  || fail "keep.d must list itself (next upgrade has to see it)"
grep -qxF '/etc/nginx/gl-conf.d/mudimodem.conf' src/upgrade/keep.d/mudimodem \
  || fail "keep.d must list the nginx alias"
grep -qxF '/usr/share/mudimodem/' src/upgrade/keep.d/mudimodem \
  || fail "keep.d must list /usr/share/mudimodem/ (the FOTA-restorable view payload)"
grep -qxF '/usr/lib/oui-httpd/rpc/mudimodem' src/upgrade/keep.d/mudimodem \
  || fail "keep.d must list the rpc plugin"
grep -E '^[[:space:]]*/www/' src/upgrade/keep.d/mudimodem \
  && fail "keep.d must not list /www (abfota silently drops it)" || true

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*|\#*) continue ;;
    /etc/*|/usr/*|/lib/*|/bin/*|/sbin/*|/data/*|/var/*) ;;
    *) fail "keep.d path not in abfota backup prefixes: $line" ;;
  esac
done < src/upgrade/keep.d/mudimodem

grep -q 'location ^~ /views/gl-sdk4-ui-mudimodem' src/nginx/mudimodem.conf \
  || fail "nginx conf must prefix-match /views/gl-sdk4-ui-mudimodem"
grep -q 'root /usr/share/mudimodem/www' src/nginx/mudimodem.conf \
  || fail "nginx conf must root at the persist www tree"
grep -q 'location ^~ /mudimodem/' src/nginx/mudimodem.conf \
  || fail "nginx conf must serve /mudimodem/ (AT library)"

grep -q '/lib/upgrade/keep.d/mudimodem' install.sh \
  || fail "install.sh must install keep.d"
grep -q '/etc/nginx/gl-conf.d/mudimodem.conf' install.sh \
  || fail "install.sh must install nginx conf"
grep -q '/usr/share/mudimodem/www/views' install.sh \
  || fail "install.sh must install the FOTA view payload"
grep -q '/lib/upgrade/keep.d/mudimodem' tools/deploy.sh \
  || fail "deploy.sh must install keep.d"
grep -q '/usr/share/mudimodem/www' tools/deploy.sh \
  || fail "deploy.sh must install the FOTA view payload"

grep -q '/lib/upgrade/keep.d/mudimodem' uninstall.sh \
  || fail "uninstall must remove keep.d"
grep -q '/etc/nginx/gl-conf.d/mudimodem.conf' uninstall.sh \
  || fail "uninstall must remove nginx conf"
grep -q '/usr/share/mudimodem' uninstall.sh \
  || fail "uninstall must remove the persist tree"

echo "install wiring OK"
