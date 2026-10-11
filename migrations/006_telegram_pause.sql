-- ===========================================================================
-- 006_telegram_pause.sql
--
-- Test mode ("حالت تست"): one shared switch that silences the automatic
-- notifications while a partner tries features, so the other partner is not
-- spammed with test orders.
--
--   * New `public.settings` key `telegram_paused` ('0' = live, '1' = testing).
--   * `settings_update` RLS policy extended to allow exactly '0' / '1'.
--   * The `notify` Edge Function reads this key once per invocation: while it
--     is '1', every claimed outbox group is marked processed WITHOUT sending
--     anything (partner DMs, channel posts/edits and partner pushes are all
--     dropped — nothing piles up for later). `test-notify` and `send-invoice`
--     are intentionally unaffected: both target only the caller's own chat /
--     devices, so a partner can still verify their own link mid-test.
--
-- Every statement is idempotent and safe to run twice. Mirrored in setup.sql.
-- ===========================================================================

insert into public.settings (key, value) values
  ('telegram_paused', '0')
on conflict (key) do nothing;

-- Older databases have no row yet: a missing key means "not paused", and the
-- Edge Function treats it the same as '0', so this migration is safe to apply
-- at any time. Repair a corrupted value instead of failing the migration.
update public.settings set value = '0'
 where key = 'telegram_paused' and value not in ('0', '1');

drop policy if exists settings_update on public.settings;
create policy settings_update on public.settings
  for update to authenticated
  using (public.is_member())
  with check (public.is_member() and (
    (key = 'snapp_multiplier' and value ~ '^[0-9]+(\.[0-9]+)?$') or
    (key in ('post_fee', 'rounding_step') and value ~ '^[0-9]+$') or
    (key = 'telegram_paused' and value in ('0', '1'))));

-- make PostgREST pick the policy up immediately (harmless if repeated)
notify pgrst, 'reload schema';
