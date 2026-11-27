create function public.enforce_dcip_inspection_division() returns trigger language plpgsql security invoker set search_path='' as $$
begin
  if auth.uid() is not null then
    if tg_op <> 'INSERT' and not public.can_access_dcip_division(old.division_id) then
      raise exception 'Akses divisi ditolak.' using errcode = '42501';
    end if;
    if tg_op <> 'DELETE' and not public.can_access_dcip_division(new.division_id) then
      raise exception 'Akses divisi ditolak.' using errcode = '42501';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
create trigger enforce_dcip_inspection_division before insert or update or delete on public.inspections for each row execute function public.enforce_dcip_inspection_division();