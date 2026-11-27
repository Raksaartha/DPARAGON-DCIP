import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function respond(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json; charset=utf-8' },
  })
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return respond(405, { error: 'Metode tidak didukung.' })

  const authorization = req.headers.get('Authorization')
  if (!authorization?.startsWith('Bearer ')) return respond(401, { error: 'Silakan masuk sebagai Admin.' })

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    console.error('Supabase Edge Function environment is incomplete.')
    return respond(500, { error: 'Konfigurasi server belum lengkap.' })
  }

  const token = authorization.slice('Bearer '.length)
  const authClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const { data: authData, error: authError } = await authClient.auth.getUser(token)
  if (authError || !authData.user) return respond(401, { error: 'Sesi tidak valid. Silakan masuk kembali.' })

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const { data: caller, error: callerError } = await admin
    .from('user_profiles')
    .select('role')
    .eq('id', authData.user.id)
    .maybeSingle()
  if (callerError || caller?.role !== 'admin') return respond(403, { error: 'Hanya Admin yang dapat membuat akun.' })

  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return respond(400, { error: 'Data permintaan tidak valid.' })
  }

  const username = String(body.username ?? '').trim().toLowerCase()
  const displayName = String(body.display_name ?? '').trim()
  const password = String(body.password ?? '')
  const divisionId = String(body.division_id ?? '').trim()
  const city = String(body.city ?? '').trim()
  if (divisionId || city) {
    const { data: division } = await admin.from('divisions').select('id').eq('id', divisionId).maybeSingle()
    if (!division || !city) return respond(400, { error: 'Pilih divisi dan kota yang valid.' })
  }
  const propertyIds = Array.isArray(body.property_ids)
    ? [...new Set(body.property_ids.map(value => String(value).trim()).filter(Boolean))]
    : []

  if (!/^[a-z0-9][a-z0-9._-]{2,31}$/.test(username)) {
    return respond(400, { error: 'Nama pengguna harus 3–32 karakter: huruf, angka, titik, garis bawah, atau tanda hubung.' })
  }
  if (displayName.length < 2 || displayName.length > 80) {
    return respond(400, { error: 'Nama petugas harus 2–80 karakter.' })
  }
  if (password.length < 8 || password.length > 72) {
    return respond(400, { error: 'Kata sandi harus 8–72 karakter.' })
  }
  if (propertyIds.length === 0) return respond(400, { error: 'Pilih setidaknya satu properti untuk akun petugas.' })

  const { data: properties, error: propertiesError } = await admin
    .from('properties')
    .select('id,city')
    .in('id', propertyIds)
  if (propertiesError) return respond(500, { error: 'Gagal memeriksa properti.' })
  if ((properties?.length ?? 0) !== propertyIds.length) {
    return respond(400, { error: 'Salah satu properti yang dipilih tidak ditemukan.' })
  }

  if (city && properties?.some(property => (property.city ?? '__unassigned__') !== city)) {
    return respond(400, { error: 'Properti harus berada di kota yang dipilih.' })
  }

  // Supabase Auth is the credential store; the UI and staff use a username.
  const emailAlias = `${username}@accounts.dparagon.invalid`
  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email: emailAlias,
    password,
    email_confirm: true,
    user_metadata: { username, display_name: displayName },
  })
  if (createError || !created.user) {
    console.error('Admin createUser failed:', createError?.message)
    return respond(400, { error: 'Akun gagal dibuat. Pastikan nama pengguna belum digunakan dan kata sandi memenuhi syarat.' })
  }

  const userId = created.user.id
  const { error: profileError } = await admin.from('user_profiles').upsert({
    id: userId,
    username,
    display_name: displayName,
    role: 'petugas',
    division_id: divisionId || null,
  })
  if (profileError) {
    await admin.auth.admin.deleteUser(userId)
    console.error('Profile creation failed:', profileError.message)
    return respond(500, { error: 'Profil akun gagal disimpan.' })
  }

  const memberships = propertyIds.map(property_id => ({ user_id: userId, property_id, role: 'petugas' }))
  const { error: membershipError } = await admin.from('property_memberships').insert(memberships)
  if (membershipError) {
    await admin.auth.admin.deleteUser(userId)
    console.error('Property assignment failed:', membershipError.message)
    return respond(500, { error: 'Akun gagal diberi akses properti.' })
  }

  return respond(201, {
    user: { id: userId, username, display_name: displayName, role: 'petugas', property_ids: propertyIds },
  })
})
