-- ===========================================================================
-- tests/admin_edit_delete.sql — admin edit/delete/restore checks (part B).
--
-- Run the whole file in the Supabase SQL Editor. It creates throw-away
-- profiles/products/orders, impersonates each role with
-- `set local role authenticated` + `request.jwt.claims`, and rolls
-- everything back at the end. Ends with `raise notice 'ALL PASSED ...'`;
-- any failure raises an exception instead. If it cannot run here, the
-- feature is UNVERIFIED (see README).
-- ===========================================================================

begin;

do $$
declare
  v_admin uuid := gen_random_uuid();
  v_page  uuid := gen_random_uuid();
  v_store uuid := gen_random_uuid();
  v_p1 uuid; v_p2 uuid;
  v_o1 uuid; v_o2 uuid; v_o3 uuid;
  v_aid bigint; v_restored uuid;
  r record; v_n integer; v_changed jsonb;
  v_claims text;
begin
  -- throw-away profiles (rolled back at the end)
  insert into public.profiles (user_id, role) values
    (v_admin, 'admin'), (v_page, 'helia'), (v_store, 'mahdi');

  insert into public.products (name, base_price, hp, available, archived)
  values ('AdminTest A', 500000, 150000, true, false) returning id into v_p1;
  insert into public.products (name, base_price, hp, available, archived)
  values ('AdminTest B', 200000, 150000, true, false) returning id into v_p2;

  -- ------------------------------------------------ (1) non-admins blocked --
  -- helper: run each new RPC as page and as store, expect «دسترسی غیرمجاز»
  for v_claims in
    select unnest(array[
      '{"sub":"' || v_page || '"}',
      '{"sub":"' || v_store || '"}'])
  loop
    execute 'set local role authenticated';
    execute 'set local request.jwt.claims = ''' || v_claims || '''';
    begin perform public.admin_update_order(gen_random_uuid(), '{}'::jsonb);
      raise exception 'admin_update_order should have raised for %', v_claims;
    exception when raise_exception then
      if SQLERRM <> 'دسترسی غیرمجاز' then raise; end if;
    end;
    begin perform public.admin_delete_order(gen_random_uuid());
      raise exception 'admin_delete_order should have raised';
    exception when raise_exception then
      if SQLERRM <> 'دسترسی غیرمجاز' then raise; end if;
    end;
    begin perform public.admin_update_product(gen_random_uuid(), '{"name":"x"}');
      raise exception 'admin_update_product should have raised';
    exception when raise_exception then
      if SQLERRM <> 'دسترسی غیرمجاز' then raise; end if;
    end;
    begin perform public.admin_delete_product(gen_random_uuid());
      raise exception 'admin_delete_product should have raised';
    exception when raise_exception then
      if SQLERRM <> 'دسترسی غیرمجاز' then raise; end if;
    end;
    begin perform public.admin_restore_order(1);
      raise exception 'admin_restore_order should have raised';
    exception when raise_exception then
      if SQLERRM <> 'دسترسی غیرمجاز' then raise; end if;
    end;
    begin perform public.admin_restore_product(1);
      raise exception 'admin_restore_product should have raised';
    exception when raise_exception then
      if SQLERRM <> 'دسترسی غیرمجاز' then raise; end if;
    end;
    begin perform public.admin_list_audit(10);
      raise exception 'admin_list_audit should have raised';
    exception when raise_exception then
      if SQLERRM <> 'دسترسی غیرمجاز' then raise; end if;
    end;
  end loop;

  -- ------------------------------------------------- make orders (as page) --
  execute 'set local request.jwt.claims = ''{"sub":"' || v_page || '"}''';
  -- cash courier order, status paid
  v_o1 := public.create_order(
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'qty', 1)),
    'Admin Customer', '09121234567', 'Tehran', '1234567890',
    'courier', 'cash', 0, 'helia', null, null, 'paid', null);
  -- move to delivered through the normal flow
  perform public.set_order_status(v_o1, 'settled');
  perform public.set_order_status(v_o1, 'shipped', 'TRK-1');
  perform public.set_order_status(v_o1, 'delivered');
  -- mixed post order (stays awaiting_snapp)
  v_o2 := public.create_order(
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'qty', 1)),
    'Mixed Customer', '09121234567', 'Tehran', '1234567890',
    'post', 'mixed', 0, 'helia', 1.15, null, null, 325000);

  -- --------------------------------- (2) admin edits a delivered order ----
  execute 'set local request.jwt.claims = ''{"sub":"' || v_admin || '"}''';
  -- case 1: replace items with 1x product B (base 200000 + hp 150000),
  -- courier cash: net 350000, payout 350000, owe 200000, h_share 150000
  perform public.admin_update_order(v_o1, jsonb_build_object('items',
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'name', 'AdminTest B',
                                         'qty', 1, 'base', 200000, 'hp', 150000))));
  select * into r from public.orders where id = v_o1;
  if r.total <> 350000 or r.payout <> 350000 then raise exception 'edit1 totals %/%', r.total, r.payout; end if;
  if r.owe <> 200000 or r.h_share <> 150000 then raise exception 'edit1 shares'; end if;
  if r.snapp_charge + r.cash_charge <> r.total then raise exception 'edit1 inv1'; end if;
  if r.snapp_deposit + r.cash_charge <> r.payout then raise exception 'edit1 inv2'; end if;
  if r.owe + r.h_share <> r.payout then raise exception 'edit1 inv3'; end if;
  if r.status <> 'delivered' then raise exception 'edit1 keeps status'; end if;
  -- case 2: same order, discount 50000 split + post shipping with fee override
  perform public.admin_update_order(v_o1, jsonb_build_object(
    'discount', 50000, 'discount_bearer', 'split',
    'shipping_method', 'post', 'shipping_fee', 190000));
  select * into r from public.orders where id = v_o1;
  -- sub 350000 - 50000 = net 300000, payout 490000, owe 365000, h_share 125000
  if r.total <> 490000 or r.payout <> 490000 then raise exception 'edit2 totals %/%', r.total, r.payout; end if;
  if r.owe <> 365000 or r.h_share <> 125000 then raise exception 'edit2 shares %/%', r.owe, r.h_share; end if;
  if r.mahdi_discount <> 25000 or r.helia_discount <> 25001 then raise exception 'edit2 split'; end if;
  if r.snapp_charge + r.cash_charge <> r.total then raise exception 'edit2 inv1'; end if;
  if r.snapp_deposit + r.cash_charge <> r.payout then raise exception 'edit2 inv2'; end if;
  if r.owe + r.h_share <> r.payout then raise exception 'edit2 inv3'; end if;

  -- --------------------------------------- (3) cash -> mixed (OWNER) ------
  -- rebuild a big order: items price override base 8M + hp 2M, courier
  perform public.admin_update_order(v_o1, jsonb_build_object(
    'items', jsonb_build_array(jsonb_build_object('product_id', v_p1, 'name', 'Big',
                                                  'qty', 1, 'base', 8000000, 'hp', 2000000)),
    'method', 'mixed', 'snapp_part', 5000000,
    'shipping_method', 'courier', 'discount', 0, 'discount_bearer', 'helia'));
  select * into r from public.orders where id = v_o1;
  if r.snapp_charge <> 5000000 then raise exception 'owner charge %', r.snapp_charge; end if;
  if r.snapp_fee <> 750000 or r.cash_charge <> 5750000 then raise exception 'owner cash/fee'; end if;
  if r.total <> 10750000 or r.payout <> 10000000 then raise exception 'owner totals'; end if;
  if r.snapp_deposit <> 4250000 or r.owe <> 8000000 or r.h_share <> 2000000 then raise exception 'owner shares'; end if;
  if r.total <> r.payout + r.snapp_fee then raise exception 'owner inv4'; end if;

  -- ------------------------------------------------ (4) unknown key --------
  begin
    perform public.admin_update_order(v_o1, '{"nope":1}');
    raise exception 'unknown key should have raised';
  exception when raise_exception then
    if SQLERRM <> 'فیلد نامعتبر' then raise; end if;
  end;
  begin
    perform public.admin_update_product(v_p1, '{"nope":1}');
    raise exception 'unknown product key should have raised';
  exception when raise_exception then
    if SQLERRM <> 'فیلد نامعتبر' then raise; end if;
  end;

  -- --------------------------------- (5) delete: audit + outbox + gone ----
  -- v_o2 (mixed) has a pending order_created outbox row from its INSERT
  select count(*) into v_n from public.outbox
   where order_id = v_o2 and processed_at is null and kind = 'order_created';
  if v_n < 1 then raise exception 'expected a pending order_created row'; end if;
  perform public.admin_delete_order(v_o2);
  if exists (select 1 from public.orders where id = v_o2) then
    raise exception 'order should be gone';
  end if;
  select count(*) into v_n from public.audit_log
   where entity = 'order' and entity_id = v_o2 and action = 'delete';
  if v_n <> 1 then raise exception 'expected one delete audit row'; end if;
  select payload into v_changed from public.outbox
   where order_id = v_o2 and kind = 'order_deleted'
   order by id desc limit 1;
  if v_changed is null or v_changed->>'customer' <> 'Mixed Customer' then
    raise exception 'order_deleted payload wrong';
  end if;
  select count(*) into v_n from public.outbox
   where order_id = v_o2 and processed_at is null and kind <> 'order_deleted';
  if v_n <> 0 then raise exception 'old pending rows must be processed'; end if;

  -- --------------------------------------- (6) restore + double restore ---
  select id into v_aid from public.audit_log
   where entity = 'order' and entity_id = v_o2 and action = 'delete'
   order by id desc limit 1;
  v_restored := public.admin_restore_order(v_aid);
  if v_restored <> v_o2 then raise exception 'restore must keep the id'; end if;
  select * into r from public.orders where id = v_o2;
  if r.customer <> 'Mixed Customer' or r.total is null then raise exception 'restored row wrong'; end if;
  if r.tg_channel_msg_id is not null then raise exception 'restored tg id must be null'; end if;
  begin
    perform public.admin_restore_order(v_aid);
    raise exception 'second restore should have raised';
  exception when raise_exception then
    if SQLERRM <> 'این مورد قبلاً بازگردانده شده یا وجود دارد' then raise; end if;
  end;

  -- ------------------------------ (7) product delete keeps snapshots ------
  -- v_p1 is referenced by v_o1 (Big line keeps product_id v_p1? no — case OWNER
  -- used product_id v_p1 with overridden prices; use v_o3 instead)
  v_o3 := public.create_order(
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'qty', 2)),
    'ProdRef', '09121234567', 'Tehran', '1234567890',
    'courier', 'cash', 0, 'helia', null, null, 'new', null);
  select public.admin_delete_product(v_p2) into v_changed;
  if (v_changed->>'deleted')::boolean is not true then raise exception 'delete flag'; end if;
  if (v_changed->>'referenced_by_orders')::integer < 1 then raise exception 'ref count %', v_changed; end if;
  if exists (select 1 from public.products where id = v_p2) then
    raise exception 'product should be gone';
  end if;
  select items into v_changed from public.orders where id = v_o3;
  if v_changed is null or v_changed->0->>'name' is null then
    raise exception 'old order snapshot must stay readable';
  end if;

  -- admin list works
  select count(*) into v_n from public.admin_list_audit(10);
  if v_n < 1 then raise exception 'audit list empty'; end if;

  raise notice 'ALL PASSED (admin_edit_delete.sql): auth, edit x2, cash->mixed, bad key, delete, restore, product';
end;
$$;

rollback;
