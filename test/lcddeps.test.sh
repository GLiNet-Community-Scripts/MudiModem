#!/bin/sh
# Behavioural test for src/sbin/mudimodem-lcddeps — the LCD python dependency
# guard added after the 4.8.5 -> 4.10.0 A/B FOTA wiped site-packages and left
# mudi.py / mudi-watch.py crash-looping on ModuleNotFoundError while gl_screen
# kept the panel (2026-08-24).
#
# Runs anywhere: python3, opkg, logger and the init scripts are all stubbed, so
# nothing is installed and no service is touched. $1 = path to the script.
set -eu
SCRIPT="${1:-$(dirname "$0")/../src/sbin/mudimodem-lcddeps}"
[ -f "$SCRIPT" ] || { echo "FAIL: no such script: $SCRIPT" >&2; exit 1; }
SCRIPT=$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

# --- stubs ------------------------------------------------------------------
# python3: imports succeed only for modules listed in $WORK/have
cat > "$BIN/python3" <<'EOF'
#!/bin/sh
# invoked as: python3 -c "import NAME"
mod=$(echo "$2" | sed 's/^import //')
grep -qx "$mod" "$WORK/have" 2>/dev/null && exit 0
exit 1
EOF

# opkg: list-installed reads $WORK/installed; install appends and logs the call
cat > "$BIN/opkg" <<'EOF'
#!/bin/sh
echo "opkg $*" >> "$WORK/opkg.log"
case "$1" in
  list-installed) cat "$WORK/installed" 2>/dev/null ;;
  update) [ -f "$WORK/net_down" ] && exit 1; exit 0 ;;
  install)
      shift
      for a in "$@"; do case "$a" in --*) continue ;; *) pkg=$a ;; esac; done
      echo "$pkg - stub" >> "$WORK/installed"
      # installing pillow is what makes PIL importable, and only if libtiff6
      # is already in — this is the real-world coupling the ordering protects.
      if [ "$pkg" = python3-pillow ]; then
          grep -q '^libtiff6 ' "$WORK/installed" && echo PIL >> "$WORK/have"
      fi
      [ "$pkg" = python3-numpy ] && echo numpy >> "$WORK/have"
      [ "$pkg" = python3-evdev ] && echo evdev >> "$WORK/have"
      exit 0 ;;
esac
exit 0
EOF

cat > "$BIN/logger" <<'EOF'
#!/bin/sh
echo "$*" >> "$WORK/logger.log"
EOF

# init scripts: record that they were asked to start, never actually start
mkdir -p "$WORK/etc/init.d"
for s in mudi mudi-watch; do
  cat > "$WORK/etc/init.d/$s" <<EOF
#!/bin/sh
echo "$s \$1" >> "\$WORK/started.log"
EOF
  chmod +x "$WORK/etc/init.d/$s"
done

