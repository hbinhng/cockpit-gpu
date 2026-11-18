#!/usr/bin/env bash
set -euo pipefail

COCKPIT_TAG=372
COCKPIT_SHA256=42fe04b8acc60594e9316077a565c795816d61442a3164ee585544e3f2eedea5
REF=3cb1708ca7de2565d7adc844a6e5ad64a7ad6e25
REPO=hbinhng/cockpit-gpu
DIR=/usr/local/share/cockpit/gpus
LIBEXEC=/usr/local/libexec/cockpit-gpu
UNIT=/etc/systemd/system/cockpit-gpu-usage-collector.service
STATE=/var/lib/cockpit/gpus
BUILD_USER=${SUDO_USER:-}
LOCAL=$(cd -- "$(dirname -- "$0")" && pwd -P)
RESTART=0
UNINSTALL=0
usage() {
  cat <<'HELP'
Usage: sudo ./install.sh [--build-user USER] [--dir PATH] [--ref COMMIT] [--repo OWNER/REPO] [--restart-cockpit] [--uninstall]
Installs from this local checkout; --ref downloads the specified immutable commit.
--dir selects a root-owned plugin directory. Use the same --dir for uninstall.
--restart-cockpit restarts existing Cockpit units after install/uninstall.
--uninstall removes the plugin, collector, service, account and usage data.
HELP
}
while (($#)); do
  case "$1" in
    --build-user|--dir|--ref|--repo)
      (($# >= 2)) || { echo "Missing value for $1" >&2; exit 2; }
      case "$1" in
        --build-user) BUILD_USER=$2;;
        --dir) DIR=$2;;
        --ref) REF=$2; LOCAL=;;
        --repo) REPO=$2;;
      esac
      shift 2;;
    --restart-cockpit) RESTART=1; shift;;
    --uninstall) UNINSTALL=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done
