begin;

create table public.user_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9][a-z0-9._-]{2,31}$'),
  display_name text not null,
  role text not null default 'petugas' check (role in ('admin', 'petugas')),
  created_at timestamptz not null default now()
);

create or replace function public.create_user_profile_from_auth()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  username_value text;
  display_value text;
begin
  username_value := lower(coalesce(
    nullif(new.raw_user_meta_data ->> 'username', ''),
    split_part(coalesce(new.email, ''), '@', 1)
  ));
  display_value := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
    initcap(replace(username_value, '.', ' '))
  );

  insert into public.user_profiles (id, username, display_name, role)
  values (new.id, username_value, display_value, 'petugas');
  return new;
end;
$$;

create trigger on_auth_user_created_profile
  after insert on auth.users
  for each row execute function public.create_user_profile_from_auth();

create or replace function public.is_current_user_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_profiles p
    where p.id = (select auth.uid())
      and p.role = 'admin'
  );
$$;

alter table public.user_profiles enable row level security;
revoke all on table public.user_profiles from anon, authenticated;
grant select on public.user_profiles to authenticated;
revoke all on function public.is_current_user_admin() from public, anon;
grant execute on function public.is_current_user_admin() to authenticated;

create policy user_profiles_read_self_or_admin
  on public.user_profiles for select to authenticated
  using (id = (select auth.uid()) or (select public.is_current_user_admin()));

create policy memberships_admin_read
  on public.property_memberships for select to authenticated
  using ((select public.is_current_user_admin()));

commit;