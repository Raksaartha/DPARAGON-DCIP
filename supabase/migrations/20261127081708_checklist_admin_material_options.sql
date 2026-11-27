alter table public.material_options add column if not exists retired boolean not null default false;
grant insert on public.material_options to authenticated;
grant update (retired) on public.material_options to authenticated;
create policy checklist_admin_add_option on public.material_options for insert to authenticated
with check ((select public.is_current_user_admin()) and option_type = 'REGULER' and not retired);
create policy checklist_admin_retire_option on public.material_options for update to authenticated
using ((select public.is_current_user_admin()) and option_type = 'REGULER')
with check ((select public.is_current_user_admin()) and option_type = 'REGULER');
