import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.95.0'

const supabase = createClient(
  'https://bzbjnuqjfavccsdbnpdr.supabase.co',
  'sb_publishable_lUFNmyhRFWj448iCtioUag_L7lDC3LI'
)

function checked(result) {
  if (result.error) {
    if (result.error.code === '23505') throw new Error('Data dengan nama yang sama sudah tersedia atau sedang diproses.')
    throw new Error(result.error.message)
  }
  return result.data
}

export async function createDcipApi() {
  let catalog = []
  let master = []

  return {
    async signOut() {
      checked(await supabase.auth.signOut())
    },
    async signIn(username, password) {
      const id = String(username).trim().toLowerCase()
      if (!/^[a-z0-9][a-z0-9._-]{2,31}$/.test(id)) throw new Error('ID pengguna tidak valid.')
      checked(await supabase.auth.signInWithPassword({
        email: id + '@accounts.dparagon.invalid', password
      }))
    },
    async currentProfile() {
      const {data, error} = await supabase.auth.getUser()
      if (error) return null
      const user = data.user
      if (!user) return null
      return checked(await supabase.from('user_profiles')
        .select('id,username,display_name,role').eq('id', user.id).single())
    },
    async rmisMuat() {
      const tables = ['divisions', 'properties', 'areas', 'position_codes', 'locations', 'material_items', 'material_options']
      const values = await Promise.all(tables.map(table => supabase.from(table).select('*')))
      const data = Object.fromEntries(tables.map((table, index) => [table, checked(values[index])]))
      const rows = (type, source) => source.map(row => ({
        master_type: type, master_id: row.id, name: row.name, city: row.city || null
      }))
      master = [
        ...rows('DIVISI', data.divisions),
        ...rows('PROPERTI', data.properties),
        ...rows('AREA', data.areas),
        ...rows('KODE_POSISI', data.position_codes),
        ...data.locations.map(row => ({
          master_type: 'LOKASI', master_id: row.id, name: row.name,
          parent_property_id: row.property_id, parent_area_id: row.area_id
        }))
      ]
      const itemByKey = new Map(data.material_items.map(item => [
        [item.division_id, item.position_id, item.id].join('|'), item
      ]))
      catalog = data.material_options.map(option => {
        const item = itemByKey.get([option.division_id, option.position_id, option.item_id].join('|'))
        return {
          division_code: option.division_id,
          position_code_id: option.position_id,
          item_id: option.item_id,
          item_name: item?.name || option.item_id,
          item_order: item?.display_order || 1,
          option_id: option.id,
          option_value: option.value,
          option_order: option.display_order
        }
      }).sort((a, b) => a.item_order - b.item_order || a.option_order - b.option_order)
      return {master, katalog: catalog}
    },
    async rmisBacaInspeksi(divisionId, locationId) {
      let query = supabase.from('inspections').select('*').eq('division_id', divisionId)
      if (locationId) query = query.eq('location_id', locationId)
      const inspections = checked(await query)
      if (!inspections.length) return []
      const answers = checked(await supabase.from('inspection_answers').select('*')
        .in('inspection_id', inspections.map(row => row.id)))
      const locationById = new Map(master.filter(row => row.master_type === 'LOKASI')
        .map(row => [row.master_id, row]))
      const inspectionById = new Map(inspections.map(row => [row.id, row]))
      return answers.map(answer => {
        const inspection = inspectionById.get(answer.inspection_id)
        return {
          inspection_id: inspection.id,
          division_code: inspection.division_id,
          property_id: inspection.property_id,
          area_id: locationById.get(inspection.location_id)?.parent_area_id || '',
          location_name: inspection.location_name,
          position_code_id: inspection.position_id,
          updated_at: inspection.updated_at,
          item_id: answer.item_id,
          option_value: answer.option_value,
          custom_specification: answer.custom_specification
        }
      })
    },
    async rmisBacaStatusPosisi(locationId) {
      if (!locationId) return []
      return checked(await supabase.from('location_position_status')
        .select('location_id,property_id,position_id,status,created_by,updated_by,created_at,updated_at')
        .eq('location_id', locationId))
    },
    async rmisSimpanStatusPosisi(locationId, positionId, status) {
      return checked(await supabase.rpc('set_location_position_status', {
        p_location_id: locationId,
        p_position_id: positionId,
        p_status: status
      }))
    },
    async rmisAjukanUsulan(input) {
      const row = checked(await supabase.from('catalog_requests').insert({
        division_id: input.division_id,
        request_type: input.request_type,
        value: String(input.value || '').trim(),
        property_id: input.property_id || null,
        location_id: input.location_id || null,
        position_id: input.position_id || null,
        item_id: input.item_id || null
      }).select('id,division_id,request_type,value,property_id,location_id,position_id,item_id,status,created_at').single())
      return row
    },
    async rmisBacaUsulan() {
      return checked(await supabase.from('catalog_requests')
        .select('id,division_id,request_type,value,property_id,location_id,position_id,item_id,status,requested_by,created_at')
        .in('status', ['DIAJUKAN','DIPROSES'])
        .order('created_at', {ascending:false}))
    },
    async rmisTinjauUsulan(requestId, action) {
      return checked(await supabase.rpc('review_catalog_request', {
        p_request_id: requestId,
        p_action: action
      }))
    },
    async rmisSimpanInspeksi(input) {
      const answers = input.answers.map(answer => {
        const option = catalog.find(row => row.option_id === answer.option_id)
        if (!option) throw new Error('Pilihan material tidak tersedia.')
        return {
          item_id: option.item_id,
          option_id: answer.option_id,
          custom_specification: answer.custom_specification || null
        }
      })
      const id = checked(await supabase.rpc('save_inspection', {
        p_division_id: input.division_code,
        p_location_id: input.location_id,
        p_position_id: input.position_code_id,
        p_answers: answers,
        p_inspection_id: input.inspection_id || null
      }))
      return {inspection_id: id}
    },
    async rmisHapusInspeksi(_divisionId, inspectionId) {
      checked(await supabase.rpc('delete_inspection', {p_inspection_id: inspectionId}))
    },
    async rmisTambahLokasi(propertyId, areaId, name) {
      const row = checked(await supabase.from('locations').insert({
        property_id: propertyId, area_id: areaId, name
      }).select('id,name,property_id,area_id').single())
      return {id: row.id, name: row.name, propertyId: row.property_id, areaPosition: areaId}
    },
    async rmisHapusLokasi(locationId) {
      checked(await supabase.rpc('delete_location', {p_location_id: locationId}))
    },
    async setPropertyCity(propertyId, city) {
      return checked(await supabase.from('properties').update({city})
        .eq('id', propertyId).select('id,city').single())
    },
    async rmisUbahMaster(type, action, value) {
      const table = {DIVISI:'divisions', PROPERTI:'properties', AREA:'areas', KODE_POSISI:'position_codes'}[type]
      if (!table) throw new Error('Jenis master data tidak dikenal.')
      if (action === 'hapus') {
        checked(await supabase.from(table).delete().eq('id', value))
        return {id: value}
      }
      const row = checked(await supabase.from(table).insert({
        id: type + '-' + crypto.randomUUID(), name: value
      }).select('id,name').single())
      return row
    }
  }
}

