alter table public.user_profiles drop constraint user_profiles_role_check;
alter table public.user_profiles add constraint user_profiles_role_check check (role in ('admin','petugas','sub_admin') and (role <> 'sub_admin' or division_id is not null));
create or replace function public.can_manage_dcip_division(target text) returns boolean
language sql stable set search_path = '' as $$
  select exists(select 1 from public.user_profiles p where p.id=(select auth.uid())
    and (p.role='admin' or (p.role='sub_admin' and p.division_id=target)))
$$;
revoke all on function public.can_manage_dcip_division(text) from public;
grant execute on function public.can_manage_dcip_division(text) to authenticated;
CREATE OR REPLACE FUNCTION public.can_access_dcip_division(target text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
select exists(select 1 from public.user_profiles p where p.id=(select auth.uid()) and (p.role='admin' or (p.role='petugas' and p.division_id is null) or p.division_id=target));
$function$
;
create policy scoped_admin_read_divisions on public.divisions for select to authenticated using (public.can_manage_dcip_division(id));
create policy scoped_admin_read_properties on public.properties for select to authenticated using (exists(select 1 from public.user_profiles p where p.id=(select auth.uid()) and p.role='sub_admin'));
create policy scoped_admin_read_areas on public.areas for select to authenticated using (exists(select 1 from public.user_profiles p where p.id=(select auth.uid()) and p.role='sub_admin'));
create policy scoped_admin_read_position_codes on public.position_codes for select to authenticated using (exists(select 1 from public.user_profiles p where p.id=(select auth.uid()) and p.role='sub_admin'));
create policy scoped_admin_read_locations on public.locations for select to authenticated using (exists(select 1 from public.user_profiles p where p.id=(select auth.uid()) and p.role='sub_admin'));
create policy scoped_admin_read_location_position_status on public.location_position_status for select to authenticated using (exists(select 1 from public.user_profiles p where p.id=(select auth.uid()) and p.role='sub_admin'));
create policy scoped_admin_read_material_items on public.material_items for select to authenticated using (public.can_manage_dcip_division(division_id));
create policy scoped_division_boundary_material_items on public.material_items as restrictive for all to authenticated using (public.can_access_dcip_division(division_id)) with check (public.can_access_dcip_division(division_id));
create policy scoped_admin_read_material_options on public.material_options for select to authenticated using (public.can_manage_dcip_division(division_id));
create policy scoped_division_boundary_material_options on public.material_options as restrictive for all to authenticated using (public.can_access_dcip_division(division_id)) with check (public.can_access_dcip_division(division_id));
create policy scoped_admin_read_inspections on public.inspections for select to authenticated using (public.can_manage_dcip_division(division_id));
create policy scoped_division_boundary_inspections on public.inspections as restrictive for all to authenticated using (public.can_access_dcip_division(division_id)) with check (public.can_access_dcip_division(division_id));
create policy scoped_admin_read_inspection_answers on public.inspection_answers for select to authenticated using (public.can_manage_dcip_division(division_id));
create policy scoped_division_boundary_inspection_answers on public.inspection_answers as restrictive for all to authenticated using (public.can_access_dcip_division(division_id)) with check (public.can_access_dcip_division(division_id));
create policy scoped_admin_read_catalog_requests on public.catalog_requests for select to authenticated using (public.can_manage_dcip_division(division_id));
create policy scoped_division_boundary_catalog_requests on public.catalog_requests as restrictive for all to authenticated using (public.can_access_dcip_division(division_id)) with check (public.can_access_dcip_division(division_id));
create policy scoped_admin_edit_items on public.material_items for update to authenticated using (public.can_manage_dcip_division(division_id)) with check (public.can_manage_dcip_division(division_id));
create policy scoped_admin_edit_options on public.material_options for update to authenticated using (public.can_manage_dcip_division(division_id) and option_type='REGULER') with check (public.can_manage_dcip_division(division_id) and option_type='REGULER');
create policy scoped_admin_add_options on public.material_options for insert to authenticated with check (public.can_manage_dcip_division(division_id) and option_type='REGULER' and not retired);
create policy scoped_admin_submit_request on public.catalog_requests for insert to authenticated
with check (public.can_manage_dcip_division(division_id) and requested_by=(select auth.uid()) and status='DIAJUKAN' and reviewed_by is null);
CREATE OR REPLACE FUNCTION public.save_inspection(p_division_id text, p_location_id text, p_position_id text, p_answers jsonb, p_inspection_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := auth.uid();
  v_location public.locations%rowtype;
  v_division_name text;
  v_position_name text;
  v_property_name text;
  v_expected integer;
  v_valid integer;
  v_id uuid;
begin
  if v_user is null then raise exception 'Silakan masuk terlebih dahulu'; end if;
  if not public.can_access_dcip_division(p_division_id) then raise exception 'Akses divisi ditolak'; end if;
  select * into v_location from public.locations where id=p_location_id;
  if not found then raise exception 'Lokasi tidak ditemukan'; end if;
  if not exists (
    select 1 from public.property_memberships m
    where m.user_id=v_user and m.property_id=v_location.property_id
  ) and not public.can_manage_dcip_division(p_division_id) then raise exception 'Akses properti ditolak'; end if;
  select name into v_division_name from public.divisions where id=p_division_id;
  select name into v_position_name from public.position_codes where id=p_position_id;
  select name into v_property_name from public.properties where id=v_location.property_id;
  if v_division_name is null or v_position_name is null then raise exception 'Divisi atau kode posisi tidak tersedia'; end if;
  if jsonb_typeof(p_answers) is distinct from 'array' then raise exception 'Jawaban harus berupa daftar'; end if;
  select count(*) into v_expected from public.material_items
  where division_id=p_division_id and position_id=p_position_id and not retired;
  if v_expected=0 or jsonb_array_length(p_answers)<>v_expected then
    raise exception 'Jumlah jawaban belum lengkap';
  end if;
  select count(*) into v_valid
  from (
    select a.item_id, count(*) as occurrences
    from jsonb_to_recordset(p_answers) as a(item_id text,option_id text,custom_specification text)
    join public.material_options o
      on o.id=a.option_id and o.division_id=p_division_id
      and o.position_id=p_position_id and o.item_id=a.item_id
    join public.material_items i on i.division_id=o.division_id and i.position_id=o.position_id and i.id=o.item_id
    where not i.retired and (upper(btrim(o.value))<>'LAINNYA'
       or nullif(btrim(a.custom_specification),'') is not null)
    group by a.item_id
    having count(*)=1
  ) checked;
  if v_valid<>v_expected then raise exception 'Jawaban tidak valid atau belum lengkap'; end if;
  if p_inspection_id is null then
    insert into public.inspections(
      division_id,position_id,location_id,property_id,location_name,
      property_name,area_name,position_name,created_by,updated_by
    )
    select p_division_id,p_position_id,v_location.id,v_location.property_id,
      v_location.name,v_property_name,a.name,v_position_name,v_user,v_user
    from public.areas a where a.id=v_location.area_id
    returning id into v_id;
  else
    update public.inspections
    set updated_by=v_user,updated_at=now()
    where id=p_inspection_id and division_id=p_division_id
      and position_id=p_position_id and location_id=p_location_id
    returning id into v_id;
    if v_id is null then raise exception 'Pendataan untuk diedit tidak ditemukan'; end if;
    delete from public.inspection_answers a using public.material_items i
    where a.inspection_id=v_id and i.division_id=a.division_id and i.position_id=a.position_id
      and i.id=a.item_id and not i.retired;
  end if;
  insert into public.inspection_answers(
    inspection_id,division_id,position_id,item_id,option_id,
    item_name,option_value,custom_specification
  )
  select v_id,p_division_id,p_position_id,a.item_id,a.option_id,
    i.name,o.value,nullif(btrim(a.custom_specification),'')
  from jsonb_to_recordset(p_answers) as a(item_id text,option_id text,custom_specification text)
  join public.material_items i on i.division_id=p_division_id
    and i.position_id=p_position_id and i.id=a.item_id
  join public.material_options o on o.id=a.option_id
    and o.division_id=p_division_id and o.position_id=p_position_id
    and o.item_id=a.item_id;
  return v_id;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.delete_inspection(p_inspection_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_user uuid := auth.uid(); v_property text; v_division text;
begin
  if v_user is null then raise exception 'Silakan masuk terlebih dahulu'; end if;
  select property_id, division_id into v_property, v_division from public.inspections where id=p_inspection_id;
  if v_property is null then raise exception 'Pendataan tidak ditemukan'; end if;
  if not public.can_access_dcip_division(v_division) then raise exception 'Akses divisi ditolak'; end if;
  if not exists(select 1 from public.property_memberships m where m.user_id=v_user and m.property_id=v_property)
     and not public.can_manage_dcip_division(v_division)
  then raise exception 'Akses properti ditolak'; end if;
  delete from public.inspections where id=p_inspection_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.review_catalog_request(p_request_id uuid, p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := auth.uid();
  v_request public.catalog_requests%rowtype;
  v_new_id text;
  v_order integer;
begin
  if v_user is null then
    raise exception 'Hanya Admin yang dapat memproses usulan';
  end if;

  select * into v_request
  from public.catalog_requests
  where id = p_request_id
  for update;
  if not found then raise exception 'Usulan tidak ditemukan'; end if;
  if not public.can_manage_dcip_division(v_request.division_id) then raise exception 'Akses divisi ditolak'; end if;
  if p_action = 'DISETUJUI' and v_request.request_type in ('AREA','KODE_POSISI') and not public.is_current_user_admin() then
    raise exception 'Perubahan data bersama harus disetujui Admin Utama';
  end if;
  if v_request.status not in ('DIAJUKAN', 'DIPROSES') then
    raise exception 'Usulan ini sudah ditinjau';
  end if;

  if p_action = 'DIPROSES' then
    update public.catalog_requests
    set status = 'DIPROSES', handled_by = v_user, handled_at = now(), updated_at = now()
    where id = p_request_id returning * into v_request;
    return to_jsonb(v_request);
  end if;

  if p_action not in ('DISETUJUI', 'DITOLAK') then
    raise exception 'Tindakan usulan tidak valid';
  end if;

  if p_action = 'DISETUJUI' then
    case v_request.request_type
      when 'AREA' then
        if exists (select 1 from public.areas a where lower(btrim(a.name)) = lower(btrim(v_request.value))) then
          raise exception 'Nama area yang sama sudah tersedia';
        end if;
        v_new_id := 'AREA-' || gen_random_uuid()::text;
        insert into public.areas(id, name) values (v_new_id, btrim(v_request.value));
      when 'KODE_POSISI' then
        if exists (select 1 from public.position_codes p where lower(btrim(p.name)) = lower(btrim(v_request.value))) then
          raise exception 'Kode posisi yang sama sudah tersedia';
        end if;
        v_new_id := 'POS-' || gen_random_uuid()::text;
        insert into public.position_codes(id, name) values (v_new_id, btrim(v_request.value));
      when 'KOMPONEN' then
        perform pg_advisory_xact_lock(hashtext(v_request.division_id), hashtext(v_request.position_id));
        if exists (
          select 1 from public.material_items i
          where i.division_id = v_request.division_id
            and i.position_id = v_request.position_id
            and lower(btrim(i.name)) = lower(btrim(v_request.value))
        ) then raise exception 'Komponen yang sama sudah tersedia untuk posisi ini'; end if;
        select coalesce(max(i.display_order), 0) + 1 into v_order
        from public.material_items i
        where i.division_id = v_request.division_id and i.position_id = v_request.position_id;
        v_new_id := 'ITEM-' || gen_random_uuid()::text;
        insert into public.material_items(division_id, position_id, id, name, display_order)
        values (v_request.division_id, v_request.position_id, v_new_id, btrim(v_request.value), v_order);
      when 'SPESIFIKASI_MATERIAL' then
        perform pg_advisory_xact_lock(hashtext(v_request.division_id), hashtext(v_request.item_id));
        if exists (
          select 1 from public.material_options o
          where o.division_id = v_request.division_id
            and o.position_id = v_request.position_id
            and o.item_id = v_request.item_id
            and lower(btrim(o.value)) = lower(btrim(v_request.value))
        ) then raise exception 'Spesifikasi material yang sama sudah tersedia'; end if;
        select coalesce(max(o.display_order), 0) + 1 into v_order
        from public.material_options o
        where o.division_id = v_request.division_id
          and o.position_id = v_request.position_id and o.item_id = v_request.item_id;
        v_new_id := 'OPT-' || gen_random_uuid()::text;
        insert into public.material_options(
          id, division_id, position_id, item_id, value, display_order, option_type, source
        ) values (
          v_new_id, v_request.division_id, v_request.position_id, v_request.item_id,
          btrim(v_request.value), v_order, 'REGULER', 'USULAN'
        );
    end case;
  end if;

  update public.catalog_requests
  set status = p_action, reviewed_by = v_user, reviewed_at = now(), updated_at = now()
  where id = p_request_id
  returning * into v_request;
  return to_jsonb(v_request) || jsonb_build_object('created_catalog_id', v_new_id);
end;
$function$
;

