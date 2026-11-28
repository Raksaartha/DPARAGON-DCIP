import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.95.0'

import { createPetugasAccount, managePetugasAccount } from './supabase-auth.js'

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

async function readPages(makeQuery, columns) {
  const size = 500;
  const rows = [];
  for (let start = 0; ; start += size) {
    let query = makeQuery();
    for (const column of columns) query = query.order(column);
    const page = checked(await query.range(start, start + size - 1));
    rows.push(...page);
    if (page.length < size) return rows;
  }
}

export async function createDcipApi() {
  let catalog = []
  let master = []

  return {
    async manageStaffAccount(input) {
      return managePetugasAccount(supabase, input)
    },
    async createStaffAccount(input) {
      return createPetugasAccount(supabase, input)
    },
    async signOut() {
      checked(await supabase.auth.signOut())
    },
    async signIn(username, password) {
      const id = String(username).trim().toLowerCase()
      if (!/^[a-z0-9][a-z0-9._-]{2,31}$/.test(id)) throw new Error('ID pengguna tidak valid.')
      const aliases = id === 'dparagonadmin'
        ? [id, id + '.teknis', id + '.inventory', id + '.rd']
        : [id]
      for (const alias of aliases) {
        const { error } = await supabase.auth.signInWithPassword({
          email: alias + '@accounts.dparagon.invalid', password
        })
        if (!error) return
        if (error.code !== 'invalid_credentials') throw error
      }
      throw new Error('ID atau kata sandi salah.')
    },
    async currentProfile() {
      const {data, error} = await supabase.auth.getUser()
      if (error) return null
      const user = data.user
      if (!user) return null
      return checked(await supabase.from('user_profiles')
        .select('id,username,display_name,role,division_id').eq('id', user.id).single())
    },
    async addChecklistComponent(divisionId, positionId, name) {
      return checked(await supabase.rpc('add_checklist_component', {
        p_division_id: divisionId, p_position_id: positionId, p_name: name
      }))
    },
    async retireChecklistComponent(scope) {
      return checked(await supabase.from('material_items').update({ retired: true })
        .match(scope).eq('retired', false).select('id').single())
    },
    async changeMaterialOption(scope, value, removeId) {
      const matches = catalog.filter(row => row.division_code === scope.division_id &&
        row.position_code_id === scope.position_id && row.item_id === scope.item_id)
      const retire = (id, retired) => supabase.from('material_options').update({ retired })
        .match(scope).eq('id', id).select('id').single()
      if (removeId) return checked(await retire(removeId, true))
      const match = matches.find(row => row.option_value.trim().toLocaleLowerCase('id-ID') === value.toLocaleLowerCase('id-ID'))
      if (match) {
        if (match.retired) return checked(await retire(match.option_id, false))
        throw new Error('Spesifikasi ini sudah tersedia.')
      }
      return checked(await supabase.from('material_options').insert({
        ...scope, id: crypto.randomUUID(), value, option_type: 'REGULER', source: 'ADMIN',
        display_order: Math.max(0, ...matches.map(row => row.option_order)) + 1,
      }).select('id').single())
    },
    async rmisMuat() {
      const tables = ['divisions', 'properties', 'areas', 'position_codes', 'division_position_codes', 'locations', 'material_items', 'material_options']
      const values = await Promise.all(tables.map(table => readPages(
        () => supabase.from(table).select('*'),
        table === 'division_position_codes' ? ['division_id', 'position_id'] :
          table === 'material_items' ? ['division_id', 'position_id', 'id'] : ['id']
      )))
      const data = Object.fromEntries(tables.map((table, index) => [table, values[index]]))
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
          retired: option.retired === true,
          item_retired: item?.retired === true,
          option_type: option.option_type,
          option_value: option.value,
          option_order: option.display_order
        }
      }).sort((a, b) => a.item_order - b.item_order || a.option_order - b.option_order)
      return {master, katalog: catalog, divisionPositions: data.division_position_codes}
    },
    async rmisBacaInspeksi(divisionId, locationId) {
      const inspections = await readPages(() => {
        const query = supabase.from('inspections').select('*').eq('division_id', divisionId);
        return locationId ? query.eq('location_id', locationId) : query;
      }, ['id']);
      const answers = [];
      for (let start = 0; start < inspections.length; start += 50) {
        const ids = inspections.slice(start, start + 50).map(row => row.id);
        answers.push(...await readPages(
          () => supabase.from('inspection_answers').select('*').in('inspection_id', ids),
          ['inspection_id', 'item_id']
        ));
      }
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
          position_name: inspection.position_name,
          updated_at: inspection.updated_at,
          item_id: answer.item_id,
          option_value: answer.option_value,
          custom_specification: answer.custom_specification
        }
      })
    },
    async addDivisionPosition(divisionId, name) {
      return checked(await supabase.rpc('add_division_position', {p_division_id: divisionId, p_name: name}))
    },
    async removeDivisionPosition(divisionId, positionId) {
      return checked(await supabase.rpc('remove_division_position', {p_division_id: divisionId, p_position_id: positionId}))
    },
    async rmisBacaStatusPosisi(locationId, divisionId) {
      if (!locationId || !divisionId) return []
      return checked(await supabase.from('division_position_status')
        .select('position_id,status').eq('location_id', locationId).eq('division_id', divisionId))
    },
    async rmisSimpanStatusPosisi(locationId, positionId, status, divisionId) {
      return checked(await supabase.rpc('set_division_position_status', {
        p_division_id: divisionId, p_location_id: locationId, p_position_id: positionId, p_status: status
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
    async rmisUbahMaster(type, action, value, city) {
      const table = {DIVISI:'divisions', PROPERTI:'properties', AREA:'areas', KODE_POSISI:'position_codes'}[type]
      if (!table) throw new Error('Jenis master data tidak dikenal.')
      if (action === 'hapus') {
        checked(await supabase.from(table).delete().eq('id', value))
        return {id: value}
      }
      const row = checked(await supabase.from(table).insert({
        id: type + '-' + crypto.randomUUID(), name: value,
        ...(type === 'PROPERTI' ? {city} : {})
      }).select('id,name').single())
      return row
    }
  }
}

