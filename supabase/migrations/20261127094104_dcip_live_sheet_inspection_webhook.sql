create extension if not exists pg_net;
create function public.configure_dcip_live_sync(p_url text,p_secret text) returns void
language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
  if p_url is null or p_url !~ '^https://script[.]google[.]com/(macros|a/macros/[a-zA-Z0-9.-]+)/s/[a-zA-Z0-9_-]+/exec$'
     or p_secret is null or length(p_secret) not between 48 and 128 then
    raise exception 'Konfigurasi webhook tidak valid';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(78119362);
  select id into v_id from vault.secrets where name='dcip_sheets_live_config';
  if v_id is null then
    perform vault.create_secret(jsonb_build_object('url',p_url,'secret',p_secret)::text,'dcip_sheets_live_config');
  else
    perform vault.update_secret(v_id,jsonb_build_object('url',p_url,'secret',p_secret)::text);
  end if;
end;
$$;
revoke all on function public.configure_dcip_live_sync(text,text) from public, anon, authenticated;
grant execute on function public.configure_dcip_live_sync(text,text) to service_role;
create schema if not exists dcip_private;
revoke all on schema dcip_private from public;
create function dcip_private.notify_inspection_sheet() returns trigger
language plpgsql security definer set search_path='' as $$
declare c jsonb; v_id uuid; v_division text;
begin
  select decrypted_secret::jsonb into c from vault.decrypted_secrets where name='dcip_sheets_live_config';
  if c is null then return null; end if;
  if tg_op='DELETE' then v_id:=old.id; v_division:=old.division_id;
  else v_id:=new.id; v_division:=new.division_id; end if;
  perform net.http_post(url:=c->>'url',body:=jsonb_build_object('id',v_id,'division',v_division,'secret',c->>'secret'),timeout_milliseconds:=15000);
  return null;
exception when others then
  raise warning 'DCIP Sheets delivery could not be queued; scheduled sync remains available';
  return null;
end;
$$;
revoke all on function dcip_private.notify_inspection_sheet() from public;
create trigger dcip_notify_inspection_sheet after insert or update or delete on public.inspections
for each row execute function dcip_private.notify_inspection_sheet();
