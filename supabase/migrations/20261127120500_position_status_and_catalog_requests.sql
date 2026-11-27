-- Track whether each standard position exists at a location and collect
-- controlled catalog proposals from inspectors.

create table public.location_position_status (
  location_id text not null,
  property_id text not null,
  position_id text not null references public.position_codes(id) on delete restrict,
  status text not null check (status in ('ADA', 'TIDAK_TERDAPAT')),
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (location_id, position_id),
  foreign key (location_id, property_id)
    references public.locations(id, property_id) on delete cascade
);

create index location_position_status_property_idx
  on public.location_position_status(property_id, location_id);

alter table public.location_position_status enable row level security;
grant select, insert, update on public.location_position_status to authenticated;

create policy location_position_status_read on public.location_position_status
  for select to authenticated
  using (
    (select public.is_current_user_admin())
    or exists (
      select 1 from public.property_memberships m
      where m.user_id = (select auth.uid())
        and m.property_id = location_position_status.property_id
    )
  );

create policy location_position_status_insert on public.location_position_status
  for insert to authenticated
  with check (
    (select public.is_current_user_admin())
    or exists (
      select 1 from public.property_memberships m
      where m.user_id = (select auth.uid())
        and m.property_id = location_position_status.property_id
    )
  );

create policy location_position_status_update on public.location_position_status
  for update to authenticated
  using (
    (select public.is_current_user_admin())
    or exists (
      select 1 from public.property_memberships m
      where m.user_id = (select auth.uid())
        and m.property_id = location_position_status.property_id
    )
  )
  with check (
    (select public.is_current_user_admin())
    or exists (
      select 1 from public.property_memberships m
      where m.user_id = (select auth.uid())
        and m.property_id = location_position_status.property_id
    )
  );

create table public.catalog_requests (
  id uuid primary key default gen_random_uuid(),
  division_id text not null references public.divisions(id) on delete restrict,
  request_type text not null check (
    request_type in ('AREA', 'KODE_POSISI', 'KOMPONEN', 'SPESIFIKASI_MATERIAL')
  ),
  value text not null check (btrim(value) <> ''),
  property_id text references public.properties(id) on delete set null,
  location_id text references public.locations(id) on delete set null,
  position_id text references public.position_codes(id) on delete restrict,
  item_id text,
  requested_by uuid default auth.uid() references auth.users(id) on delete set null,
  status text not null default 'DIAJUKAN' check (
    status in ('DIAJUKAN', 'DIPROSES', 'DISETUJUI', 'DITOLAK')
  ),
  handled_by uuid references auth.users(id) on delete set null,
  handled_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  admin_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (division_id, position_id, item_id)
    references public.material_items(division_id, position_id, id) on delete restrict,
  check (
    (location_id is null or property_id is not null)
    and (
      (request_type in ('AREA', 'KODE_POSISI') and position_id is null and item_id is null)
      or (request_type = 'KOMPONEN' and position_id is not null and item_id is null)
      or (request_type = 'SPESIFIKASI_MATERIAL' and position_id is not null and item_id is not null)
    )
  )
);

create index catalog_requests_status_created_idx
  on public.catalog_requests(status, created_at desc);
create index catalog_requests_requester_idx
  on public.catalog_requests(requested_by, created_at desc);
create unique index catalog_requests_open_dedup_idx
  on public.catalog_requests (
    division_id,
    request_type,
    coalesce(position_id, ''),
    coalesce(item_id, ''),
    lower(regexp_replace(btrim(value), '\s+', ' ', 'g'))
  )
  where status in ('DIAJUKAN', 'DIPROSES');

alter table public.catalog_requests enable row level security;
grant select, insert on public.catalog_requests to authenticated;

create policy catalog_requests_read on public.catalog_requests
  for select to authenticated
  using (
    requested_by = (select auth.uid())
    or (select public.is_current_user_admin())
  );

create policy catalog_requests_insert on public.catalog_requests
  for insert to authenticated
  with check (
    requested_by = (select auth.uid())
    and status = 'DIAJUKAN'
    and reviewed_by is null
    and (
      property_id is null
      or (select public.is_current_user_admin())
      or exists (
        select 1 from public.property_memberships m
        where m.user_id = (select auth.uid())
          and m.property_id = catalog_requests.property_id
      )
    )
  );