[[ $EUID -eq 0 ]] || { echo 'ERROR: run this installer as root, for example sudo ./install.sh' >&2; exit 1; }
[[ $DIR = /* && $DIR != / && $DIR != *'/../'* && $DIR != */.. ]] || { echo 'ERROR: invalid install directory' >&2; exit 1; }
DIR=$(realpath -m -- "$DIR")
case "$DIR" in /usr/local/share/cockpit/gpus) ;; /usr|/usr/*|/etc|/etc/*|/var|/var/*|/home|/home/*|/root|/root/*|/tmp|/tmp/*|/opt|/opt/*|/boot|/boot/*|/run|/run/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/) echo 'ERROR: custom directory must not be a system or user directory' >&2; exit 1;; esac
# Every existing ancestor must be root-controlled and not group/world writable.
p=$DIR
while [[ $p != / ]]; do
  if [[ -e $p || -L $p ]]; then
    [[ ! -L $p && -d $p && $(stat -c %u "$p") == 0 ]] || { echo "ERROR: unsafe path: $p" >&2; exit 1; }
    mode=$(stat -c %a "$p")
    (( (8#$mode & 0022) == 0 )) || { echo "ERROR: writable path: $p" >&2; exit 1; }
  fi
  p=${p%/*}; [[ -n $p ]] || p=/
done
is_plugin() {
  python3 - "$1/manifest.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        assert json.load(f).get('name') == 'gpus'
except (OSError, ValueError, AssertionError):
    sys.exit(1)
PY
}
if [[ -d $DIR ]] && [[ -n $(find "$DIR" -mindepth 1 -maxdepth 1 -print -quit) ]] && ! is_plugin "$DIR"; then
  echo "ERROR: nonempty directory is not a gpus plugin: $DIR" >&2; exit 1
fi
restart_cockpit() {
  if ((RESTART)); then
    for unit in cockpit.socket cockpit.service cockpit-ws.socket cockpit-ws.service; do
      if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit "; then systemctl restart "$unit"; fi
    done
  else
    echo 'Refresh Cockpit; use --restart-cockpit to restart its services.'
  fi
}
if ((UNINSTALL)); then
  systemctl disable --now cockpit-gpu-usage-collector.service 2>/dev/null || true
  rm -f -- "$UNIT" "$LIBEXEC/cockpit-gpu-usage-collector.py"
  rmdir -- "$LIBEXEC" 2>/dev/null || true
  if [[ -d $DIR ]] && is_plugin "$DIR"; then rm -rf -- "$DIR"; fi
  rm -rf -- "$STATE"
  if id cockpit-gpu >/dev/null 2>&1; then userdel cockpit-gpu; fi
  systemctl daemon-reload 2>/dev/null || true
  restart_cockpit
  exit 0
fi
[[ -n $BUILD_USER ]] && id "$BUILD_USER" >/dev/null 2>&1 && [[ $(id -u "$BUILD_USER") -ne 0 ]] || { echo 'ERROR: specify an existing non-root --build-user (or invoke via sudo)' >&2; exit 1; }
[[ $REF =~ ^[0-9a-f]{40}$ ]] || { echo 'ERROR: --ref must be a full commit SHA' >&2; exit 1; }
[[ $REPO =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || { echo 'ERROR: invalid repository' >&2; exit 1; }
WORK=$(mktemp -d /tmp/cockpit-gpu-build.XXXXXXXX)
trap 'rm -rf -- "$WORK"' EXIT
chown "$BUILD_USER" "$WORK"
# Build and all dependency scripts are run without root privileges.
runuser -u "$BUILD_USER" -- bash -s -- "$WORK" "$LOCAL" "$REPO" "$REF" "$COCKPIT_TAG" "$COCKPIT_SHA256" <<'BUILD'
set -euo pipefail
work=$1 local_source=$2 repo=$3 ref=$4 tag=$5 hash=$6
if [[ -n $local_source ]]; then
  cp -rL -- "$local_source/plugin" "$work/plugin"
else
  curl -fsSL "https://codeload.github.com/$repo/tar.gz/$ref" -o "$work/plugin.tar.gz"
  mkdir "$work/source"
  tar -xzf "$work/plugin.tar.gz" -C "$work/source" --strip-components=1
  cp -rL "$work/source/plugin" "$work/plugin"
fi
curl -fsSL "https://codeload.github.com/cockpit-project/cockpit/tar.gz/refs/tags/$tag" -o "$work/cockpit.tar.gz"
echo "$hash  $work/cockpit.tar.gz" | sha256sum -c -
mkdir "$work/cockpit"
tar -xzf "$work/cockpit.tar.gz" -C "$work/cockpit" --strip-components=1
cp -r "$work/plugin" "$work/cockpit/pkg/cockpit-gpu"
python3 - "$work/cockpit/files.js" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
for key, value in [('entries', '"cockpit-gpu/cockpit-gpu.jsx"'), ('files', '"cockpit-gpu/index.html"')]:
    s, n = re.subn(r'(' + key + r'\s*:\s*\[)', r'\1\n        ' + value + ',', s, count=1)
    if n != 1: raise SystemExit('Cannot patch Cockpit files.js: ' + key)
open(p, 'w', encoding='utf-8').write(s)
PY
cd "$work/cockpit"
npm install --ignore-scripts
NODE_ENV=production ./build.js cockpit-gpu
BUILD
DIST=$WORK/cockpit/dist/cockpit-gpu
for f in cockpit-gpu.js cockpit-gpu.css; do
  if [[ ! -f $DIST/$f && -f $DIST/$f.gz ]]; then
    runuser -u "$BUILD_USER" -- gzip -dk "$DIST/$f.gz"
  fi
done
# Root never reads the build-user-writable tree directly: the build user streams it out with its own
# privileges (tar -h dereferences symlinks as that user), root unpacks into a root-only staging dir.
STAGE=$(mktemp -d /tmp/cockpit-gpu-stage.XXXXXXXX)
trap 'rm -rf -- "$WORK" "$STAGE"' EXIT
chmod 0700 "$STAGE"
mkdir "$STAGE/dist" "$STAGE/plugin"
runuser -u "$BUILD_USER" -- tar -chf - -C "$DIST" . | tar -xf - -C "$STAGE/dist" --no-same-owner --no-same-permissions
runuser -u "$BUILD_USER" -- tar -chf - -C "$WORK/plugin" index.html cockpit-gpu-boot.js po.js cockpit-gpu-usage-collector.py cockpit-gpu-usage-collector.service \
  | tar -xf - -C "$STAGE/plugin" --no-same-owner --no-same-permissions
[[ -z $(find "$STAGE" -mindepth 1 ! -type f ! -type d -print -quit) ]] || { echo 'ERROR: non-regular file in build output' >&2; exit 1; }
for f in manifest.json cockpit-gpu.js cockpit-gpu.css; do [[ -f $STAGE/dist/$f ]] || { echo "ERROR: missing build output $f" >&2; exit 1; }; done
install -d -o root -g root -m 0755 "$DIR" "$LIBEXEC"
rsync -r --delete --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r --chown=root:root "$STAGE/dist/" "$DIR/"
for f in index.html cockpit-gpu-boot.js po.js; do install -o root -g root -m 0644 "$STAGE/plugin/$f" "$DIR/$f"; done
install -o root -g root -m 0755 "$STAGE/plugin/cockpit-gpu-usage-collector.py" "$LIBEXEC/cockpit-gpu-usage-collector.py"
install -o root -g root -m 0644 "$STAGE/plugin/cockpit-gpu-usage-collector.service" "$UNIT"
if ! id cockpit-gpu >/dev/null 2>&1; then useradd --system --no-create-home --shell /usr/sbin/nologin cockpit-gpu; fi
install -d -o cockpit-gpu -g cockpit-gpu -m 0755 "$STATE"
if [[ -f $STATE/usage-summary.json && ! -L $STATE/usage-summary.json ]]; then chown cockpit-gpu:cockpit-gpu "$STATE/usage-summary.json"; fi
systemctl daemon-reload
systemctl enable --now cockpit-gpu-usage-collector.service
restart_cockpit
echo "Installed in $DIR"
