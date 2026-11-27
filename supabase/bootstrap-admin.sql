-- Run once in Supabase SQL Editor after creating the first Auth user with:
--   email: dparagonadmin@accounts.dparagon.invalid
--   password: choose a strong password
-- The auth trigger creates a petugas profile automatically. This promotes it
-- and grants the first Admin access to existing properties.
do $$
declare
  admin_id uuid;
begin
  select id into admin_id from public.user_profiles where username = 'dparagonadmin';
  if admin_id is null then
    raise exception 'Create the first Auth user dparagonadmin before running this script.';
  end if;
  update public.user_profiles set role = 'admin' where id = admin_id;
  insert into public.property_memberships (user_id, property_id, role)
  select admin_id, id, 'admin' from public.properties
  on conflict (user_id, property_id) do update set role = 'admin';
end;
$$;
