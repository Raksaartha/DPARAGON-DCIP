import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.95.0'
import { signInWithUsername } from './supabase-auth.js'

const url = 'https://bzbjnuqjfavccsdbnpdr.supabase.co'
const key = 'sb_publishable_lUFNmyhRFWj448iCtioUag_L7lDC3LI'
const supabase = createClient(url, key)
const byId = id => document.getElementById(id)
const status = message => { byId('status').textContent = message }
const login = byId('login-form')
const create = byId('create-form')

function showSignedOut() {
  byId('account').hidden = true
  byId('admin').hidden = true
  byId('login').hidden = false
  byId('property-list').replaceChildren()
  byId('property-picker').querySelectorAll('label').forEach(label => label.remove())
  create.reset()
}

async function showAccount(profile) {
  const { data, error } = await supabase.from('properties').select('id,name').order('name')
  if (error) throw new Error('Daftar properti gagal dimuat.')
  const list = byId('property-list')
  const picker = byId('property-picker')
  list.replaceChildren()
  picker.querySelectorAll('label').forEach(label => label.remove())
  for (const property of data) {
    const item = document.createElement('li')
    item.textContent = property.name
    list.append(item)
    if (profile.role !== 'admin') continue
    const label = document.createElement('label')
    const input = document.createElement('input')
    input.type = 'checkbox'
    input.name = 'property'
    input.value = property.id
    label.append(input, property.name)
    picker.append(label)
  }
  if (!data.length) list.textContent = 'Belum ada akses properti.'
  byId('display-name').textContent = profile.display_name
  byId('role').textContent = profile.role === 'admin' ? 'Admin' : 'Petugas'
  byId('login').hidden = true
  byId('account').hidden = false
  byId('admin').hidden = profile.role !== 'admin'
}

login.addEventListener('submit', async event => {
  event.preventDefault()
  const button = login.querySelector('button')
  button.disabled = true
  status('Sedang masuk…')
  const fields = new FormData(login)
  try {
    const { profile } = await signInWithUsername(supabase, fields.get('username'), fields.get('password'))
    await showAccount(profile)
    login.reset()
    status('')
  } catch (error) {
    login.elements.password.value = ''
    status(error.message)
  } finally {
    button.disabled = false
  }
})

create.addEventListener('submit', async event => {
  event.preventDefault()
  const fields = new FormData(create)
  const propertyIds = fields.getAll('property')
  if (!propertyIds.length) {
    status('Pilih minimal satu properti.')
    return
  }
  const button = create.querySelector('button')
  button.disabled = true
  status('Sedang membuat akun…')
  try {
    const { data, error } = await supabase.auth.getSession()
    if (error || !data.session) throw new Error('Sesi berakhir. Silakan masuk kembali.')
    const response = await fetch(url + '/functions/v1/create-account', {
      method: 'POST',
      headers: {
        apikey: key,
        Authorization: 'Bearer ' + data.session.access_token,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        username: fields.get('username'),
        display_name: fields.get('displayName'),
        password: fields.get('password'),
        property_ids: propertyIds,
      }),
    })
    const result = await response.json().catch(() => ({}))
    if (!response.ok) throw new Error(result.error || 'Gagal membuat akun Petugas.')
    create.reset()
    status('Akun Petugas ' + result.user.username + ' berhasil dibuat.')
  } catch (error) {
    status(error.message)
  } finally {
    button.disabled = false
  }
})

byId('logout').addEventListener('click', async () => {
  const { error } = await supabase.auth.signOut()
  if (error) {
    status('Gagal keluar. Silakan coba kembali.')
    return
  }
  showSignedOut()
  status('')
})
supabase.auth.onAuthStateChange(event => {
  if (event === 'SIGNED_OUT') showSignedOut()
})

async function restoreAccount() {
  status('Memuat akun…')
  try {
    const { data, error } = await supabase.auth.getSession()
    if (error) throw error
    if (!data.session) {
      showSignedOut()
      status('')
      return
    }
    const profile = await supabase.from('user_profiles')
      .select('display_name, role').eq('id', data.session.user.id).single()
    if (profile.error) throw profile.error
    await showAccount(profile.data)
    status('')
  } catch {
    showSignedOut()
    status('Akun gagal dimuat. Silakan masuk kembali.')
  }
}

restoreAccount()
