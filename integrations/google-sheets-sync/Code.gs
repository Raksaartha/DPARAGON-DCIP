const DCIP_SYNC = {
  PAGE_SIZE: 1000,
  STATE_SHEET: '__SYNC_STATE',
  SHEETS: {
    master: 'MASTER DATA',
    options: 'OPSI_MATERIAL',
    inspection: {TEKNIS: 'DATA_TEKNIS', INVENTORY: 'DATA_INVENTORY', RD: 'DATA_RD'},
    proposals: 'USULAN',
    positionStatus: 'STATUS POSISI'
  },
  HEADERS: {
    master: ['master_type','master_id','name','parent_property_id','parent_area_id','target_sheet','display_order','city'],
    options: ['option_id','division_code','position_code_id','item_order','item_id','item_name','option_order','option_value','option_type','source'],
    details: ['inspection_detail_id','inspection_id','location_id','property_id','area_id','location_name','position_code_id','item_id','item_name','option_id','option_value','custom_specification','created_at','updated_at','created_by','updated_by'],
    proposals: ['NO','DIVISI','USULAN','KETERANGAN','KONFIRMASI','request_id'],
    positionStatus: ['NO','KOTA','PROPERTI','AREA','NAMA/NOMOR LOKASI','KODE POSISI','STATUS','PETUGAS UPDATE','TANGGAL UPDATE','status_key']
  }
};

function syncDcipToSheets() {
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    const config = getConfig_();
    const spreadsheet = SpreadsheetApp.openById(config.spreadsheetId);
    ensureSupportSheets_(spreadsheet);
    validateAllSheets_(spreadsheet);
    const stateSheet = getStateSheet_(spreadsheet);
    const previous = readSyncState_(stateSheet);
    const db = loadDatabase_(config);
    const next = {};

    next['MASTER DATA'] = syncSheet_(
      spreadsheet, DCIP_SYNC.SHEETS.master, DCIP_SYNC.HEADERS.master,
      buildMasterRows_(db), row => row[0] + '|' + row[1], previous['MASTER DATA'] || []
    );
    next['OPSI_MATERIAL'] = syncSheet_(
      spreadsheet, DCIP_SYNC.SHEETS.options, DCIP_SYNC.HEADERS.options,
      buildOptionRows_(db), row => row[0], previous['OPSI_MATERIAL'] || []
    );

    next[DCIP_SYNC.SHEETS.proposals] = syncSheet_(
      spreadsheet, DCIP_SYNC.SHEETS.proposals, DCIP_SYNC.HEADERS.proposals,
      buildProposalRows_(db), row => row[5], previous[DCIP_SYNC.SHEETS.proposals] || []
    );
    next[DCIP_SYNC.SHEETS.positionStatus] = syncSheet_(
      spreadsheet, DCIP_SYNC.SHEETS.positionStatus, DCIP_SYNC.HEADERS.positionStatus,
      buildPositionStatusRows_(db), row => row[9], previous[DCIP_SYNC.SHEETS.positionStatus] || []
    );

    Object.entries(DCIP_SYNC.SHEETS.inspection).forEach(([division, sheetName]) => {
      next[sheetName] = syncSheet_(
        spreadsheet, sheetName, DCIP_SYNC.HEADERS.details,
        buildInspectionRows_(db, division), row => row[0], previous[sheetName] || []
      );
    });

    writeSyncState_(stateSheet, next);
    console.log('Sinkronisasi Supabase selesai.');
  } finally {
    lock.releaseLock();
  }
}

function setupDcipAutoSync() {
  const config = getConfig_();
  const spreadsheet = SpreadsheetApp.openById(config.spreadsheetId);
  ensureSupportSheets_(spreadsheet);
  validateAllSheets_(spreadsheet);
  removeDcipAutoSync();
  ScriptApp.newTrigger('syncDcipToSheets').timeBased().everyMinutes(15).create();
  setupUsulanConfirmTrigger();
  console.log('Sinkron otomatis aktif setiap 15 menit; konfirmasi usulan aktif.');
}

function removeDcipAutoSync() {
  ScriptApp.getProjectTriggers().forEach(trigger => {
    if (['syncDcipToSheets','handleUsulanConfirmation'].includes(trigger.getHandlerFunction())) ScriptApp.deleteTrigger(trigger);
  });
}

