# Login nama pengguna DPARAGON DCIP

Form login menerima username dan kata sandi. Supabase Auth memakai alias
internal `username@accounts.dparagon.invalid`; alias tidak digunakan untuk
mengirim email dan tidak ditampilkan kepada petugas.

## Bootstrap Admin pertama

1. Di Supabase Dashboard, buka **Authentication → Settings** dan matikan
   pendaftaran publik (**Allow new users to sign up**).
2. Buka **Authentication → Users → Add user**.
3. Buat user dengan email `dparagonadmin@accounts.dparagon.invalid` dan
   kata sandi Admin yang kuat. Tandai email sebagai terkonfirmasi jika tersedia.
4. Jalankan `supabase/bootstrap-admin.sql` di SQL Editor. Ini mempromosikan
   profil menjadi Admin dan memberinya akses ke properti yang sudah ada.
5. Masuk melalui form aplikasi menggunakan username `dparagonadmin`.

Jangan masukkan service-role key ke frontend. Edge Function `create-account`
memeriksa sesi dan role Admin, lalu membuat akun petugas di server.

## Membuat akun Petugas

Panggil `createPetugasAccount()` dari `web/supabase-auth.js` dengan nama,
username, kata sandi, dan ID properti. Username harus 3–32 karakter; kata sandi
minimal 10 karakter. Admin pertama perlu memakai kata sandi baru yang kuat;
jangan gunakan ulang kredensial awal yang sudah dibagikan di percakapan.
