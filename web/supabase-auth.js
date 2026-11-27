// Username login helper for the static DPARAGON DCIP frontend.
export const USERNAME_EMAIL_DOMAIN = 'accounts.dparagon.invalid'

export function usernameToAuthEmail(value) {
  const username = String(value ?? '').trim().toLowerCase()
  if (!/^[a-z0-9][a-z0-9._-]{2,31}$/.test(username)) throw new Error('Nama pengguna tidak valid.')
  return `${username}@${USERNAME_EMAIL_DOMAIN}`
}

export async function signInWithUsername(supabase, username, password) {
  const { data, error } = await supabase.auth.signInWithPassword({
    email: usernameToAuthEmail(username), password,
  })
  if (error) throw new Error('Nama pengguna atau kata sandi salah.')
  const { data: profile, error: profileError } = await supabase
    .from('user_profiles')
    .select('id, username, display_name, role')
    .eq('id', data.user.id)
    .single()
  if (profileError || !profile) {
    await supabase.auth.signOut()
    throw new Error('Profil akun tidak tersedia. Hubungi Admin.')
  }
  return { user: data.user, profile }
}

export async function createPetugasAccount(supabase, { username, displayName, password, propertyIds }) {
  const { data, error } = await supabase.functions.invoke('create-account', {
    body: {
      username: String(username ?? '').trim().toLowerCase(),
      display_name: String(displayName ?? '').trim(),
      password: String(password ?? ''),
      property_ids: propertyIds,
    },
  })
  if (error) throw new Error(data?.error || error.message || 'Gagal membuat akun petugas.')
  return data.user
}
