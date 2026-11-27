begin;

drop policy if exists properties_assigned on public.properties;
create policy properties_assigned
  on public.properties for select to authenticated
  using (
    (select public.is_current_user_admin())
    or exists (select 1 from public.property_memberships m where m.property_id = properties.id)
  );

drop policy if exists locations_assigned on public.locations;
create policy locations_assigned
  on public.locations for select to authenticated
  using (
    (select public.is_current_user_admin())
    or exists (select 1 from public.property_memberships m where m.property_id = locations.property_id)
  );

drop policy if exists inspections_assigned on public.inspections;
create policy inspections_assigned
  on public.inspections for select to authenticated
  using (
    (select public.is_current_user_admin())
    or exists (select 1 from public.property_memberships m where m.property_id = inspections.property_id)
  );

do $$
declare
  table_name text;
begin
  foreach table_name in array array['divisions', 'areas', 'position_codes', 'material_items', 'material_options']
  loop
    execute format('drop policy if exists catalog_assigned on public.%I', table_name);
    execute format('create policy catalog_assigned on public.%I for select to authenticated using (
      (select public.is_current_user_admin()) or exists (select 1 from public.property_memberships)
    )', table_name);
  end loop;
end $$;

commit;