function setupUsulanConfirmTrigger() {
  const config = getConfig_();
  const spreadsheet = SpreadsheetApp.openById(config.spreadsheetId);
  ScriptApp.getProjectTriggers().forEach(trigger => {
    if (trigger.getHandlerFunction() === 'handleUsulanConfirmation') ScriptApp.deleteTrigger(trigger);
  });
  ScriptApp.newTrigger('handleUsulanConfirmation').forSpreadsheet(spreadsheet).onEdit().create();
  console.log('Konfirmasi USULAN aktif.');
}

function getConfig_() {
  const p = PropertiesService.getScriptProperties();
  const config = {
    spreadsheetId: p.getProperty('SPREADSHEET_ID'),
    supabaseUrl: String(p.getProperty('SUPABASE_URL') || '').replace(/\/$/, ''),
    secretKey: p.getProperty('SUPABASE_SECRET_KEY')
  };
  if (!config.spreadsheetId || !config.supabaseUrl || !config.secretKey) {
    throw new Error('Isi SPREADSHEET_ID, SUPABASE_URL, dan SUPABASE_SECRET_KEY pada Script Properties.');
  }
  if (config.secretKey.startsWith('sb_publishable_')) {
    throw new Error('Gunakan Supabase Secret API key server-side, bukan Publishable key.');
  }
  return config;
}

function loadDatabase_(config) {
  const names = ['divisions','properties','areas','position_codes','locations','material_items','material_options','inspections','inspection_answers','user_profiles','location_position_status','catalog_requests'];
  const result = {};
  names.forEach(name => result[name] = fetchTable_(config, name));
  return result;
}

function fetchTable_(config, table) {
  const rows = [];
  for (let offset = 0; ; offset += DCIP_SYNC.PAGE_SIZE) {
    const headers = {
      apikey: config.secretKey,
      Accept: 'application/json',
      'Range-Unit': 'items',
      Range: offset + '-' + (offset + DCIP_SYNC.PAGE_SIZE - 1)
    };
    // Opaque sb_secret keys are API gateway keys, not JWTs. Legacy service_role
    // keys are JWTs and also belong in Authorization.
    if (!config.secretKey.startsWith('sb_secret_')) headers.Authorization = 'Bearer ' + config.secretKey;
    const response = UrlFetchApp.fetch(config.supabaseUrl + '/rest/v1/' + encodeURIComponent(table) + '?select=*', {
      method: 'get', headers, muteHttpExceptions: true
    });
    const code = response.getResponseCode();
    if (code < 200 || code >= 300) {
      throw new Error('Gagal membaca tabel ' + table + ' dari Supabase (' + code + '): ' + response.getContentText().slice(0, 400));
    }
    const page = JSON.parse(response.getContentText() || '[]');
    if (!Array.isArray(page)) throw new Error('Respons tabel ' + table + ' bukan array.');
    rows.push.apply(rows, page);
    if (page.length < DCIP_SYNC.PAGE_SIZE) break;
  }
  return rows;
}

function buildMasterRows_(db) {
  const rows = [];
  const pushGroup = (type, records, getName, getFields, preferredOrder) => {
    const rank = new Map((preferredOrder || []).map((value, index) => [value, index]));
    const sorted = records.slice().sort((a, b) => {
      const an = getName(a), bn = getName(b);
      const ar = rank.has(an) ? rank.get(an) : 100000;
      const br = rank.has(bn) ? rank.get(bn) : 100000;
      return ar - br || an.localeCompare(bn, 'id');
    });
    sorted.forEach((record, index) => {
      const extra = getFields(record);
      rows.push([type, record.id, getName(record), extra[0] || '', extra[1] || '', extra[2] || '', index + 1, type === 'PROPERTI' ? record.city || '' : '']);
    });
  };

  pushGroup('DIVISI', db.divisions, row => row.name, row => ['', '', row.name], ['TEKNIS','INVENTORY','RD']);
  pushGroup('PROPERTI', db.properties, row => row.name, () => ['', '', '']);
  pushGroup('AREA', db.areas, row => row.name, () => ['', '', ''], ['Didalam Kamar','Diluar Kamar']);
  pushGroup('KODE_POSISI', db.position_codes, row => row.name, () => ['', '', ''], ['KAMAR','KAMAR MANDI','BALKON','FASUM']);

  const locations = db.locations.slice().sort((a, b) =>
    String(a.property_id).localeCompare(String(b.property_id)) ||
    String(a.area_id).localeCompare(String(b.area_id)) ||
    Number(a.display_order || 0) - Number(b.display_order || 0) ||
    String(a.name).localeCompare(String(b.name), 'id')
  );
  const locationOrder = new Map();
  locations.forEach(row => {
    const group = row.property_id + '|' + row.area_id;
    locationOrder.set(group, (locationOrder.get(group) || 0) + 1);
    rows.push(['LOKASI', row.id, row.name, row.property_id, row.area_id, '', locationOrder.get(group), '']);
  });
  return rows;
}

