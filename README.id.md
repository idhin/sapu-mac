# sapu mac

**Sapu bersih disk Mac Anda, tanpa kehilangan apa pun.**

**sapu mac** adalah pembersih disk berbasis command line untuk macOS; perintahnya `sapu`. Ia mencari tiga jenis pemborosan:

| Perintah | Yang dicari |
| --- | --- |
| `sapu junk` | Cache, hasil build, dan dependensi terpasang yang bisa dibuat ulang oleh tool-nya |
| `sapu dupes` | **Folder** dan file yang identik, di mana pun letaknya |
| `sapu big` | Apa yang sebenarnya memakan ruang |

Semua perintah hanya melaporkan sampai Anda menyuruhnya bertindak, dan dirancang agar tindakan itu tidak bisa menghilangkan data.

[English](README.md)

## Kenapa perlu pembersih lagi

- **Menemukan folder duplikat, bukan hanya file duplikat.** Dua salinan proyek berisi 40.000 file muncul sebagai satu baris, bukan 40.000 baris.
- **Paham APFS clone.** Saat Anda menduplikasi sesuatu di Finder, macOS menyimpan datanya satu kali saja. Kebanyakan tool melaporkan salinan itu sebagai ruang terbuang; `sapu` memberi tahu bahwa menghapusnya tidak membebaskan apa pun, dan menghitung data bersama satu kali di setiap total.
- **Bisa deduplikasi tanpa menghapus.** `--clone` membiarkan semua path di tempatnya dan membuat file identik berbagi penyimpanan.
- **Hati-hati sejak desain.** Lihat [Keamanan](#keamanan).
- **Cepat.** Folder home berisi 2,8 juta item dipindai dan dibandingkan dalam sekitar 20 detik di Mac seri M.
- **Tanpa dependensi, tanpa jaringan, tanpa telemetri.** Satu binary native yang kecil.

## Instalasi

Unduh binary universal terbaru (Apple silicon dan Intel, macOS 12 ke atas):

```sh
curl -fsSL https://raw.githubusercontent.com/idhin/sapu-mac/main/install.sh | sh
```

Atau build dari source (butuh Xcode atau Command Line Tools):

```sh
git clone https://github.com/idhin/sapu-mac.git
cd sapu-mac
make install          # terpasang di /usr/local/bin; pakai PREFIX=~/.local untuk lokasi lain
```

## Mulai cepat

```sh
sapu              # seberapa penuh disknya?
sapu junk         # apa yang bisa dibuat ulang? (biasanya hasil tercepat)
sapu junk -i      # centang yang mau dibuang, lalu pilih Trash atau hapus
sapu dupes ~/Documents ~/Downloads
sapu big          # ke mana perginya ruang disk?
```

Setiap perintah punya `--help`, dan `--json` untuk dipakai di skrip.

## `sapu junk`

Setiap temuan diberi salah satu dari tiga tanda:

| Tanda | Arti | Dihapus oleh `--delete` |
| --- | --- | --- |
| ● safe | Dibuat atau diunduh ulang secara otomatis | Ya |
| ◐ review | Bisa dibuat ulang, tapi ada harganya atau tidak bisa dipastikan: proyek yang baru disentuh minggu ini, dependensi tanpa lockfile, virtual environment Python, data simulator, model AI yang sudah diunduh, Trash | Hanya dengan `--review`, atau dicentang lewat `-i` |
| ○ info | Hanya dilaporkan, beserta cara yang benar untuk mengosongkannya (misalnya disk image Docker) | Tidak pernah |

Yang dicari:

- **Hasil build proyek**, ditemukan dengan menelusuri folder Anda: `node_modules`, `.next`, `target` (Rust, Maven), `.build` (SwiftPM), `build` (Gradle, Flutter, Xcode, CMake), `Pods`, `.venv`, `vendor` (Composer), `bin`/`obj` (.NET), `.terraform`, cache Unity, Unreal, Godot, dan lainnya. Sebuah folder baru dihitung bila buktinya ada di sebelah atau di dalamnya: `target` butuh `Cargo.toml`, `node_modules` butuh `package.json`, dan folder yang sekadar bernama `build` juga harus berisi hasil keluaran build tool-nya.
- **Tool developer**: Xcode DerivedData, device support, archive, simulator.
- **Cache package manager**: npm, Yarn, pnpm, Bun, Cargo, Go, Gradle, Maven, CocoaPods, pub, pip, uv, Poetry, Homebrew, conda.
- **Cache dan log aplikasi**: `~/Library/Caches`, cache aplikasi sandbox, cache aplikasi Electron.
- **Data aplikasi berukuran besar**: disk Docker dan OrbStack, emulator Android, backup iOS, model AI lokal, installer macOS yang tertinggal.

Opsi yang berguna:

```sh
sapu junk ~/Projects --older-than 3m     # hanya hasil build proyek yang tidak disentuh tiga bulan
sapu junk --only node_modules,xcode-derived-data --delete
sapu junk --skip system                  # biarkan cache aplikasi
sapu junk --delete --dry-run             # tampilkan apa yang akan terjadi
```

## `sapu dupes`

```
Duplicates in ~/Pictures
Scanned 58 items (34.7 MB) in 0.0s · read 33.1 MB to compare contents

  1  FOLDER ×4  5.40 MB each · 7 files                                          frees 10.8 MB
     keep    Holiday Photos
     remove  Backup/2023/Holiday Photos
     remove  Holiday Photos (cloned by Finder)
     remove  Holiday Photos copy
  2  FILE ×3  2.50 MB each                                                      frees 5.01 MB
     keep    Documents/installer.dmg
     remove  Downloads/installer (1).dmg
     remove  Downloads/installer.dmg
```

Tiga cara menindaklanjuti laporan:

```sh
sapu dupes ~/Pictures -i         # tinjau tiap grup dan centang yang mau dibuang
sapu dupes ~/Pictures --trash    # pindahkan salinan bertanda "remove" ke Trash
sapu dupes ~/Pictures --clone    # semua path tetap ada, data identik disimpan satu kali
```

Salinan mana yang dipertahankan ditentukan oleh `--keep auto` (bawaan: yang tidak terlihat seperti salinan, dilihat dari nama seperti `copy`, `(1)`, `salinan`, `backup`, dan dari lokasinya), `--keep oldest`, atau `--keep newest`. `--prefer <path>` mempertahankan salinan di folder pilihan Anda.

Opsi lain: `--min-size 100M`, `--files-only`, `--folders-only`, `--hidden`, `--exclude '*.iso'`.

## `sapu big`

Menampilkan pohon folder terbesar beserta daftar file terbesar. Ukuran adalah ruang di disk, dengan data yang dibagi antar clone dan hard link dihitung satu kali, sehingga angkanya cocok dengan isi disk yang sebenarnya. Opsi: `--depth 3`, `--top 12`, `--files 30`.

## Keamanan

Menghapus hal yang salah adalah satu-satunya kesalahan yang tidak boleh dilakukan pembersih disk. Aturan berikut ditegakkan di kode dan dicakup oleh tes:

1. **Lapor dulu.** Tidak ada perintah yang mengubah apa pun tanpa `-i`, `--trash`, `--delete`, atau `--clone`, dan masing-masing meminta konfirmasi kecuali Anda menambahkan `--yes`. `--dry-run` menampilkan rencananya.
2. **Satu salinan terverifikasi selalu tersisa.** Sebelum sebuah duplikat dihapus, `sapu` memeriksa bahwa salinan lain yang berbeda dari grup yang sama masih ada dan tidak berubah. Pilihan yang akan menghapus semua salinan ditolak. Folder yang bisa dicapai lewat dua path (firmlink, volume yang di-mount dua kali) dikenali sebagai satu folder, bukan salinan dari dirinya sendiri.
3. **Yang sudah berubah tidak disentuh.** Tepat sebelum bertindak, setiap file yang terlibat dibandingkan dengan hasil scan (ukuran, waktu modifikasi sampai nanodetik, inode; untuk folder, setiap isinya). Bila ada yang berubah, item itu dilewati.
4. **Hanya benda utuh.** Sebuah salinan tidak pernah disarankan untuk dihapus bila ia bagian dari sesuatu yang lebih besar: di dalam repositori git, di dalam folder yang merupakan variasi dari folder kembarannya (dua versi satu proyek yang sama-sama punya folder `assets`), atau bersebelahan dengan kembarannya dengan nama yang tidak berhubungan. Salinan seperti itu tetap ditampilkan beserta alasannya dan masih bisa dicentang manual.
5. **Folder milik tool tetap utuh.** Bundle aplikasi, `.git`, `node_modules`, dan hasil build lain dibandingkan sebagai satu kesatuan dan tidak pernah dipreteli per file.
6. **Lokasi sistem terlarang.** `/System`, `/Library`, `/usr`, folder tingkat atas di home Anda, dan path sejenis ditolak oleh penjaga yang dilewati setiap penghapusan.
7. **File cloud tidak diunduh.** File yang hanya ada di iCloud dilewati; membacanya diblokir di tingkat proses.
8. **Trash adalah tujuan bawaan** untuk duplikat, sehingga kesalahan bisa dibatalkan dengan sekali seret.

`--clone` mengganti file duplikat dengan APFS clone dari kembarannya. Clone itu dibandingkan byte demi byte dengan file yang akan digantikannya; path tersebut mempertahankan izin, tanggal, extended attribute, dan tag Finder miliknya; pertukarannya berupa satu rename atomik. Tutup dulu aplikasi yang sedang membuka file tersebut (virtual machine, database): program yang masih memegang file lama akan terus menulis ke file yang sudah tidak punya nama.

### Batasan yang diketahui

- Perubahan dikenali lewat ukuran, waktu modifikasi, dan inode. Program yang mengubah file lewat memory map tanpa menggeser waktu modifikasinya, di antara scan dan penghapusan, tidak akan terdeteksi. Karena itu file yang dicocokkan hanya lewat clone ID APFS dibaca dan dibandingkan lagi tepat sebelum dihapus.
- Extended attribute selain resource fork tidak dibandingkan, jadi dua file yang hanya berbeda di tag Finder dianggap identik.
- Aturan junk mengenali folder dari nama ditambah bukti di sebelah atau di dalamnya. Tanda `review` dipakai saat bukti itu tidak bisa memastikan tidak ada milik Anda di dalamnya.
- Jalankan sebagai user biasa. `sudo` tidak diperlukan dan memperluas jangkauan sebuah kesalahan.

## Cara kerja

**Pemindaian.** Direktori dibaca dengan `getattrlistbulk(2)`, yang mengembalikan nama, ukuran, waktu, dan clone ID APFS untuk satu direktori penuh dalam sekali panggil, di beberapa thread. Symlink tidak pernah diikuti dan volume lain tidak dimasuki kecuali diminta.

**Folder duplikat.** Identitas sebuah folder adalah SHA-256 atas isinya yang terurut: nama, jenis, dan identitas tiap anak (untuk file, SHA-256 isinya; untuk symlink, targetnya). Identitas sama berarti pohon sama. Hanya folder identik terluar yang dilaporkan. `.DS_Store` diabaikan; file tersembunyi lainnya dihitung, jadi folder yang hanya berbeda di `.env` bukan duplikat. Resource fork sebuah file termasuk isinya; extended attribute lain (tag Finder, tanda karantina), izin, dan tanggal tidak dibandingkan.

**Membaca sesedikit mungkin.** Sebuah file hanya dibaca bila masih mungkin ada yang sama dengannya:

1. Folder dibandingkan dulu dari bentuknya (nama isi dan ukuran file, tanpa membaca). Folder dengan bentuk unik tidak mungkin punya kembaran.
2. File dikelompokkan menurut ukuran; ukuran unik berarti file unik.
3. File dengan clone ID APFS yang sama pasti identik dan tidak dibaca sama sekali.
4. Sisanya dibandingkan lewat hash 64 KB pertama dan terakhir, dan hanya yang lolos yang di-hash penuh.

**Angka yang jujur.** Untuk setiap grup, `sapu` menghitung byte mana yang benar-benar akan dilepas: salinan yang merupakan clone atau hard link dari salinan yang dipertahankan tidak membebaskan apa pun, dan dilaporkan demikian.

## Tanya jawab

**Katanya ada folder yang tidak bisa dibaca.** macOS melindungi sebagian folder home Anda. Agar hasilnya lengkap, tambahkan terminal Anda di System Settings › Privacy & Security › Full Disk Access.

**Saya menghapus 20 GB tapi ruang kosong hampir tidak berubah.** Tiga penyebab umum: filenya masih di Trash (kosongkan); snapshot lokal Time Machine masih merujuknya (kedaluwarsa dalam sehari, dan `sapu` memberi tahu bila ada snapshot); atau filenya adalah clone dari sesuatu yang masih ada.

**Bisa untuk drive eksternal?** Bisa: `sapu dupes /Volumes/Backup`. Deteksi clone dan `--clone` butuh APFS; sisanya jalan di file system apa pun.

**Bisa membandingkan dua drive atau folder?** `sapu dupes /Volumes/A /Volumes/B` melaporkan apa yang sama di keduanya.

**Kenapa duplikat yang jelas tidak disarankan untuk dihapus?** Biasanya ada catatan dalam kurung yang menjelaskan kenapa keputusannya diserahkan kepada Anda. Pakai `-i` untuk mencentangnya sendiri.

## Pengembangan

```sh
make build      # release build di .build/release/sapu
make test       # unit test (membuat dan membandingkan file sungguhan di folder temp)
make dist       # binary universal + tarball di dist/
```

Kode dibagi menjadi `SapuCore` (scanner, pencari duplikat, aturan junk, aksi; tanpa kode terminal) dan `sapu` (antarmuka command line). Aturan junk ada di [`Sources/SapuCore/Junk/JunkRules.swift`](Sources/SapuCore/Junk/JunkRules.swift): menambah folder build atau lokasi cache cukup beberapa baris, dan pull request untuk tool yang belum tercakup sangat diterima.

## Lisensi

[MIT](LICENSE)
