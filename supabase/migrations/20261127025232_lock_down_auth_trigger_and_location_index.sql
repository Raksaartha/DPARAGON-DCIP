revoke all on function public.create_user_profile_from_auth() from public, anon, authenticated;
create index if not exists inspections_location_id_idx on public.inspections(location_id);
