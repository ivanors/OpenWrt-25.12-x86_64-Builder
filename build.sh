#!/usr/bin/env bash
# OpenWrt 25.12 x86_64 firmware builder
# Run locally on Ubuntu/Debian or from the included GitHub Actions workflow.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$SCRIPT_DIR}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
WORK_DIR="${WORK_DIR:-$BUILD_DIR/openwrt}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output}"
OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/openwrt/openwrt.git}"
OPENWRT_BRANCH="${OPENWRT_BRANCH:-openwrt-25.12}"
PROFILE="${PROFILE:-generic}"
IMAGE_SIZE="${IMAGE_SIZE:-1024}"
HOSTNAME="${HOSTNAME:-OpenWrt}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
PACKAGES="${PACKAGES:-luci luci-ssl kmod-e1000e kmod-igb kmod-ixgbe kmod-r8169 kmod-usb3 usbutils curl ca-bundle htop nano}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
KEEP_BUILD_DIR="${KEEP_BUILD_DIR:-0}"

log(){ printf '\n\033[1;32m[builder]\033[0m %s\n' "$*"; }
die(){ printf '\n\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Perintah '$1' tidak ditemukan."; }

usage(){
  cat <<'EOF'
OpenWrt 25.12 x86_64 Builder

Usage:
  ./build.sh [menuconfig|build|clean|help]

Environment variables:
  OPENWRT_BRANCH  Git branch/tag (default: openwrt-25.12)
  PROFILE         x86 image profile: generic (default), legacy
  IMAGE_SIZE      Root filesystem size in MB (default: 1024)
  HOSTNAME        Default router hostname (default: OpenWrt)
  ROOT_PASSWORD   Optional root password (empty = no preset password)
  PACKAGES        Space-separated package list
  EXTRA_PACKAGES  Additional packages
  JOBS            Parallel compile jobs (default: nproc)

Examples:
  PROFILE=generic IMAGE_SIZE=2048 ./build.sh build
  PACKAGES="luci luci-ssl luci-app-opkg" ./build.sh build
  ./build.sh menuconfig

Notes:
  - x86/64 generic normally produces combined EFI and BIOS disk images.
  - Verify the exact device/boot mode before flashing.
  - Do not flash an image to a disk containing data you need.
EOF
}

install_deps(){
  need sudo
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
    gettext git libncurses-dev libssl-dev python3 python3-distutils \
    python3-setuptools rsync swig unzip zlib1g-dev file wget curl \
    xsltproc qemu-utils libelf-dev ccache
}

checkout_source(){
  mkdir -p "$BUILD_DIR"
  if [[ -d "$WORK_DIR/.git" ]]; then
    log "Memperbarui source OpenWrt di $WORK_DIR"
    git -C "$WORK_DIR" fetch --depth=1 origin "$OPENWRT_BRANCH"
    git -C "$WORK_DIR" checkout -B "$OPENWRT_BRANCH" FETCH_HEAD
  else
    log "Clone $OPENWRT_REPO ($OPENWRT_BRANCH)"
    git clone --depth=1 --branch "$OPENWRT_BRANCH" "$OPENWRT_REPO" "$WORK_DIR" ||
      die "Branch '$OPENWRT_BRANCH' tidak ditemukan. Periksa nama branch/tag pada repositori OpenWrt."
  fi
}

configure_feeds(){
  cd "$WORK_DIR"
  ./scripts/feeds update -a
  ./scripts/feeds install -a
}

write_config(){
  cd "$WORK_DIR"
  make defconfig

  # Configure x86_64 generic profile and rootfs partition size.
  cat >> .config <<EOF
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_DEVICE_generic=y
CONFIG_TARGET_ROOTFS_PARTSIZE=$IMAGE_SIZE
EOF

  # Add selected packages. Unknown package symbols are ignored by Kconfig;
  # missing packages will be visible in the build log.
  for pkg in $PACKAGES $EXTRA_PACKAGES; do
    printf 'CONFIG_PACKAGE_%s=m\\n' "$pkg" >> .config
  done

  make defconfig
  cp .config "$ROOT_DIR/.config.generated"
}

apply_custom_files(){
  cd "$WORK_DIR"
  mkdir -p files/etc
  printf '%s\n' "$HOSTNAME" > files/etc/hostname

  if [[ -n "$ROOT_PASSWORD" ]]; then
    if ! command -v openssl >/dev/null 2>&1; then
      die "openssl dibutuhkan untuk membuat hash ROOT_PASSWORD."
    fi
    local hash
    hash="$(openssl passwd -6 "$ROOT_PASSWORD")"
    mkdir -p files/etc/uci-defaults
    # UCI defaults run on first boot; set root password without embedding plaintext.
    cat > files/etc/uci-defaults/99-builder-root-password <<EOF
#!/bin/sh
sed -i 's#^root:[^:]*:#root:${hash}:#' /etc/shadow
exit 0
EOF
    chmod 0755 files/etc/uci-defaults/99-builder-root-password
  fi

  # Ensure the image includes the requested packages through a dedicated config fragment.
  # This is merged into .config before build.
  for pkg in $PACKAGES $EXTRA_PACKAGES; do
    grep -q "^CONFIG_PACKAGE_${pkg}=" .config || \
      printf 'CONFIG_PACKAGE_%s=m\n' "$pkg" >> .config
  done
  make defconfig
}

build_firmware(){
  cd "$WORK_DIR"
  log "Mulai compile dengan $JOBS job"
  make download -j"$JOBS"
  make -j"$JOBS" V=s
  mkdir -p "$OUTPUT_DIR"
  if [[ -d bin/targets/x86/64 ]]; then
    cp -a bin/targets/x86/64/. "$OUTPUT_DIR/"
  else
    die "Direktori output bin/targets/x86/64 tidak ditemukan. Build mungkin gagal atau layout target berubah."
  fi
  (cd "$OUTPUT_DIR" && sha256sum * > SHA256SUMS 2>/dev/null || true)
  log "Selesai. Hasil firmware ada di: $OUTPUT_DIR"
  find "$OUTPUT_DIR" -maxdepth 1 -type f -printf '%f\n' | sort
}

main(){
  local action="${1:-build}"
  case "$action" in
    help|-h|--help) usage ;;
    deps) install_deps ;;
    clean) rm -rf "$BUILD_DIR" "$OUTPUT_DIR" "$ROOT_DIR/.config.generated"; log "Build dibersihkan." ;;
    menuconfig)
      checkout_source
      configure_feeds
      write_config
      cd "$WORK_DIR"
      make menuconfig
      cp .config "$ROOT_DIR/.config"
      log "Konfigurasi disimpan ke $ROOT_DIR/.config"
      ;;
    build)
      need git; need make; need python3
      checkout_source
      configure_feeds
      if [[ -f "$ROOT_DIR/.config" ]]; then
        cp "$ROOT_DIR/.config" "$WORK_DIR/.config"
      fi
      write_config
      apply_custom_files
      build_firmware
      if [[ "$KEEP_BUILD_DIR" != "1" ]]; then
        log "Source build dipertahankan untuk rebuild cepat."
      fi
      ;;
    *) usage; die "Aksi tidak dikenal: $action" ;;
  esac
}
main "$@"
