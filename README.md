# OpenWrt 25.12 x86_64 Builder

Builder berbasis Bash + GitHub Actions untuk menghasilkan image OpenWrt x86_64.

## Isi
- `build.sh`: clone source, update/install feeds, siapkan konfigurasi, compile, dan salin firmware.
- `.github/workflows/build.yml`: workflow manual GitHub Actions.
- `.config.example`: contoh konfigurasi awal.

## Cara pakai lewat GitHub Actions
1. Buat repository GitHub baru.
2. Upload seluruh isi folder ini ke repository.
3. Buka tab **Actions**.
4. Pilih **Build OpenWrt 25.12 x86_64**.
5. Klik **Run workflow**, pilih profile `generic`, lalu jalankan.
6. Setelah selesai, unduh artifact `openwrt-25.12-x86_64-generic`.

## Cara pakai lokal (Ubuntu/Debian)
```bash
sudo apt-get update
sudo apt-get install -y git build-essential
./build.sh build
```

Untuk menu konfigurasi:
```bash
./build.sh menuconfig
```
Simpan `.config` hasil menuconfig di root repository agar dapat dipakai workflow berikutnya.

## Pengaturan
Contoh:
```bash
PROFILE=generic \
IMAGE_SIZE=2048 \
HOSTNAME=Router-Kantor \
PACKAGES="luci luci-ssl kmod-e1000e kmod-igb kmod-r8169 htop nano" \
./build.sh build
```

Profile:
- `generic`: image x86_64 umum; biasanya cocok untuk PC/mini PC modern, UEFI/BIOS sesuai image yang dihasilkan.
- `legacy`: untuk perangkat/boot chain lama. Pastikan profile ini tersedia pada branch yang dipakai.

## Catatan penting
- Branch default disetel ke `openwrt-25.12`. Pastikan branch/tag tersebut tersedia di repositori resmi sebelum build; bila belum tersedia, masukkan branch/tag 25.12 yang benar pada input workflow.
- Nama profile, paket, dan opsi kernel dapat berubah antar-rilis. Periksa `make menuconfig` dan log build jika ada paket yang tidak ditemukan.
- `kmod-*` harus cocok dengan kernel yang dibangun. Jangan menyalin modul dari firmware versi/kernel lain.
- `ROOT_PASSWORD` tidak disetel secara default. Atur password pertama kali melalui LuCI/SSH setelah boot. Jangan masukkan password rahasia ke file repository.
- Image disk akan menghapus isi disk tujuan ketika di-flash. Backup data dan pastikan disk target benar.
- GitHub-hosted runners memiliki batas waktu dan ruang disk; build besar bisa gagal karena kehabisan ruang atau timeout.

## Output
Firmware dan file pendamping disalin ke folder `output/`. Periksa file `*combined-efi.img.gz`, `*combined.img.gz`, atau format yang tersedia pada hasil build sebelum memilih image.
