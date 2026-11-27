-- Ensure each newly approved component has the standard system options needed by the checklist UI.
create or replace function public.seed_default_material_options()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.material_options (
    id, division_id, position_id, item_id, value, display_order, option_type, source
  )
  values
    ('OPT-' || gen_random_uuid()::text, new.division_id, new.position_id, new.id, 'Lainnya', 1, 'SISTEM', 'SISTEM'),
    ('OPT-' || gen_random_uuid()::text, new.division_id, new.position_id, new.id, 'Tidak Ada', 2, 'SISTEM', 'SISTEM'),
    ('OPT-' || gen_random_uuid()::text, new.division_id, new.position_id, new.id, 'Belum diketahui', 3, 'SISTEM', 'SISTEM');

  return new;
end;
$$;

revoke all on function public.seed_default_material_options() from public, anon, authenticated;

drop trigger if exists seed_default_material_options_after_insert on public.material_items;
create trigger seed_default_material_options_after_insert
  after insert on public.material_items
  for each row execute function public.seed_default_material_options();