create or replace function public.validate_catalog_request_location()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_property_id text;
begin
  if new.location_id is null then return new; end if;
  select l.property_id into v_property_id
  from public.locations l where l.id = new.location_id;
  if v_property_id is distinct from new.property_id then
    raise exception 'Lokasi tidak sesuai dengan properti yang dipilih';
  end if;
  return new;
end;
$$;

create trigger validate_catalog_request_location
  before insert or update of location_id, property_id on public.catalog_requests
  for each row execute function public.validate_catalog_request_location();

-- Keep position presence changes and checklist creation mutually consistent.
create or replace function public.set_location_position_status(
  p_location_id text,
  p_position_id text,
  p_status text
)
returns public.location_position_status
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_property_id text;
  v_row public.location_position_status%rowtype;
begin
  if v_user is null then raise exception 'Silakan masuk terlebih dahulu'; end if;
  if p_status not in ('ADA', 'TIDAK_TERDAPAT') then
    raise exception 'Status kode posisi tidak valid';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_location_id), hashtext(p_position_id));

  select l.property_id into v_property_id
  from public.locations l where l.id = p_location_id;
  if v_property_id is null then raise exception 'Lokasi tidak ditemukan'; end if;

  if not (select public.is_current_user_admin()) and not exists (
    select 1 from public.property_memberships m
    where m.user_id = v_user and m.property_id = v_property_id
  ) then raise exception 'Akses properti ditolak'; end if;

  if p_status = 'TIDAK_TERDAPAT' and exists (
    select 1 from public.inspections i
    where i.location_id = p_location_id and i.position_id = p_position_id
  ) then
    raise exception 'Kode posisi sudah memiliki pendataan. Hapus atau tinjau pendataan tersebut terlebih dahulu.';
  end if;

  insert into public.location_position_status (
    location_id, property_id, position_id, status, created_by, updated_by
  ) values (
    p_location_id, v_property_id, p_position_id, p_status, v_user, v_user
  )
  on conflict (location_id, position_id) do update
    set status = excluded.status,
        updated_by = v_user,
        updated_at = now()
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.set_location_position_status(text, text, text) from public, anon;
grant execute on function public.set_location_position_status(text, text, text) to authenticated;

create or replace function public.enforce_location_position_presence()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtext(new.location_id), hashtext(new.position_id));

  if exists (
    select 1 from public.location_position_status s
    where s.location_id = new.location_id
      and s.position_id = new.position_id
      and s.status = 'TIDAK_TERDAPAT'
  ) then
    raise exception 'Kode posisi ini ditandai tidak terdapat pada lokasi';
  end if;

  insert into public.location_position_status (
    location_id, property_id, position_id, status, created_by, updated_by
  ) values (
    new.location_id, new.property_id, new.position_id, 'ADA', auth.uid(), auth.uid()
  )
  on conflict (location_id, position_id) do update
    set status = 'ADA', updated_by = auth.uid(), updated_at = now();

  return new;
end;
$$;

revoke all on function public.enforce_location_position_presence() from public, anon, authenticated;
create trigger enforce_location_position_presence
  before insert or update of location_id, position_id on public.inspections
  for each row execute function public.enforce_location_position_presence();

-- Inspector submissions stay pending until an admin processes them.
create or replace function public.review_catalog_request(
  p_request_id uuid,
  p_action text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_request public.catalog_requests%rowtype;
  v_new_id text;
  v_order integer;
begin
  if v_user is null or not (select public.is_current_user_admin()) then
    raise exception 'Hanya Admin yang dapat memproses usulan';
  end if;

  select * into v_request
  from public.catalog_requests
  where id = p_request_id
  for update;
  if not found then raise exception 'Usulan tidak ditemukan'; end if;
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
$$;

revoke all on function public.review_catalog_request(uuid, text) from public, anon;
grant execute on function public.review_catalog_request(uuid, text) to authenticated;

-- Fix the existing insert policy: the qualified comparison prevents a member
-- of one property from inserting locations into a different property.
drop policy if exists location_insert on public.locations;
create policy location_insert on public.locations
  for insert to authenticated
  with check (
    (select public.is_current_user_admin())
    or exists (
      select 1 from public.property_memberships m
      where m.user_id = (select auth.uid())
        and m.property_id = locations.property_id
    )
  );

