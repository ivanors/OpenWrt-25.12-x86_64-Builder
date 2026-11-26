#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$SCRIPT_DIR}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
WORK_DIR="${WORK_DIR:-$BUILD_DIR/openwrt}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output}"
CONFIG_JSON="${CONFIG_JSON:-$ROOT_DIR/builder-config.json}"
OPENWRT_REPO="${OPENWRT_REPO:-https://git.openwrt.org/openwrt/openwrt.git}"
OPENWRT_BRANCH="${OPENWRT_BRANCH:-v25.12.6}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

log(){ printf '\n\033[1;32m[builder]\033[0m %s\n' "$*"; }
die(){ printf '\n\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Perintah '$1' tidak ditemukan."; }

usage(){
cat <<'EOF'
OpenWrt 25.12 x86_64 Builder v2
  ./build.sh build       Build sesuai builder-config.json
  ./build.sh menuconfig  Buka menuconfig dan simpan .config
  ./build.sh deps        Install dependensi Ubuntu/Debian
  ./build.sh clean       Hapus source build dan output
  ./build.sh help        Bantuan

Environment:
  OPENWRT_BRANCH=v25.12.6 (default)
  JOBS=2
  CONFIG_JSON=builder-config.json
EOF
}

install_deps(){
  need sudo
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
    gettext git libncurses-dev libssl-dev python3 python3-venv rsync \
    swig unzip zlib1g-dev file wget curl xsltproc qemu-utils libelf-dev \
    ccache device-tree-compiler
}

cfg(){
  python3 - "$CONFIG_JSON" "$1" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
v=d
for p in sys.argv[2].split("."):
    v=v.get(p,{}) if isinstance(v,dict) else {}
print(str(v).lower() if isinstance(v,bool) else (v if isinstance(v,(str,int,float)) else ""))
PY
}

cfg_list(){
  python3 - "$CONFIG_JSON" "$1" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
v=d
for p in sys.argv[2].split("."):
    v=v.get(p,{}) if isinstance(v,dict) else {}
if isinstance(v,list):
    print(" ".join(str(x) for x in v))
PY
}

checkout_source(){
  mkdir -p "$BUILD_DIR"
  if [[ -d "$WORK_DIR/.git" ]]; then
    log "Fetch source OpenWrt $OPENWRT_BRANCH"
    git -C "$WORK_DIR" fetch --depth=1 origin "$OPENWRT_BRANCH"
    git -C "$WORK_DIR" checkout -B builder "$OPENWRT_BRANCH"
    git -C "$WORK_DIR" reset --hard FETCH_HEAD
  else
    log "Clone OpenWrt $OPENWRT_BRANCH"
    git clone --depth=1 --branch "$OPENWRT_BRANCH" "$OPENWRT_REPO" "$WORK_DIR"
  fi
}

setup_custom_feeds(){
  cd "$WORK_DIR"
  local feeds="feeds.conf.default"
  touch "$feeds"
  if [[ " $(cfg_list integrations) " == *" passwall "* ]]; then
    grep -q 'builder_passwall_packages' "$feeds" || \
      echo 'src-git builder_passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git' >> "$feeds"
    grep -q 'builder_passwall_luci' "$feeds" || \
      echo 'src-git builder_passwall_luci https://github.com/Openwrt-Passwall/openwrt-passwall.git' >> "$feeds"
  fi
  if [[ " $(cfg_list integrations) " == *" adguardhome "* ]]; then
    grep -q 'builder_adguardhome' "$feeds" || \
      echo 'src-git builder_adguardhome https://github.com/MomoFlora/luci-app-adguardhome.git;main' >> "$feeds"
  fi
  if [[ " $(cfg_list integrations) " == *" openclash "* ]]; then
    grep -q 'builder_openclash' "$feeds" || \
      echo 'src-git builder_openclash https://github.com/vernesong/OpenClash.git' >> "$feeds"
  fi
  ./scripts/feeds update -a
  ./scripts/feeds install -a
}

write_config(){
  cd "$WORK_DIR"
  make defconfig >/dev/null

  local fs bios efi size
  fs="$(cfg filesystem)"; bios="$(cfg boot.bios)"; efi="$(cfg boot.uefi)"
  size="$(cfg rootfs_size_mb)"
  [[ "$size" =~ ^[0-9]+$ ]] || die "rootfs_size_mb harus angka."
  [[ "$fs" == "squashfs" || "$fs" == "ext4" ]] || die "filesystem harus squashfs atau ext4."

  # Start from x86/64 generic and explicitly select filesystem/boot artifacts.
  ./scripts/config -e TARGET_x86 -e TARGET_x86_64 -e TARGET_x86_64_DEVICE_generic
  ./scripts/config --set-val TARGET_ROOTFS_PARTSIZE "$size"
  ./scripts/config -e TARGET_IMAGES_GZIP

  if [[ "$fs" == "squashfs" ]]; then
    ./scripts/config -e TARGET_ROOTFS_SQUASHFS -d TARGET_ROOTFS_EXT4FS
  else
    ./scripts/config -e TARGET_ROOTFS_EXT4FS -d TARGET_ROOTFS_SQUASHFS
  fi
  if [[ "$bios" == "true" ]]; then ./scripts/config -e GRUB_IMAGES; else ./scripts/config -d GRUB_IMAGES; fi
  if [[ "$efi" == "true" ]]; then ./scripts/config -e GRUB_EFI_IMAGES; else ./scripts/config -d GRUB_EFI_IMAGES; fi

  local pkgs
  pkgs="$(cfg_list packages)"
  pkgs="$pkgs $(cfg_list kernel_modules)"
  for pkg in $pkgs; do
    [[ "$pkg" =~ ^[a-zA-Z0-9_+.-]+$ ]] || die "Nama paket tidak valid: $pkg"
    ./scripts/config -e "PACKAGE_${pkg}" 2>/dev/null || true
  done

  # Optional application integrations are opt-in. Feeds are external and can change independently.
  local integrations
  integrations="$(cfg_list integrations)"
  for app in $integrations; do
    case "$app" in
      adguardhome)
        # AdGuard Home daemon and LuCI integration are not guaranteed in the core feed.
        ./scripts/config -e PACKAGE_adguardhome 2>/dev/null || true
        ./scripts/config -e PACKAGE_luci-app-adguardhome 2>/dev/null || true
        ;;
      passwall)
        ./scripts/config -e PACKAGE_luci-app-passwall 2>/dev/null || true
        ./scripts/config -e PACKAGE_luci-app-passwall2 2>/dev/null || true
        ./scripts/config -e PACKAGE_xray-core 2>/dev/null || true
        ;;
      openclash)
        ./scripts/config -e PACKAGE_luci-app-openclash 2>/dev/null || true
        ;;
      *) die "Integrasi tidak dikenal: $app" ;;
    esac
  done

  make defconfig
  cp .config "$ROOT_DIR/.config.generated"
}