function buildProposalRows_(db) {
  const divisionById = new Map(db.divisions.map(row => [row.id, row]));
  return db.catalog_requests.filter(row => row.status === 'DIAJUKAN')
    .sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)))
    .map((row, index) => [index + 1, divisionById.get(row.division_id)?.name || row.division_id,
      row.request_type, row.value, false, row.id]);
}

function buildPositionStatusRows_(db) {
  const propertyById = new Map(db.properties.map(row => [row.id, row]));
  const areaById = new Map(db.areas.map(row => [row.id, row]));
  const positionById = new Map(db.position_codes.map(row => [row.id, row]));
  const locationById = new Map(db.locations.map(row => [row.id, row]));
  const profileById = new Map(db.user_profiles.map(row => [row.id, row]));
  return db.location_position_status.slice()
    .sort((a, b) => String(b.updated_at).localeCompare(String(a.updated_at)))
    .map((row, index) => {
      const location = locationById.get(row.location_id) || {};
      const updater = profileById.get(row.updated_by) || {};
      const key = row.location_id + '|' + row.position_id;
      return [index + 1, propertyById.get(row.property_id)?.city || '', propertyById.get(row.property_id)?.name || row.property_id,
        areaById.get(location.area_id)?.name || location.area_id || '', location.name || '',
        positionById.get(row.position_id)?.name || row.position_id, row.status,
        updater.display_name || updater.username || row.updated_by || '', row.updated_at ? new Date(row.updated_at) : '', key];
    });
}

function buildOptionRows_(db) {
  const divisionById = new Map(db.divisions.map(row => [row.id, row]));
  const itemById = new Map(db.material_items.map(row => [[row.division_id,row.position_id,row.id].join('|'), row]));
  const positionById = new Map(db.position_codes.map(row => [row.id, row]));
  return db.material_options.map(option => {
    const item = itemById.get([option.division_id,option.position_id,option.item_id].join('|')) || {};
    return [option.id, divisionById.get(option.division_id)?.name || option.division_id,
      option.position_id, item.display_order || 1, option.item_id, item.name || option.item_id,
      option.display_order || 1, option.value, option.option_type || '', option.source || ''];
  }).sort((a, b) => String(a[1]).localeCompare(String(b[1]), 'id') ||
    String(positionById.get(a[2])?.name || a[2]).localeCompare(String(positionById.get(b[2])?.name || b[2]), 'id') ||
    Number(a[3]) - Number(b[3]) || Number(a[6]) - Number(b[6]));
}

function buildInspectionRows_(db, divisionName) {
  const divisionById = new Map(db.divisions.map(row => [row.id, row]));
  const locationById = new Map(db.locations.map(row => [row.id, row]));
  const profilesById = new Map(db.user_profiles.map(row => [row.id, row]));
  const inspectionsById = new Map(db.inspections
    .filter(row => (divisionById.get(row.division_id)?.name || row.division_id) === divisionName)
    .map(row => [row.id, row]));
  return db.inspection_answers.filter(answer => inspectionsById.has(answer.inspection_id))
    .map(answer => {
      const inspection = inspectionsById.get(answer.inspection_id);
      const creator = profilesById.get(inspection.created_by);
      const editor = profilesById.get(inspection.updated_by);
      return ['SUPABASE-' + inspection.id + '-' + answer.item_id, inspection.id,
        inspection.location_id, inspection.property_id, locationById.get(inspection.location_id)?.area_id || '',
        inspection.location_name, inspection.position_id, answer.item_id, answer.item_name,
        answer.option_id, answer.option_value, answer.custom_specification || '',
        inspection.created_at, inspection.updated_at,
        creator?.display_name || creator?.username || inspection.created_by,
        editor?.display_name || editor?.username || inspection.updated_by];
    }).sort((a, b) => String(a[13]).localeCompare(String(b[13])) ||
      String(a[1]).localeCompare(String(b[1])) || String(a[7]).localeCompare(String(b[7])));
}

