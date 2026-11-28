create or replace function public.delete_location(p_location_id text) returns void
language plpgsql security definer set search_path='' as $$
begin
  if not public.is_current_user_admin() then raise exception 'Hanya Admin Utama yang dapat menghapus lokasi' using errcode='42501'; end if;
  if not exists(select 1 from public.locations where id=p_location_id) then raise exception 'Lokasi tidak ditemukan'; end if;
  delete from public.inspections where location_id=p_location_id;
  delete from public.locations where id=p_location_id;
end;
$$;
grant select on public.property_memberships to service_role;
create function public.update_dcip_staff_access(p_caller uuid,p_id uuid,p_name text,p_division text,p_properties text[])
returns void language plpgsql security definer set search_path='' as $$
declare caller public.user_profiles%rowtype; target public.user_profiles%rowtype;
begin
 select * into caller from public.user_profiles where id=p_caller;
 select * into target from public.user_profiles where id=p_id for update;
 if caller.role is null or (caller.role <> 'admin' and (caller.role <> 'sub_admin' or caller.division_id is distinct from target.division_id or caller.division_id is distinct from p_division))
    or target.role is distinct from 'petugas' then raise exception 'Akses akun ditolak' using errcode='42501'; end if;
 if p_name is null or char_length(btrim(p_name)) not between 2 and 80 or not exists(select 1 from public.divisions where id=p_division) then raise exception 'Nama atau divisi tidak valid'; end if;
 if p_properties is null or exists(select 1 from unnest(p_properties) v(id) where not exists(select 1 from public.properties p where p.id=v.id)) then raise exception 'Properti tidak valid'; end if;
 update public.user_profiles set display_name=btrim(p_name),division_id=p_division where id=p_id;
 delete from public.property_memberships where user_id=p_id and not (property_id=any(p_properties));
 insert into public.property_memberships(user_id,property_id,role)
 select p_id,v.id,'petugas' from (select distinct unnest(p_properties) id) v
 where not exists(select 1 from public.property_memberships m where m.user_id=p_id and m.property_id=v.id);
end;
$$;
revoke all on function public.update_dcip_staff_access(uuid,uuid,text,text,text[]) from public,anon,authenticated;
grant execute on function public.update_dcip_staff_access(uuid,uuid,text,text,text[]) to service_role;
