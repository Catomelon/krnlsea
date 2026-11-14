#!/usr/bin/env bash
# catosea-setup.sh
# Áp cấu hình Catosea kernel theo README + hardening + nền hỗ trợ Android.
#
# Dùng:
#   ./catosea-setup.sh deps      # cài gói cần thiết (Debian/Ubuntu)
#   ./catosea-setup.sh fetch     # tải source + xác minh PGP + giải nén
#   ./catosea-setup.sh config    # áp fragment + kiểm tra từng dòng
#   ./catosea-setup.sh build     # build bzImage + modules
#   ./catosea-setup.sh run       # chạy thử trong QEMU (cần initramfs.cpio.gz)
#   ./catosea-setup.sh all       # fetch -> config -> build
#
# Tắt bớt phần: WITH_ANDROID=0 hoặc WITH_HARDENING=0
#
# LƯU Ý: script chưa được chạy thử trên cây 7.3.4. Bước `config` tự in ra mọi
# dòng không áp được để bạn xử lý, đừng bỏ qua nó.

set -euo pipefail

KVER="${KVER:-7.3.4}"
BASE_URL="${BASE_URL:-https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT="${FRAGMENT:-$HERE/catosea.fragment}"
HARDENING="${HARDENING:-$HERE/catosea-hardening.fragment}"
ANDROID="${ANDROID:-$HERE/catosea-android.fragment}"
WITH_HARDENING="${WITH_HARDENING:-1}"
WITH_ANDROID="${WITH_ANDROID:-1}"
INITRD="${INITRD:-$HERE/initramfs.cpio.gz}"
SRC="$HERE/linux-$KVER"

# Dòng trong catosea.fragment đã bỏ có chủ đích (xem README, mục "Đã thử và bỏ")
SKIP_RE='^CONFIG_(BPF_LSM|LOCK_DOWN_IN_EFI_SECURE_BOOT)='

deps() {
  sudo apt update
  # Build kernel (README)
  sudo apt install -y build-essential flex bison libelf-dev libssl-dev bc dwarves \
    curl gnupg xz-utils
  # Chạy thử, boot chain, toàn vẹn, TPM, sandbox (dùng ở các bước lộ trình sau)
  sudo apt install -y qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools \
    busybox-static cpio \
    erofs-utils cryptsetup-bin fsverity keyutils \
    sbsigntool systemd-ukify openssl tpm2-tools \
    bubblewrap flatpak xdg-desktop-portal
}

fetch() {
  cd "$HERE"
  [ -f "linux-$KVER.tar.xz" ]   || curl -fLO "$BASE_URL/linux-$KVER.tar.xz"
  [ -f "linux-$KVER.tar.sign" ] || curl -fLO "$BASE_URL/linux-$KVER.tar.sign"

  gpg --locate-keys torvalds@kernel.org gregkh@kernel.org

  # Chữ ký kernel.org ký trên file .tar (chưa nén), nên phải giải nén xz rồi
  # đưa qua stdin. gpg --verify thẳng trên .tar.xz sẽ không khớp.
  # Kết quả cần thấy: "Good signature from ... Greg Kroah-Hartman" (hoặc Linus).
  xz -cd "linux-$KVER.tar.xz" | gpg --verify "linux-$KVER.tar.sign" -

  [ -d "$SRC" ] || tar xf "linux-$KVER.tar.xz"
  echo "Đã tải và xác minh linux-$KVER"
}

config() {
  [ -d "$SRC" ] || { echo "Chưa có $SRC, chạy 'fetch' trước"; exit 1; }
  [ -f "$FRAGMENT" ] || { echo "Không thấy $FRAGMENT (catosea.fragment trong README)"; exit 1; }
  cd "$SRC"

  local frags=("$FRAGMENT")
  if [ "$WITH_HARDENING" = 1 ]; then frags+=("$HARDENING"); fi
  if [ "$WITH_ANDROID" = 1 ];   then frags+=("$ANDROID");   fi
  if [ -f "$HERE/catosea-local.fragment" ]; then frags+=("$HERE/catosea-local.fragment"); fi

  make defconfig
  make kvm_guest.config
  scripts/kconfig/merge_config.sh -m .config "${frags[@]}"

  # Các bước README yêu cầu làm riêng vì có phụ thuộc
  scripts/config -e KEXEC_FILE -e KEXEC_SIG -e KEXEC_SIG_FORCE
  scripts/config -e LOCK_DOWN_KERNEL_FORCE_INTEGRITY
  make olddefconfig

  # Kiểm tra: olddefconfig âm thầm bỏ symbol thiếu phụ thuộc hoặc không tồn tại
  local missing
  missing="$(
    cat "${frags[@]}" \
      | grep -E '^(CONFIG_|# CONFIG_.* is not set)' \
      | grep -Ev "$SKIP_RE" \
      | while IFS= read -r l; do
          grep -qxF "$l" .config || echo "THIẾU: $l"
        done || true
  )"

  for l in CONFIG_KEXEC_SIG_FORCE=y CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY=y; do
    grep -qxF "$l" .config || missing+=$'\n'"THIẾU: $l"
  done

  if [ -n "$missing" ]; then
    echo "$missing"
    echo
    echo "Có dòng không áp được (xem ghi chú đầu mỗi fragment)."
    exit 1
  fi
  echo "OK: mọi dòng trong fragment đã có trong .config"
}

build() {
  cd "$SRC"
  make -j"$(nproc)" bzImage modules
  echo "Kernel: $SRC/arch/x86/boot/bzImage"
  echo "Khóa ký module hiện là khóa tự sinh (chỉ dùng thử nghiệm)."
}

run() {
  [ -f "$INITRD" ] || { echo "Thiếu $INITRD (cần initramfs, ví dụ busybox)"; exit 1; }
  # Cmdline hardening. psi=1 cần cho Android sau này.
  # Khi có UKI đã ký thì cmdline nằm trong UKI, không truyền bằng -append nữa.
  qemu-system-x86_64 -enable-kvm -cpu host -m 4G -smp 4 \
    -kernel "$SRC/arch/x86/boot/bzImage" \
    -initrd "$INITRD" \
    -append "console=ttyS0 lockdown=integrity module.sig_enforce=1 slab_nomerge pti=on vsyscall=none randomize_kstack_offset=on page_alloc.shuffle=1 psi=1" \
    -device virtio-rng-pci \
    -nographic
}

case "${1:-}" in
  deps)   deps ;;
  fetch)  fetch ;;
  config) config ;;
  build)  build ;;
  run)    run ;;
  all)    fetch; config; build ;;
  *)      sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 1 ;;
esac