function syncSheet_(spreadsheet, sheetName, expectedHeaders, rows, keyFn, previousKeys) {
  const sheet = spreadsheet.getSheetByName(sheetName);
  if (!sheet) throw new Error('Tab ' + sheetName + ' tidak ditemukan.');
  validateSheetHeaders_(sheet, expectedHeaders);

  const lastRow = sheetName === DCIP_SYNC.SHEETS.proposals ? getUsulanContentLastRow_(sheet) : sheet.getLastRow();
  const existing = lastRow > 1 ? sheet.getRange(2, 1, lastRow - 1, expectedHeaders.length).getValues() : [];
  const current = new Map(rows.map(row => [keyFn(row), row]));
  const rowIndexes = new Map();
  existing.forEach((row, index) => {
    const key = keyFn(row);
    if (key && !rowIndexes.has(key)) rowIndexes.set(key, index + 2);
  });

  current.forEach((row, key) => {
    const rowNumber = rowIndexes.get(key);
    if (rowNumber) {
      sheet.getRange(rowNumber, 1, 1, expectedHeaders.length).setValues([row]);
      if (sheetName === DCIP_SYNC.SHEETS.proposals) ensureUsulanCheckbox_(sheet, rowNumber);
    } else {
      const appendAt = (sheetName === DCIP_SYNC.SHEETS.proposals ? getUsulanContentLastRow_(sheet) : sheet.getLastRow()) + 1;
      ensureRowCapacity_(sheet, appendAt);
      sheet.getRange(appendAt, 1, 1, expectedHeaders.length).setValues([row]);
      if (sheetName === DCIP_SYNC.SHEETS.proposals) ensureUsulanCheckbox_(sheet, appendAt);
    }
  });

  const currentKeys = new Set(current.keys());
  const stale = new Set((previousKeys || []).filter(key => !currentKeys.has(key)));
  const rowsToDelete = [];
  existing.forEach((row, index) => {
    const key = keyFn(row);
    if (stale.has(key)) rowsToDelete.push(index + 2);
  });
  rowsToDelete.sort((a, b) => b - a).forEach(rowNumber => sheet.deleteRow(rowNumber));
  return [...currentKeys];
}

function validateAllSheets_(spreadsheet) {
  validateSheetHeaders_(spreadsheet.getSheetByName(DCIP_SYNC.SHEETS.proposals), DCIP_SYNC.HEADERS.proposals, DCIP_SYNC.SHEETS.proposals);
  validateSheetHeaders_(spreadsheet.getSheetByName(DCIP_SYNC.SHEETS.positionStatus), DCIP_SYNC.HEADERS.positionStatus, DCIP_SYNC.SHEETS.positionStatus);
  validateSheetHeaders_(spreadsheet.getSheetByName(DCIP_SYNC.SHEETS.master), DCIP_SYNC.HEADERS.master, DCIP_SYNC.SHEETS.master);
  validateSheetHeaders_(spreadsheet.getSheetByName(DCIP_SYNC.SHEETS.options), DCIP_SYNC.HEADERS.options, DCIP_SYNC.SHEETS.options);
  Object.values(DCIP_SYNC.SHEETS.inspection).forEach(name =>
    validateSheetHeaders_(spreadsheet.getSheetByName(name), DCIP_SYNC.HEADERS.details, name));
}

function validateSheetHeaders_(sheet, expectedHeaders, expectedName) {
  const name = expectedName || sheet?.getName() || 'tab';
  if (!sheet) throw new Error('Tab ' + name + ' tidak ditemukan.');
  const currentHeaders = sheet.getRange(1, 1, 1, expectedHeaders.length).getDisplayValues()[0];
  if (expectedHeaders.some((header, index) => currentHeaders[index] !== header)) {
    throw new Error('Header tab ' + name + ' tidak sesuai. Sinkronisasi dibatalkan sebelum data diubah.');
  }
}


