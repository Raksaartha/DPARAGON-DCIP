alter table public.material_items add column retired boolean not null default false;
grant update (retired) on public.material_items to authenticated;
create policy checklist_admin_retire_item on public.material_items for update to authenticated
using ((select public.is_current_user_admin())) with check ((select public.is_current_user_admin()));
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
  select * into v_location from public.locations where id=p_location_id;
  if not found then raise exception 'Lokasi tidak ditemukan'; end if;
  if not exists (
    select 1 from public.property_memberships m
    where m.user_id=v_user and m.property_id=v_location.property_id
  ) and not exists (
    select 1 from public.user_profiles p where p.id=v_user and p.role='admin'
  ) then raise exception 'Akses properti ditolak'; end if;
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