chmod +x "$BIN"/*
export WORK
export PATH="$BIN:$PATH"

# The script hardcodes /etc/init.d/... — rewrite those to the stub tree so the
# test can never touch the real services, even if run as root on a device.
sed "s|/etc/init.d/|$WORK/etc/init.d/|g; s|LOCK=/tmp/|LOCK=$WORK/|; s|STAMP=/tmp/|STAMP=$WORK/|" \
    "$SCRIPT" > "$WORK/lcddeps"
chmod +x "$WORK/lcddeps"
S="$WORK/lcddeps"

reset() { : > "$WORK/have"; : > "$WORK/installed"; rm -f "$WORK"/*.log "$WORK"/*.failed "$WORK/net_down"; }

echo "== mudimodem-lcddeps =="

# --- 1. check: all present -> exit 0, silent ---
reset; printf 'numpy\nevdev\nPIL\n' > "$WORK/have"
out=$("$S" check) || fail "check must exit 0 when every module imports"
[ -z "$out" ] || fail "check must be silent on success (got: $out)"
pass "check exits 0 and prints nothing when deps are healthy"

# --- 2. check: missing -> exit 1, names the modules ---
reset; printf 'evdev\n' > "$WORK/have"
out=$("$S" check) && fail "check must exit nonzero when a module is missing"
echo "$out" | grep -q numpy || fail "check must name numpy as missing"
echo "$out" | grep -q PIL   || fail "check must name PIL as missing"
echo "$out" | grep -q evdev && fail "check must NOT name evdev (it imports fine)"
pass "check exits 1 and reports exactly the missing modules"

# --- 3. install: only what is missing, pillow --nodeps, libtiff6 first ---
reset
echo "python3-numpy - 1.24.3" > "$WORK/installed"   # numpy already there
echo numpy > "$WORK/have"
"$S" install >/dev/null 2>&1 || fail "install should succeed with the stub feed"
grep -q 'opkg install python3-numpy' "$WORK/opkg.log" && fail "install must skip already-installed packages"
grep -q 'opkg install --nodeps python3-pillow' "$WORK/opkg.log" \
    || fail "pillow must be installed with --nodeps (libfreetype clash with gl-sdk4-screen-large)"
tiff=$(grep -n 'install libtiff6'  "$WORK/opkg.log" | head -1 | cut -d: -f1)
pill=$(grep -n 'install --nodeps python3-pillow' "$WORK/opkg.log" | head -1 | cut -d: -f1)
[ -n "$tiff" ] || fail "install must install libtiff6"
[ "$tiff" -lt "$pill" ] || fail "libtiff6 must be installed BEFORE pillow (PIL/_imaging.so links it)"
pass "install skips present packages, orders libtiff6 before --nodeps pillow"

# --- 4. install: reports failure against MODULES, not opkg's exit status ---
# A package can install cleanly and still not import — the libtiff6 failure mode.
reset
cat > "$BIN/opkg" <<'EOF'
#!/bin/sh
echo "opkg $*" >> "$WORK/opkg.log"
case "$1" in
  list-installed) cat "$WORK/installed" 2>/dev/null ;;
  update) exit 0 ;;
  install) shift; for a in "$@"; do case "$a" in --*) continue ;; *) pkg=$a ;; esac; done
           echo "$pkg - stub" >> "$WORK/installed"; exit 0 ;;   # installs, nothing imports
esac
exit 0
EOF
chmod +x "$BIN/opkg"
"$S" install >/dev/null 2>&1 && fail "install must fail when modules still do not import after a 'successful' opkg run"
pass "install verifies imports, not opkg exit status"

# --- 5. heal: does not start services when the install failed ---
reset
"$S" heal >/dev/null 2>&1 && fail "heal must fail when deps cannot be installed"
[ -f "$WORK/started.log" ] && fail "heal must NOT start services after a failed install (would re-enter the crash loop)"
pass "heal refuses to start the panel after a failed install"

# --- 6. heal: one failure per boot, no infinite retry ---
# test 5 above left the failure stamp; a second heal must refuse rather than retry
out=$("$S" heal 2>&1 || true)
echo "$out" | grep -q 'already failed this boot' || fail "heal must not retry after a failure until reboot"
pass "heal gives up for the boot rather than looping"

# --- 7. heal: happy path installs then starts BOTH services ---
# restore the working opkg stub
reset
cat > "$BIN/opkg" <<'EOF'
#!/bin/sh
echo "opkg $*" >> "$WORK/opkg.log"
case "$1" in
  list-installed) cat "$WORK/installed" 2>/dev/null ;;
  update) [ -f "$WORK/net_down" ] && exit 1; exit 0 ;;
  install) shift; for a in "$@"; do case "$a" in --*) continue ;; *) pkg=$a ;; esac; done
      echo "$pkg - stub" >> "$WORK/installed"
      [ "$pkg" = python3-pillow ] && echo PIL   >> "$WORK/have"
      [ "$pkg" = python3-numpy  ] && echo numpy >> "$WORK/have"
      [ "$pkg" = python3-evdev  ] && echo evdev >> "$WORK/have"
      exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/opkg"
"$S" heal >/dev/null 2>&1 || fail "heal must succeed when the feed works"
grep -q 'mudi start'       "$WORK/started.log" || fail "heal must start mudi"
grep -q 'mudi-watch start' "$WORK/started.log" || fail "heal must start mudi-watch"
pass "heal installs then starts both LCD services"

# --- 7b. install: forces a reinstall when opkg's DB disagrees with site-packages ---
# Every package marked installed, yet nothing imports. Trusting opkg here would
# report success and hand the panel back to the crash loop.
reset
for p in $(sed -n 's/^LCD_DEPS="\(.*\)"$/\1/p' "$SCRIPT") python3-pillow; do
  echo "$p - stub" >> "$WORK/installed"
done
"$S" install >/dev/null 2>&1 || fail "install must recover when the opkg DB and site-packages diverge"
grep -q -- '--force-reinstall' "$WORK/opkg.log" \
    || fail "install must --force-reinstall when packages look present but modules do not import"
grep -q 'opkg install --nodeps --force-reinstall python3-pillow' "$WORK/opkg.log" \
    || fail "a forced pillow reinstall must keep --nodeps"
pass "install force-reinstalls when opkg's DB and site-packages disagree"

# --- 8. heal: no-op when deps are already healthy ---
reset; printf 'numpy\nevdev\nPIL\n' > "$WORK/have"
"$S" heal >/dev/null 2>&1 || fail "heal must succeed as a no-op when deps are fine"
[ -f "$WORK/started.log" ] && fail "heal must not restart services when nothing was wrong"
pass "heal is a no-op on a healthy box"

# --- 9 & 10. static repo assertions -------------------------------------------
# Only meaningful when run from a checkout. On the device (verify.sh passes
# /usr/sbin/mudimodem-lcddeps) there is no src/ tree, so skip rather than fail —
# verify.sh asserts the installed equivalents separately.
REPO=$(cd "$(dirname "$SCRIPT")/../.." 2>/dev/null && pwd)
if [ -z "$REPO" ] || [ ! -f "$REPO/src/lcd/mudi.init" ]; then
  echo "  -- skipped: static repo assertions (no checkout here)"
  echo "PASS: mudimodem-lcddeps"
  exit 0
fi
cd "$REPO"

# --- 9. static: the init scripts actually call the guard ---
for f in src/lcd/mudi.init src/lcd/mudi-watch.init; do
  grep -q 'mudimodem-lcddeps' "$f" || fail "$f must consult mudimodem-lcddeps before opening a procd instance"
  grep -q 'heal' "$f"              || fail "$f must spawn a heal when the check fails"
  # the guard must come BEFORE procd_open_instance, or procd still crash-loops
  g=$(grep -n 'DEPS" check' "$f" | head -1 | cut -d: -f1)
  o=$(grep -n 'procd_open_instance' "$f" | head -1 | cut -d: -f1)
  [ -n "$g" ] && [ "$g" -lt "$o" ] || fail "$f: dep check must precede procd_open_instance"
done
pass "both init scripts gate procd on the dep check"

# --- 10. static: the dep list lives in ONE place ---
grep -q 'LCD_DEPS=' install.sh && fail "install.sh must not carry its own LCD_DEPS list (drift is what broke the panel)"
grep -q 'mudimodem-lcddeps install' install.sh || fail "install.sh must delegate dep install to mudimodem-lcddeps"
grep -q '/usr/sbin/mudimodem-lcddeps' src/upgrade/keep.d/mudimodem \
    || fail "keep.d must preserve mudimodem-lcddeps (it is the thing that repairs the next FOTA)"
pass "dependency recipe has a single source of truth and survives FOTA"

echo "PASS: mudimodem-lcddeps"
