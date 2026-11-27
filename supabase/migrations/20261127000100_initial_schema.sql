begin;

create table public.divisions (
  id text primary key,
  name text not null unique
);

create table public.properties (
  id text primary key,
  name text not null unique
);

create table public.areas (
  id text primary key,
  name text not null unique
);

create table public.position_codes (
  id text primary key,
  name text not null unique
);

create table public.locations (
  id text primary key default ('LOC-' || gen_random_uuid()::text),
  property_id text not null references public.properties(id),
  area_id text not null references public.areas(id),
  name text not null,
  normalized_name text generated always as (
    regexp_replace(upper(btrim(regexp_replace(normalize(name, NFKC), '[[:space:]]+', ' ', 'g'))),
      '^0+([0-9]+)$', '\1')
  ) stored,
  display_order integer not null default 1 check (display_order > 0),
  check (normalized_name <> ''),
  unique (property_id, area_id, normalized_name),
  unique (id, property_id)
);

create table public.property_memberships (
  user_id uuid not null references auth.users(id) on delete cascade,
  property_id text not null references public.properties(id),
  role text not null check (role in ('admin', 'petugas')),
  primary key (user_id, property_id)
);

create table public.material_items (
  division_id text not null references public.divisions(id),
  position_id text not null references public.position_codes(id),
  id text not null,
  name text not null,
  display_order integer not null check (display_order > 0),
  primary key (division_id, position_id, id),
  unique (division_id, position_id, display_order)
);

create table public.material_options (
  id text primary key,
  division_id text not null,
  position_id text not null,
  item_id text not null,
  value text not null,
  display_order integer not null check (display_order > 0),
  option_type text not null check (option_type in ('REGULER', 'SISTEM')),
  source text not null,
  foreign key (division_id, position_id, item_id)
    references public.material_items(division_id, position_id, id),
  unique (division_id, position_id, item_id, display_order),
  unique (division_id, position_id, item_id, id)
);

create table public.inspections (
  id uuid primary key default gen_random_uuid(),
  division_id text not null references public.divisions(id),
  position_id text not null references public.position_codes(id),
  location_id text not null,
  property_id text not null,
  location_name text not null,
  property_name text not null,
  area_name text not null,
  position_name text not null,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (location_id, property_id) references public.locations(id, property_id),
  unique (division_id, location_id, position_id),
  unique (id, division_id, position_id)
);

create table public.inspection_answers (
  inspection_id uuid not null,
  division_id text not null,
  position_id text not null,
  item_id text not null,
  option_id text not null,
  item_name text not null,
  option_value text not null,
  custom_specification text,
  primary key (inspection_id, item_id),
  foreign key (inspection_id, division_id, position_id)
    references public.inspections(id, division_id, position_id) on delete cascade,
  foreign key (division_id, position_id, item_id, option_id)
    references public.material_options(division_id, position_id, item_id, id),
  check (upper(btrim(option_value)) <> 'LAINNYA' or
    nullif(btrim(custom_specification), '') is not null)
);

create index property_memberships_property_idx on public.property_memberships(property_id);
create index inspections_property_idx on public.inspections(property_id);
create index locations_property_idx on public.locations(property_id);

-- In this phase clients can only read. Saving a full checklist will use a
-- dedicated transaction in the next migration.
do $$
declare
  nama text;
begin
  foreach nama in array array['divisions', 'properties', 'areas', 'position_codes',
    'locations', 'property_memberships', 'material_items', 'material_options',
    'inspections', 'inspection_answers']
  loop
    execute format('alter table public.%I enable row level security', nama);
    execute format('revoke all on table public.%I from anon, authenticated', nama);
    execute format('grant select on table public.%I to authenticated', nama);
  end loop;
end $$;

create policy memberships_self on public.property_memberships
  for select to authenticated using (user_id = (select auth.uid()));

create policy properties_assigned on public.properties
  for select to authenticated using (
    exists (select 1 from public.property_memberships m where m.property_id = properties.id)
  );
create policy locations_assigned on public.locations
  for select to authenticated using (
    exists (select 1 from public.property_memberships m where m.property_id = locations.property_id)
  );
create policy inspections_assigned on public.inspections
  for select to authenticated using (
    exists (select 1 from public.property_memberships m where m.property_id = inspections.property_id)
  );
create policy answers_assigned on public.inspection_answers
  for select to authenticated using (
    exists (select 1 from public.inspections i where i.id = inspection_answers.inspection_id)
  );

do $$
declare
  nama text;
begin
  foreach nama in array array['divisions', 'areas', 'position_codes', 'material_items', 'material_options']
  loop
    execute format('create policy catalog_assigned on public.%I for select to authenticated using (
      exists (select 1 from public.property_memberships))', nama);
  end loop;
end $$;

commit;