function ensureSupportSheets_(spreadsheet) {
  const master = spreadsheet.getSheetByName(DCIP_SYNC.SHEETS.master);
  if (master && master.getMaxColumns() >= 8 && !master.getRange('H1').getValue()) master.getRange('H1').setValue('city');
  if (master && master.getMaxColumns() === 7) {
    master.insertColumnsAfter(7, 1);
    master.getRange('H1').setValue('city');
  }
  let proposals = spreadsheet.getSheetByName(DCIP_SYNC.SHEETS.proposals);
  if (!proposals) proposals = spreadsheet.insertSheet(DCIP_SYNC.SHEETS.proposals);
  if (proposals.getMaxColumns() < 6) proposals.insertColumnsAfter(proposals.getMaxColumns(), 6 - proposals.getMaxColumns());
  const visibleHeaders = ['NO','DIVISI','USULAN','KETERANGAN','KONFIRMASI'];
  const current = proposals.getRange(1, 1, 1, 5).getDisplayValues()[0];
  if (current.every(value => !value)) proposals.getRange(1, 1, 1, 5).setValues([visibleHeaders]);
  else if (visibleHeaders.some((value, index) => current[index] !== value)) {
    throw new Error('Header tab USULAN tidak sesuai. Pastikan kolom NO, DIVISI, USULAN, KETERANGAN, KONFIRMASI.');
  }
  const requestIdHeader = proposals.getRange(1, 6).getDisplayValue();
  if (!requestIdHeader) proposals.getRange(1, 6).setValue('request_id');
  else if (requestIdHeader !== 'request_id') throw new Error('Kolom tersembunyi F pada USULAN harus bernama request_id.');
  proposals.hideColumns(6);
  const contentLastRow = getUsulanContentLastRow_(proposals);
  const checkbox = SpreadsheetApp.newDataValidation().requireCheckbox().setAllowInvalid(false)
    .setHelpText('Centang setelah usulan mulai ditindaklanjuti.').build();
  proposals.getRange(2, 5, Math.max(1, contentLastRow - 1), 1).setDataValidation(checkbox);
  const unusedStartRow = contentLastRow + 1;
  if (unusedStartRow <= proposals.getMaxRows()) {
    const unusedCheckboxes = proposals.getRange(unusedStartRow, 5, proposals.getMaxRows() - unusedStartRow + 1, 1);
    unusedCheckboxes.clearDataValidations();
    unusedCheckboxes.clearContent();
  }
  proposals.getRange(2, 6, Math.max(1, proposals.getMaxRows() - 1), 1).clearDataValidations();

  let status = spreadsheet.getSheetByName(DCIP_SYNC.SHEETS.positionStatus);
  if (!status) status = spreadsheet.insertSheet(DCIP_SYNC.SHEETS.positionStatus);
  if (status.getMaxColumns() < DCIP_SYNC.HEADERS.positionStatus.length) {
    status.insertColumnsAfter(status.getMaxColumns(), DCIP_SYNC.HEADERS.positionStatus.length - status.getMaxColumns());
  }
  const statusHeaders = status.getRange(1, 1, 1, DCIP_SYNC.HEADERS.positionStatus.length).getDisplayValues()[0];
  if (statusHeaders.every(value => !value)) status.getRange(1, 1, 1, DCIP_SYNC.HEADERS.positionStatus.length).setValues([DCIP_SYNC.HEADERS.positionStatus]);
  if (!status.getRange('J1').getValue()) status.getRange('J1').setValue('status_key');
  status.setFrozenRows(1);
  status.getRange(1, 1, 1, 9).setBackground('#142f51').setFontColor('#ffffff')
    .setFontWeight('bold').setHorizontalAlignment('center').setVerticalAlignment('middle').setWrap(true);
  status.hideColumns(10);

  Object.values(DCIP_SYNC.SHEETS.inspection).forEach(name => {
    let raw = spreadsheet.getSheetByName(name);
    if (!raw) raw = spreadsheet.insertSheet(name);
    if (raw.getMaxColumns() < DCIP_SYNC.HEADERS.details.length) {
      raw.insertColumnsAfter(raw.getMaxColumns(), DCIP_SYNC.HEADERS.details.length - raw.getMaxColumns());
    }
    const headers = raw.getRange(1, 1, 1, DCIP_SYNC.HEADERS.details.length).getDisplayValues()[0];
    if (headers.every(value => !value)) {
      raw.getRange(1, 1, 1, DCIP_SYNC.HEADERS.details.length).setValues([DCIP_SYNC.HEADERS.details]);
    }
    raw.setFrozenRows(1);
    raw.hideSheet();
  });
}

function getUsulanContentLastRow_(sheet) {
  const maxRows = sheet.getMaxRows();
  if (maxRows < 2) return 1;
  const rows = sheet.getRange(2, 1, maxRows - 1, 6).getValues();
  for (let index = rows.length - 1; index >= 0; index--) {
    const row = rows[index];
    const visibleData = row.slice(0, 4).some(value => value !== '' && value !== null && typeof value !== 'boolean');
    if (visibleData || isUuid_(row[5])) return index + 2;
  }
  return 1;
}

function isUuid_(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(value || '').trim());
}

function ensureUsulanCheckbox_(sheet, row) {
  const checkbox = SpreadsheetApp.newDataValidation().requireCheckbox().setAllowInvalid(false)
    .setHelpText('Centang setelah usulan mulai ditindaklanjuti.').build();
  sheet.getRange(row, 5).setDataValidation(checkbox);
}

