-- reset.sql — wipe all business data, keep auth users.
-- Users (Authentication → Users) and their profiles/roles are untouched.
-- Run in Supabase dashboard → SQL Editor → Run.
--
-- Assumes the v2 schema: run migrations 001, 002 (and 003) first.
-- `order_private` and `product_costs` were dropped in 002.

truncate public.orders, public.products, public.settings
  restart identity cascade;

insert into public.settings (key, value) values
  ('post_fee', '190000'),
  ('snapp_multiplier', '1.15'),
  ('rounding_step', '5000')
on conflict (key) do nothing;
