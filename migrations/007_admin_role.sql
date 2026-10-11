-- ===========================================================================
-- 007_admin_role.sql
--
-- The human behind the store login becomes the Admin (full access, keeps
-- email + password — auth is untouched). The `mahdi` (store) role stays as
-- an empty slot: no credentials are created now, add them later.
--
--   * `profiles.role` allows 'admin' (displayed as «ادمین» in the app).
--   * `is_mahdi()` covers the admin too (shop powers everywhere the store
--     has them); new `is_admin()` gates admin-only controls.
--   * `settings_update` split: price keys stay member-editable, but the
--     `telegram_paused` test-mode switch requires `is_admin()`.
--   * Product-event notifications reach every linked partner (admin, page,
--     store) — implemented in the `notify` Edge Function, no SQL needed.
--
-- Every statement is idempotent and safe to run twice. Mirrored in setup.sql.
-- After running, promote the store login (one line, real email required):
--
--   update public.profiles set role = 'admin'
--    where user_id = (select id from auth.users where email = '<store email>');
--
-- The store slot stays empty until you create its Dashboard user and run:
--
--   insert into public.profiles (user_id, role)
--   values ('<new store user uuid>', 'mahdi');
-- ===========================================================================

-- 1) widen the role check (auto-named profiles_role_check on old installs)
do $$
begin
  if exists (select 1 from pg_constraint where conname = 'profiles_role_check') then
    alter table public.profiles drop constraint profiles_role_check;
  end if;
  alter table public.profiles
    add constraint profiles_role_check check (role in ('mahdi', 'helia', 'admin'));
exception when others then
  raise warning 'profiles role check not widened: %', sqlerrm;
end $$;

-- 2) admin inherits every shop power; admin-only checks use is_admin()
create or replace function public.is_mahdi()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
     where user_id = auth.uid() and role in ('mahdi', 'admin')
  );
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles where user_id = auth.uid() and role = 'admin'
  );
$$;

-- 3) the admin reads every profile, like the store could
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (user_id = auth.uid() or public.is_mahdi() or public.is_admin());

-- 4) settings: prices stay member-editable, the test-mode switch is admin-only
drop policy if exists settings_update on public.settings;
create policy settings_update on public.settings
  for update to authenticated
  using (public.is_member())
  with check (public.is_member() and (
    (key = 'snapp_multiplier' and value ~ '^[0-9]+(\.[0-9]+)?$') or
    (key in ('post_fee', 'rounding_step') and value ~ '^[0-9]+$') or
    (key = 'telegram_paused' and value in ('0', '1') and public.is_admin())));

-- 5) grants for the new helper (the widened is_mahdi needs no re-grant)
do $$
declare
  f record;
begin
  for f in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('is_admin')
  loop
    execute format('revoke all on function public.%I(%s) from PUBLIC', f.proname, f.args);
    execute format('revoke all on function public.%I(%s) from anon', f.proname, f.args);
    execute format('revoke all on function public.%I(%s) from authenticated', f.proname, f.args);
    execute format('grant execute on function public.%I(%s) to authenticated', f.proname, f.args);
    execute format('grant execute on function public.%I(%s) to service_role', f.proname, f.args);
  end loop;
end $$;

-- make PostgREST pick everything up immediately (harmless if repeated)
notify pgrst, 'reload schema';
