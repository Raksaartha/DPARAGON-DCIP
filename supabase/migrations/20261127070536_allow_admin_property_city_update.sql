create policy properties_admin_update_city on public.properties for update to authenticated using ((select public.is_current_user_admin())) with check ((select public.is_current_user_admin()));
revoke update on public.properties from authenticated, anon, public;
grant update(city) on public.properties to authenticated;