apply_firstboot(){
  cd "$WORK_DIR"
  mkdir -p files/etc/uci-defaults
  local hostname lan_ip dns dhcp_start dhcp_limit
  hostname="$(cfg network.hostname)"
  lan_ip="$(cfg network.lan_ip)"
  dns="$(cfg network.dns)"
  dhcp_start="$(cfg network.dhcp_start)"
  dhcp_limit="$(cfg network.dhcp_limit)"

  python3 - "$hostname" "$lan_ip" "$dns" "$dhcp_start" "$dhcp_limit" <<'PY'
import sys,ipaddress,re
hostname,lan_ip,dns,start,limit=sys.argv[1:]
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,62}',hostname): raise SystemExit("Invalid hostname")
ipaddress.ip_interface(lan_ip+"/24")
ipaddress.ip_address(dns)
if not start.isdigit() or not limit.isdigit(): raise SystemExit("DHCP start/limit must be integers")
PY

  cat > files/etc/uci-defaults/99-builder-network <<EOF
#!/bin/sh
uci set system.@system[0].hostname='${hostname}'
uci set network.lan.ipaddr='${lan_ip}'
uci set network.lan.proto='static'
uci set dhcp.lan.start='${dhcp_start}'
uci set dhcp.lan.limit='${dhcp_limit}'
uci set dhcp.lan.leasetime='12h'
uci -q delete dhcp.lan.dhcp_option
uci add_list dhcp.lan.dhcp_option='6,${dns}'
uci commit system
uci commit network
uci commit dhcp
exit 0
EOF
  chmod 0755 files/etc/uci-defaults/99-builder-network
}

build_firmware(){
  cd "$WORK_DIR"
  rm -rf "$OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR"
  log "Download source packages"
  make download -j"$JOBS"
  log "Compile firmware dengan $JOBS jobs"
  make -j"$JOBS" V=s
  mkdir -p "$OUTPUT_DIR"
  find bin/targets/x86/64 -maxdepth 1 -type f \
    \( -name '*.img.gz' -o -name '*.vdi' -o -name '*.vmdk' -o -name '*.iso' -o -name '*.manifest' -o -name '*.buildinfo' -o -name '*.json' \) \
    -exec cp -f {} "$OUTPUT_DIR/" \;
  [[ -n "$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.img.gz' -print -quit)" ]] || \
    die "Tidak ada image .img.gz pada output; periksa log dan konfigurasi."
  (cd "$OUTPUT_DIR" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS)
  log "Build selesai. File ada di $OUTPUT_DIR"
  ls -lh "$OUTPUT_DIR"
}

main(){
  case "${1:-build}" in
    help|-h|--help) usage ;;
    deps) install_deps ;;
    clean) rm -rf "$BUILD_DIR" "$OUTPUT_DIR" "$ROOT_DIR/.config.generated"; log "Clean selesai." ;;
    menuconfig)
      need git; need make; need python3
      checkout_source
      setup_custom_feeds
      cd "$WORK_DIR"
      make menuconfig
      cp .config "$ROOT_DIR/.config"
      ;;
    build)
      need git; need make; need python3
      [[ -f "$CONFIG_JSON" ]] || die "Tidak ada $CONFIG_JSON. Salin builder-config.example.json."
      checkout_source
      setup_custom_feeds
      if [[ -f "$ROOT_DIR/.config" ]]; then cp "$ROOT_DIR/.config" "$WORK_DIR/.config"; fi
      write_config
      apply_firstboot
      build_firmware
      ;;
    *) usage; die "Aksi tidak dikenal: $1" ;;
  esac
}
main "$@"
