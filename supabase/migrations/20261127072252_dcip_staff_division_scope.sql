alter table public.user_profiles add column if not exists division_id text references public.divisions(id);
create function public.can_access_dcip_division(target text) returns boolean language sql stable security invoker set search_path='' as $$
select exists(select 1 from public.user_profiles p where p.id=(select auth.uid()) and (p.role='admin' or p.division_id is null or p.division_id=target));
$$;
revoke all on function public.can_access_dcip_division(text) from public, anon;
grant execute on function public.can_access_dcip_division(text) to authenticated;
create policy inspection_division_scope on public.inspections as restrictive for all to authenticated using (public.can_access_dcip_division(division_id)) with check (public.can_access_dcip_division(division_id));
create policy answer_division_scope on public.inspection_answers as restrictive for all to authenticated using (public.can_access_dcip_division(division_id)) with check (public.can_access_dcip_division(division_id));
create policy request_division_scope on public.catalog_requests as restrictive for all to authenticated using (public.can_access_dcip_division(division_id)) with check (public.can_access_dcip_division(division_id));
