-- ===========================================================================
-- tests/mixed_payment.sql — mixed-payment checks for the SQL side.
--
-- Run the whole file in the Supabase SQL Editor (no login needed: it only
-- calls the pure function public.order_amounts). Ends with
-- `raise notice 'ALL PASSED ...'`; any failure raises an exception instead.
-- Companion of tests.html section 5 (same M1–M9 numbers, same messages).
-- ===========================================================================

do $$
declare
  r      record;
  i      integer;
  v_seed bigint := 14050507;
  v_sub bigint; v_base bigint; v_hp bigint; v_disc bigint; v_md bigint;
  v_bearer text; v_ship bigint; v_method text; v_mult numeric; v_s bigint; v_net bigint;
begin
  -- ------------------------------------------------------------- M1 .. M9 --
  -- M1: courier, no discount
  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 325000, 1.15, 5000);
  if r.o_net <> 650000 or r.o_total <> 700000 or r.o_payout <> 650000 then raise exception 'M1 totals'; end if;
  if r.o_owe <> 500000 or r.o_h_share <> 150000 then raise exception 'M1 shares'; end if;
  if r.o_snapp_part <> 325000 or r.o_snapp_charge <> 375000 then raise exception 'M1 snapp'; end if;
  if r.o_cash_charge <> 325000 or r.o_snapp_deposit <> 325000 then raise exception 'M1 cash/deposit'; end if;

  -- M2: post, no discount
  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 190000, 'mixed', 325000, 1.15, 5000);
  if r.o_total <> 890000 or r.o_payout <> 840000 or r.o_owe <> 690000 then raise exception 'M2'; end if;
  if r.o_cash_charge <> 515000 or r.o_snapp_charge <> 375000 then raise exception 'M2 parts'; end if;

  -- M3: post, discount 50000 split
  select * into r from public.order_amounts(650000, 500000, 150000, 50000, 'split', 190000, 'mixed', 300000, 1.15, 5000);
  if r.o_net <> 600000 or r.o_mahdi_disc <> 25000 or r.o_helia_disc <> 25000 then raise exception 'M3 split'; end if;
  if r.o_total <> 835000 or r.o_payout <> 790000 or r.o_owe <> 665000 or r.o_h_share <> 125000 then raise exception 'M3 money'; end if;
  if r.o_snapp_charge <> 345000 or r.o_cash_charge <> 490000 or r.o_snapp_deposit <> 300000 then raise exception 'M3 parts'; end if;

  -- M4: rounding boundary 350000 x 1.15 -> 405000 (half up, not banker's)
  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 350000, 1.15, 5000);
  if r.o_snapp_charge <> 405000 or r.o_cash_charge <> 300000 or r.o_total <> 705000 then raise exception 'M4'; end if;

  -- M5: multiplier override 1.2, post
  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 190000, 'mixed', 325000, 1.2, 5000);
  if r.o_snapp_charge <> 390000 or r.o_total <> 905000 then raise exception 'M5'; end if;

  -- M6: odd discount 50001 split, post
  select * into r from public.order_amounts(650000, 500000, 150000, 50001, 'split', 190000, 'mixed', 325000, 1.15, 5000);
  if r.o_net <> 599999 or r.o_mahdi_disc <> 25000 or r.o_helia_disc <> 25001 then raise exception 'M6 split'; end if;
  if r.o_total <> 839999 or r.o_payout <> 789999 or r.o_owe <> 665000 or r.o_h_share <> 124999 then raise exception 'M6 money'; end if;

  -- M9: unit 350000, post, S 100000
  select * into r from public.order_amounts(350000, 200000, 150000, 0, 'helia', 190000, 'mixed', 100000, 1.15, 5000);
  if r.o_total <> 555000 or r.o_payout <> 540000 or r.o_owe <> 390000 or r.o_h_share <> 150000 then raise exception 'M9'; end if;
  if r.o_snapp_charge <> 115000 or r.o_cash_charge <> 440000 or r.o_snapp_deposit <> 100000 then raise exception 'M9 parts'; end if;

  -- M7: warning case, charge below deposit (NOT an error)
  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 6000, 1.15, 5000);
  if r.o_snapp_charge <> 5000 or r.o_total <> 649000 then raise exception 'M7'; end if;
  if not (r.o_snapp_charge < r.o_snapp_deposit) then raise exception 'M7 below-deposit'; end if;

  -- ---------------------------------------------------------- error cases --
  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 2000, 1.15, 5000);
    raise exception 'M8 should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی خیلی کم است؛ بعد از گرد کردن صفر می‌شود' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 0, 1.15, 5000);
    raise exception 'S=0 should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی باید عدد صحیح و حداقل ۱ باشد' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', null, 1.15, 5000);
    raise exception 'S=null should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی باید عدد صحیح و حداقل ۱ باشد' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 650000, 1.15, 5000);
    raise exception 'S=net should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی باید کمتر از مبلغ کالاها پس از تخفیف باشد؛ برای پرداخت کامل از روش اسنپ‌پی یا نقدی استفاده کنید' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 650001, 1.15, 5000);
    raise exception 'S>net should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی باید کمتر از مبلغ کالاها پس از تخفیف باشد؛ برای پرداخت کامل از روش اسنپ‌پی یا نقدی استفاده کنید' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', -5, 1.15, 5000);
    raise exception 'S<0 should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی باید عدد صحیح و حداقل ۱ باشد' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'cash', 100, 1.15, 5000);
    raise exception 'cash+part should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی فقط برای پرداخت ترکیبی است' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'snapp', 100, 1.15, 5000);
    raise exception 'snapp+part should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی فقط برای پرداخت ترکیبی است' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 100000, 'helia', 190000, 'mixed', 600000, 1.15, 5000);
    raise exception 'S>net-after-discount should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی باید کمتر از مبلغ کالاها پس از تخفیف باشد؛ برای پرداخت کامل از روش اسنپ‌پی یا نقدی استفاده کنید' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 325000, 0, 5000);
    raise exception 'mult=0 should have raised';
  exception when raise_exception then
    if SQLERRM <> 'ضریب اسنپ‌پی نامعتبر است' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 325000, 11, 5000);
    raise exception 'mult=11 should have raised';
  exception when raise_exception then
    if SQLERRM <> 'ضریب اسنپ‌پی نامعتبر است' then raise; end if;
  end;

  begin
    perform public.order_amounts(500000, 100000, 400000, 150000, 'mahdi', 190000, 'cash', null, 1.15, 5000);
    raise exception 'mahdi-overdiscount should have raised';
  exception when raise_exception then
    if SQLERRM <> 'تخفیف بر عهده مغازه از مبلغ کالاهای مغازه بیشتر است' then raise; end if;
  end;

  -- --------------------------------------------- the 13 old examples (v2) --
  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 190000, 'cash', null, 1.15, 5000);
  if r.o_total <> 840000 or r.o_owe <> 690000 or r.o_h_share <> 150000 then raise exception 'old1'; end if;
  if r.o_cash_charge <> 840000 or r.o_snapp_deposit <> 0 then raise exception 'old1 parts'; end if;

  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'cash', null, 1.15, 5000);
  if r.o_total <> 650000 or r.o_owe <> 500000 then raise exception 'old2'; end if;

  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 190000, 'snapp', null, 1.15, 5000);
  if r.o_total <> 940000 or r.o_payout <> 840000 then raise exception 'old3'; end if;
  if r.o_snapp_charge <> 940000 or r.o_cash_charge <> 0 or r.o_snapp_deposit <> 840000 then raise exception 'old3 parts'; end if;

  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'snapp', null, 1.15, 5000);
  if r.o_total <> 750000 or r.o_payout <> 650000 or r.o_owe <> 500000 then raise exception 'old4'; end if;

  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 190000, 'snapp', null, 1.2, 5000);
  if r.o_total <> 970000 or r.o_payout <> 840000 then raise exception 'old5'; end if;

  select * into r from public.order_amounts(650000, 500000, 150000, 50000, 'helia', 190000, 'cash', null, 1.15, 5000);
  if r.o_total <> 790000 or r.o_owe <> 690000 or r.o_h_share <> 100000 then raise exception 'old6'; end if;

  select * into r from public.order_amounts(650000, 500000, 150000, 50000, 'mahdi', 190000, 'cash', null, 1.15, 5000);
  if r.o_total <> 790000 or r.o_owe <> 640000 or r.o_h_share <> 150000 then raise exception 'old7'; end if;

  select * into r from public.order_amounts(650000, 500000, 150000, 50000, 'split', 190000, 'cash', null, 1.15, 5000);
  if r.o_total <> 790000 or r.o_owe <> 665000 or r.o_h_share <> 125000 then raise exception 'old8'; end if;
  if r.o_mahdi_disc <> 25000 or r.o_helia_disc <> 25000 then raise exception 'old8 split'; end if;

  select * into r from public.order_amounts(650000, 500000, 150000, 50001, 'split', 190000, 'cash', null, 1.15, 5000);
  if r.o_mahdi_disc <> 25000 or r.o_helia_disc <> 25001 then raise exception 'old9 split'; end if;
  if r.o_owe <> 665000 or r.o_h_share <> 124999 then raise exception 'old9'; end if;

  select * into r from public.order_amounts(650000, 500000, 150000, 50000, 'helia', 190000, 'snapp', null, 1.15, 5000);
  if r.o_total <> 880000 or r.o_payout <> 790000 or r.o_owe <> 690000 or r.o_h_share <> 100000 then raise exception 'old10'; end if;

  select * into r from public.order_amounts(350000, 200000, 150000, 0, 'helia', 190000, 'snapp', null, 1.15, 5000);
  if r.o_total <> 595000 or r.o_payout <> 540000 or r.o_owe <> 390000 or r.o_h_share <> 150000 then raise exception 'old11'; end if;

  select * into r from public.order_amounts(50000, 30000, 20000, 0, 'helia', 0, 'snapp', null, 1.15, 5000);
  if r.o_total <> 60000 or r.o_payout <> 50000 or r.o_owe <> 30000 or r.o_h_share <> 20000 then raise exception 'old11b'; end if;

  -- --------------------------------------- generated invariant sweep (500) --
  for i in 1..500 loop
    v_seed := (v_seed * 1103515245 + 12345) % 2147483648;
    -- the triple stays consistent like real orders: sub is exactly base+hp
    v_base := (v_seed / 7 % 500000);
    v_hp   := (v_seed / 13 % 400000);
    v_sub  := v_base + v_hp;
    if v_sub = 0 then continue; end if;
    v_disc := (v_seed / 29) % (v_sub + 1);
    case (v_seed / 31) % 3
      when 0 then v_bearer := 'helia';
      when 1 then v_bearer := 'mahdi';
      else v_bearer := 'split';
    end case;
    v_md := case when v_bearer = 'mahdi' then v_disc when v_bearer = 'split' then v_disc / 2 else 0 end;
    if v_base - v_md < 0 then continue; end if;   -- correct rejection, skip
    v_ship := case when (v_seed / 37) % 2 = 0 then 190000 else 0 end;
    case (v_seed / 41) % 3
      when 0 then v_method := 'cash';
      when 1 then v_method := 'snapp';
      else v_method := 'mixed';
    end case;
    case (v_seed / 43) % 6
      when 0 then v_mult := 1.05;
      when 1 then v_mult := 1.1;
      when 2 then v_mult := 1.125;
      when 3 then v_mult := 1.15;
      when 4 then v_mult := 1.2;
      else v_mult := 1.25;
    end case;
    v_s := null;
    v_net := v_sub - v_disc;
    if v_method = 'mixed' then
      if v_net < 2 then continue; end if;
      v_s := 1 + ((v_seed / 47) % (v_net - 1));
    end if;
    begin
      select * into r from public.order_amounts(
        v_sub, v_base, v_hp, v_disc, v_bearer, v_ship, v_method, v_s, v_mult, 5000);
    exception when raise_exception then
      if SQLERRM = 'مبلغ اسنپ‌پی خیلی کم است؛ بعد از گرد کردن صفر می‌شود' then continue; end if;
      raise exception 'sweep % failed: %', i, SQLERRM;
    end;
    if (r.o_owe + r.o_h_share) <> r.o_payout then raise exception 'sweep % shares', i; end if;
    if (r.o_snapp_charge + r.o_cash_charge) <> r.o_total then raise exception 'sweep % parts', i; end if;
    if (r.o_snapp_deposit + r.o_cash_charge) <> r.o_payout then raise exception 'sweep % deposit', i; end if;
  end loop;

  raise notice 'ALL PASSED (mixed_payment.sql): M1-M9, errors, old13, 500-combo sweep';
end;
$$;
