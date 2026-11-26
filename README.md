# OpenWrt 25.12 x86_64 Builder v2.0

Builder Bash + local Web UI + GitHub Actions. Target: x86/64 generic.

## Quick start (Ubuntu/Debian)
```bash
sudo apt update
sudo apt install -y git python3
./start-ui.sh
```
Buka `http://127.0.0.1:8787`, pilih paket dan opsi, lalu klik **Build firmware**.
Build berjalan di mesin lokal. Web UI harus tetap terbuka; log dan status dikirim secara live.

Install semua toolchain:
```bash
./build.sh deps
```

## GitHub Actions
1. Push seluruh folder repository ke GitHub.
2. Buka Actions → **OpenWrt 25.12 x86_64 Builder v2**.
3. Run workflow dan tentukan tag OpenWrt (default `v25.12.6`).
4. Workflow membaca `builder-config.json` yang tersimpan di repository.
5. Unduh artifact firmware dari hasil workflow.

Catatan: UI lokal menyimpan `builder-config.json` pada folder repository. Setelah mengubah konfigurasi via UI, commit/push file JSON tersebut agar workflow GitHub memakai konfigurasi yang sama.

## Fitur
- Web UI kategori paket Network, VPN, USB, Storage, Wi-Fi, Kernel Modules.
- Filesystem SquashFS / EXT4.
- BIOS / Legacy dan UEFI image toggle (dapat pilih keduanya).
- Driver NIC dan kernel module melalui package selection.
- Hostname, LAN IP, DNS, DHCP start/limit diterapkan saat first boot.
- Integrasi opt-in AdGuard Home, Passwall/Passwall2, OpenClash.
- Live build log, status/progress indikatif, output listing dan SHA256.
- Output `.img.gz`, manifest/buildinfo/JSON jika tersedia.

## Integrasi pihak ketiga (baca sebelum memilih)
Passwall dan OpenClash berasal dari feed pihak ketiga yang berubah secara independen dari OpenWrt. Feed dan paketnya dapat gagal build atau tidak kompatibel dengan tag yang dipilih. AdGuard Home daemon `adguardhome` berasal dari feed paket OpenWrt; opsi LuCI ditambahkan dari feed komunitas MomoFlora saat integrasi dipilih. Kompatibilitas feed pihak ketiga tetap harus diperiksa dari log build. Periksa log build.

Paket integrasi pihak ketiga tidak diaktifkan secara default. Pilih hanya jika memang diperlukan. Jangan gunakan proxy package dari sumber yang tidak dipercaya.

## Kernel
Menu "Kernel Modules" memilih paket `kmod-*` yang akan dibangun untuk kernel yang sama. Untuk mengubah opsi kernel internal (scheduler, filesystem, netfilter, debug, dll), jalankan:
```bash
./build.sh menuconfig
```
Simpan `.config` hasilnya di root repository dan commit ke GitHub. Kernel module harus dibangun dari tree yang sama dengan kernel image.

## Penting
- Web UI default hanya bind ke `127.0.0.1`. Jangan expose server ini ke jaringan publik; endpoint build menjalankan proses shell.
- Progress persen bersifat perkiraan berbasis tahapan log, bukan persentase kompilasi presisi.
- GitHub Actions hosted runner dapat kehabisan disk atau waktu untuk build penuh. `JOBS=2` dipilih agar lebih aman.
- Uji image di VM terlebih dahulu. Pastikan BIOS/UEFI cocok dan backup disk. Flash image disk dapat menghapus seluruh isi media.
- Konfigurasi LAN default `192.168.1.1`; sesuaikan agar tidak bentrok dengan jaringan lokal.
- Build belum dijalankan pada mesin target oleh generator file ini.
