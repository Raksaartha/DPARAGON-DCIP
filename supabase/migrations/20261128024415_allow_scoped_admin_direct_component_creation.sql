create function public.add_checklist_component(p_division_id text,p_position_id text,p_name text)
returns text language plpgsql security definer set search_path='' as $$
declare v_name text:=btrim(p_name); v_id text; v_retired boolean; v_order integer;
begin
 if not public.can_manage_dcip_division(p_division_id) then raise exception 'Akses divisi ditolak'; end if;
 if v_name is null or char_length(v_name) not between 1 and 120 then raise exception 'Nama komponen harus 1–120 karakter'; end if;
 if not exists(select 1 from public.division_position_codes where division_id=p_division_id and position_id=p_position_id) then
   raise exception 'Kode posisi tidak tersedia untuk divisi ini';
 end if;
 perform pg_advisory_xact_lock(hashtext(p_division_id),hashtext(p_position_id));
 select id,retired into v_id,v_retired from public.material_items
 where division_id=p_division_id and position_id=p_position_id and lower(btrim(name))=lower(v_name)
 order by retired,id limit 1;
 if found then
   if not v_retired then raise exception 'Komponen ini sudah tersedia'; end if;
   update public.material_items set retired=false where division_id=p_division_id and position_id=p_position_id and id=v_id;
   return v_id;
 end if;
 select coalesce(max(display_order),0)+1 into v_order from public.material_items
 where division_id=p_division_id and position_id=p_position_id;
 v_id:='ITEM-'||gen_random_uuid()::text;
 insert into public.material_items(division_id,position_id,id,name,display_order) values(p_division_id,p_position_id,v_id,v_name,v_order);
 return v_id;
end;
$$;
revoke all on function public.add_checklist_component(text,text,text) from public, anon;
grant execute on function public.add_checklist_component(text,text,text) to authenticated;
