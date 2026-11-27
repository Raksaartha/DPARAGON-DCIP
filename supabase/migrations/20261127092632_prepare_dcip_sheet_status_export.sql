alter table public.division_position_status add column if not exists updated_at timestamptz not null default now(), add column if not exists updated_by uuid references auth.users(id) on delete set null;
create function public.stamp_division_position_status() returns trigger language plpgsql set search_path='' as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;
create trigger stamp_division_position_status before insert or update on public.division_position_status for each row execute function public.stamp_division_position_status();
grant select on public.areas, public.position_codes, public.locations, public.material_items, public.material_options, public.inspections, public.inspection_answers, public.division_position_status, public.catalog_requests to service_role;
grant update (status, handled_at) on public.catalog_requests to service_role;
