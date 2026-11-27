# Sinkron Supabase ke Google Sheets

Folder ini menyiapkan sinkronisasi satu arah: **Supabase adalah sumber data**, Google Sheets hanya menampilkan salinannya.

## Yang dilakukan script

- Mengambil master data dan opsi material, serta jawaban inspeksi dari tiga divisi.
- Mengisi tab `STATUS POSISI` untuk status ADA/TIDAK TERDAPAT pada setiap lokasi.
- Menampilkan usulan baru dari aplikasi pada tab `USULAN`; kolom ID internal disembunyikan.
- Memperbarui baris yang sudah dikenal dan menambahkan baris baru berdasarkan ID.
- Mempertahankan baris contoh/manual yang tidak dikelola oleh sinkronisasi.
- Membuat tab tersembunyi `__SYNC_STATE` untuk mengenali baris yang pernah dibuat atau diperbarui oleh script; baris sinkron yang sudah dihapus di Supabase akan ikut dibersihkan saat sinkron berikutnya.
- Menolak sinkronisasi jika salah satu tab atau header tidak sama dengan struktur yang diharapkan.

Script tidak memerlukan deployment Web App. Sinkron otomatis memakai trigger Apps Script setiap 15 menit. Trigger edit untuk kolom KONFIRMASI juga dipasang oleh `setupDcipAutoSync`.

## Penyiapan

1. Buka [script.google.com](https://script.google.com) dan buat project Apps Script baru bernama `DPARAGON DCIP Sheet Sync`. Gunakan project terpisah agar tidak bentrok dengan Apps Script lama.
2. Salin isi `Code.gs` ke editor Apps Script lalu simpan.
3. Di Apps Script, buka **Project Settings → Script Properties → Add script property**, lalu isi:

   | Nama | Nilai |
   | --- | --- |
   | `SPREADSHEET_ID` | ID dari URL spreadsheet `DATABASE CDP` |
   | `SUPABASE_URL` | `https://bzbjnuqjfavccsdbnpdr.supabase.co` |
   | `SUPABASE_SECRET_KEY` | Secret API key Supabase (server-side), bukan Publishable key |

4. Simpan Script Properties. Jangan menaruh Secret API key di source code, GitHub, chat, atau spreadsheet.
5. Pada dropdown nama fungsi di toolbar Apps Script, pilih `syncDcipToSheets`, lalu klik **Jalankan**. Berikan izin Apps Script untuk mengakses spreadsheet dan menghubungi Supabase. Baris contoh/manual yang tidak dikelola sinkronisasi akan tetap dipertahankan.
6. Setelah sinkron manual berhasil, pilih `setupDcipAutoSync` pada dropdown fungsi, lalu klik **Jalankan**. Fungsi ini memasang sinkronisasi 15 menit dan trigger edit untuk `USULAN`.
7. Untuk memproses usulan dari spreadsheet, centang kolom `KONFIRMASI`. Script akan mengubah status usulan menjadi `DIPROSES` di Supabase, lalu menghapus baris dari daftar aktif `USULAN`. Riwayat usulan tetap tersimpan di database.
8. Untuk menghentikan sinkron otomatis, pilih `removeDcipAutoSync` pada dropdown fungsi dan klik **Jalankan**.


## Batas akses

Script memakai Secret API key yang dapat membaca semua data melalui Supabase. Batasi akses editor project Apps Script hanya untuk Admin tepercaya. Jangan berbagi project script kepada Petugas. Pengguna yang hanya viewer spreadsheet tidak dapat melihat Script Properties, tetapi editor script dapat mengubah kode dan membaca secret melalui kode.

Baris yang tidak dikenal oleh sinkronisasi tetap dipertahankan. Setelah sinkron pertama berhasil, hanya baris dengan key yang tercatat pada `__SYNC_STATE` yang dapat diperbarui atau dihapus oleh sinkron berikutnya.