function handleUsulanConfirmation(e) {
  if (!e || !e.range) return;
  const sheet = e.range.getSheet();
  const row = e.range.getRow();
  if (sheet.getName() !== DCIP_SYNC.SHEETS.proposals || row < 2 || e.range.getColumn() !== 5 || e.range.getNumRows() !== 1 || e.range.getNumColumns() !== 1 ||
      String(e.value).toUpperCase() !== 'TRUE') return;
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    const requestId = String(sheet.getRange(row, 6).getDisplayValue() || '').trim();
    if (!isUuid_(requestId)) {
      sheet.getRange(row, 5).setValue(false);
      sheet.getParent().toast('Baris contoh/manual tanpa ID database tidak dapat dikonfirmasi.', 'USULAN', 6);
      return;
    }
    try {
      patchUsulanStatus_(requestId, getConfig_());
      sheet.deleteRow(row);
      renumberUsulan_(sheet);
      sheet.getParent().toast('Usulan ditandai diproses dan dihapus dari daftar aktif.', 'USULAN', 5);
    } catch (err) {
      sheet.getRange(row, 5).setValue(false);
      sheet.getParent().toast('Konfirmasi gagal disimpan ke Supabase: ' + err.message, 'USULAN', 8);
      throw err;
    }
  } finally {
    lock.releaseLock();
  }
}

function patchUsulanStatus_(requestId, config) {
  const headers = {
    apikey: config.secretKey,
    'Content-Type': 'application/json',
    Prefer: 'return=representation'
  };
  if (!config.secretKey.startsWith('sb_secret_')) headers.Authorization = 'Bearer ' + config.secretKey;
  const url = config.supabaseUrl + '/rest/v1/catalog_requests?id=eq.' +
    encodeURIComponent(requestId) + '&status=eq.DIAJUKAN';
  const response = UrlFetchApp.fetch(url, {
    method: 'patch',
    headers,
    payload: JSON.stringify({status: 'DIPROSES', handled_at: new Date().toISOString()}),
    muteHttpExceptions: true
  });
  const code = response.getResponseCode();
  if (code < 200 || code >= 300) {
    throw new Error('Supabase (' + code + '): ' + response.getContentText().slice(0, 300));
  }
}

function renumberUsulan_(sheet) {
  const last = getUsulanContentLastRow_(sheet);
  if (last < 2) return;
  const rows = sheet.getRange(2, 1, last - 1, 6).getValues();
  let number = 0;
  sheet.getRange(2, 1, last - 1, 1).setValues(rows.map(row => [isUuid_(row[5]) ? ++number : row[0]]));
}

function getStateSheet_(spreadsheet) {
  let sheet = spreadsheet.getSheetByName(DCIP_SYNC.STATE_SHEET);
  if (!sheet) {
    sheet = spreadsheet.insertSheet(DCIP_SYNC.STATE_SHEET);
    sheet.getRange(1, 1, 1, 2).setValues([['sheet_name','row_key']]);
    sheet.hideSheet();
  }
  const headers = sheet.getRange(1, 1, 1, 2).getDisplayValues()[0];
  if (headers[0] !== 'sheet_name' || headers[1] !== 'row_key') {
    throw new Error('Header tab sinkronisasi internal berubah.');
  }
  return sheet;
}

function readSyncState_(sheet) {
  const state = {};
  if (sheet.getLastRow() < 2) return state;
  sheet.getRange(2, 1, sheet.getLastRow() - 1, 2).getDisplayValues().forEach(([name, key]) => {
    if (!name || !key) return;
    if (!state[name]) state[name] = [];
    state[name].push(key);
  });
  return state;
}

function writeSyncState_(sheet, state) {
  const rows = [];
  Object.entries(state).forEach(([name, keys]) => keys.forEach(key => rows.push([name, key])));
  ensureRowCapacity_(sheet, rows.length + 1);
  const oldCount = Math.max(0, sheet.getLastRow() - 1);
  if (oldCount) sheet.getRange(2, 1, oldCount, 2).clearContent();
  if (rows.length) sheet.getRange(2, 1, rows.length, 2).setValues(rows);
}

function ensureRowCapacity_(sheet, requiredRow) {
  const currentRows = sheet.getMaxRows();
  if (requiredRow > currentRows) sheet.insertRowsAfter(currentRows, requiredRow - currentRows);
}

