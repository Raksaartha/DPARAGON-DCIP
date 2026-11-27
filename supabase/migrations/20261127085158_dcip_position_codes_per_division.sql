create table public.division_position_codes (
  division_id text not null references public.divisions(id) on delete cascade,
  position_id text not null references public.position_codes(id) on delete cascade,
  primary key (division_id,position_id)
);
insert into public.division_position_codes select d.id,p.id from public.divisions d cross join public.position_codes p;
alter table public.division_position_codes enable row level security;
grant select on public.division_position_codes to authenticated, service_role;
create policy read_division_position_codes on public.division_position_codes for select to authenticated
using (public.can_access_dcip_division(division_id));

create function public.add_division_position(p_division_id text,p_name text) returns text
language plpgsql security definer set search_path='' as $$
declare v_id text; v_name text := btrim(p_name);
begin
  if not public.can_manage_dcip_division(p_division_id) then raise exception 'Akses divisi ditolak'; end if;
  if v_name is null or char_length(v_name) not between 1 and 120 then raise exception 'Nama kode posisi tidak valid'; end if;
  perform pg_advisory_xact_lock(hashtext(lower(v_name)));
  select id into v_id from public.position_codes where lower(btrim(name))=lower(v_name)
  order by (name=v_name) desc,id limit 1;
  if v_id is null then
    v_id := 'POS-' || gen_random_uuid()::text;
    insert into public.position_codes(id,name) values (v_id,v_name);
  end if;
  insert into public.division_position_codes values (p_division_id,v_id) on conflict do nothing;
  return v_id;
end;
$$;
revoke all on function public.add_division_position(text,text) from public;
grant execute on function public.add_division_position(text,text) to authenticated;

create function public.remove_division_position(p_division_id text,p_position_id text) returns void
language plpgsql security definer set search_path='' as $$
begin
  if not public.can_manage_dcip_division(p_division_id) then raise exception 'Akses divisi ditolak'; end if;
  delete from public.division_position_codes where division_id=p_division_id and position_id=p_position_id;
end;
$$;
revoke all on function public.remove_division_position(text,text) from public;
grant execute on function public.remove_division_position(text,text) to authenticated;

create table public.division_position_status (
  division_id text not null references public.divisions(id) on delete cascade,
  location_id text not null references public.locations(id) on delete cascade,
  position_id text not null references public.position_codes(id) on delete cascade,
  status text not null check (status in ('ADA','TIDAK_TERDAPAT')),
  primary key (division_id,location_id,position_id)
);
insert into public.division_position_status
select c.division_id,s.location_id,s.position_id,s.status
from public.location_position_status s join public.division_position_codes c on c.position_id=s.position_id;
alter table public.division_position_status enable row level security;
grant select on public.division_position_status to authenticated;
create policy read_division_position_status on public.division_position_status for select to authenticated using (
 public.can_manage_dcip_division(division_id) or (public.can_access_dcip_division(division_id)
 and exists(select 1 from public.locations l where l.id=division_position_status.location_id))
);
create function public.set_division_position_status(p_division_id text,p_location_id text,p_position_id text,p_status text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not public.can_access_dcip_division(p_division_id) or not (
    public.can_manage_dcip_division(p_division_id) or exists (
      select 1 from public.locations l join public.property_memberships m on m.property_id=l.property_id
      where l.id=p_location_id and m.user_id=auth.uid()
    )
  ) then raise exception 'Akses lokasi atau divisi ditolak'; end if;
  if not exists(select 1 from public.division_position_codes where division_id=p_division_id and position_id=p_position_id)
    then raise exception 'Kode posisi tidak tersedia untuk divisi ini'; end if;
  perform pg_advisory_xact_lock(hashtext(p_location_id),hashtext(p_position_id));
  if p_status='TIDAK_TERDAPAT' and exists(select 1 from public.inspections
    where division_id=p_division_id and location_id=p_location_id and position_id=p_position_id)
    then raise exception 'Kode posisi sudah memiliki pendataan'; end if;
  insert into public.division_position_status values (p_division_id,p_location_id,p_position_id,p_status)
  on conflict (division_id,location_id,position_id) do update set status=excluded.status;
end;
$$;
revoke all on function public.set_division_position_status(text,text,text,text) from public;
grant execute on function public.set_division_position_status(text,text,text,text) to authenticated;

create or replace function public.enforce_location_position_presence() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  perform pg_advisory_xact_lock(hashtext(new.location_id),hashtext(new.position_id));
  if exists(select 1 from public.division_position_status s where s.division_id=new.division_id
     and s.location_id=new.location_id and s.position_id=new.position_id and s.status='TIDAK_TERDAPAT')
    then raise exception 'Kode posisi ini ditandai tidak terdapat pada lokasi'; end if;
  return new;
end;
$$;
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
  if p_inspection_id is null and not exists (
    select 1 from public.division_position_codes c
    where c.division_id=p_division_id and c.position_id=p_position_id
  ) then raise exception 'Kode posisi tidak tersedia untuk divisi ini'; end if;
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
  if p_action = 'DISETUJUI' and v_request.request_type = 'AREA' and not public.is_current_user_admin() then
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
        perform public.add_division_position(v_request.division_id, v_request.value);
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
