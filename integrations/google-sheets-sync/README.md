# Sinkron Supabase ke Google Sheets

Folder ini menyiapkan sinkronisasi satu arah: **Supabase adalah sumber data**, Google Sheets hanya menampilkan salinannya.

## Yang dilakukan script

- Mengambil `MASTER DATA`, `OPSI_MATERIAL`, serta jawaban inspeksi dari tiga divisi.
- Memperbarui baris yang sudah dikenal dan menambahkan baris baru berdasarkan ID.
- Mempertahankan baris contoh/manual yang tidak dikelola oleh sinkronisasi.
- Membuat tab tersembunyi `__SYNC_STATE` untuk mengenali baris yang pernah dibuat atau diperbarui oleh script; baris sinkron yang sudah dihapus di Supabase akan ikut dibersihkan saat sinkron berikutnya.
- Menolak sinkronisasi jika salah satu tab atau header tidak sama dengan struktur yang diharapkan.

Script tidak memerlukan deployment Web App. Sinkron otomatis memakai trigger Apps Script setiap 15 menit; menu `DCIP Sync` juga menyediakan sinkronisasi manual.

## Penyiapan

1. Buka spreadsheet `DATABASE CDP`, lalu pilih **Ekstensi → Apps Script**. Buat project Apps Script yang terikat ke spreadsheet tersebut, atau gunakan project sinkronisasi khusus yang tidak dibagikan kepada Petugas.
2. Salin isi `Code.gs` ke editor Apps Script lalu simpan.
3. Di Apps Script, buka **Project Settings → Script Properties → Add script property**, lalu isi:

   | Nama | Nilai |
   | --- | --- |
   | `SPREADSHEET_ID` | ID dari URL spreadsheet `DATABASE CDP` |
   | `SUPABASE_URL` | `https://bzbjnuqjfavccsdbnpdr.supabase.co` |
   | `SUPABASE_SECRET_KEY` | Secret API key Supabase (server-side), bukan Publishable key |

4. Simpan Script Properties. Jangan menaruh Secret API key di source code, GitHub, chat, atau spreadsheet.
5. Kembali ke spreadsheet dan muat ulang halaman. Pilih **DCIP Sync → Sinkronkan sekarang** dan berikan izin Apps Script yang diminta untuk mengakses spreadsheet dan menghubungi Supabase.
6. Setelah sinkron manual berhasil, pilih **DCIP Sync → Aktifkan sinkron otomatis (15 menit)**. Jalankan sekali dan setujui izin pembuatan trigger.

## Batas akses

Script memakai Secret API key yang dapat membaca semua data melalui Supabase. Batasi akses editor project Apps Script hanya untuk Admin tepercaya. Jangan berbagi project script kepada Petugas. Pengguna yang hanya viewer spreadsheet tidak dapat melihat Script Properties, tetapi editor script dapat mengubah kode dan membaca secret melalui kode.

Baris yang tidak dikenal oleh sinkronisasi tetap dipertahankan. Setelah sinkron pertama berhasil, hanya baris dengan key yang tercatat pada `__SYNC_STATE` yang dapat diperbarui atau dihapus oleh sinkron berikutnya.

