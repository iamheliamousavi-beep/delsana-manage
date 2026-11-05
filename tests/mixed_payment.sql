-- ===========================================================================
-- tests/mixed_payment.sql — mixed-payment checks for the SQL side.
--
-- Two mixed models live side by side (migration 012), selected by p_cash_part:
--   p_cash_part not null -> v5: the fee is collected INSIDE the Snapp part P;
--     cash part C covers goods only:
--       remainingGoods = net - C
--       expectedSnap   = round_to_step(remainingGoods * multiplier, 1000)
--       validation:    |P - expectedSnap| <= 5000 (rounding tolerance)
--   p_cash_part null     -> legacy: S is the customer's exact Snapp charge
--     and fee = max(0, round(S)-S) is paid in cash (pre-012 rows).
-- Run the whole file in the Supabase SQL Editor (no login needed: it only
-- calls the pure function public.order_amounts). Ends with
-- `raise notice 'ALL PASSED ...'`; any failure raises an exception instead.
-- Companion of tests.html sections 5/5ب.
-- ===========================================================================

do $$
declare
  r      record;
  i      integer;
  v_seed bigint := 14050507;
  v_sub bigint; v_base bigint; v_hp bigint; v_disc bigint; v_md bigint;
  v_bearer text; v_ship bigint; v_method text; v_mult numeric;
  v_s bigint; v_c bigint; v_net bigint; v_expected bigint;
  v_ship_pay text;
begin
  -- ======================================================== v5 mixed model =
  -- the owner's failing scenario: 5,500,000 goods, 100,000 cash, the real
  -- Snapp checkout 6,100,000 (incl. the fee; expected 5,400,000 x 1.13)
  select * into r from public.order_amounts(
    5500000, 5500000, 0, 0, 'helia', 0, 'mixed', 6100000, 100000, 1.13, 5000);
  if r.o_net <> 5500000 or r.o_total <> 6200000 or r.o_payout <> 5500000 then raise exception 'V5A totals'; end if;
  if r.o_snapp_part <> 6100000 or r.o_snapp_charge <> 6100000 or r.o_cash_charge <> 100000 then raise exception 'V5A parts'; end if;
  if r.o_snapp_fee <> 700000 or r.o_snapp_deposit <> 5400000 then raise exception 'V5A fee/deposit'; end if;
  if r.o_owe <> 5500000 or r.o_h_share <> 0 then raise exception 'V5A shares'; end if;
  if r.o_snapp_fee_clamped then raise exception 'V5A clamped'; end if;

  -- fully via Snapp: cash 0, expected 5,500,000 x 1.13 = 6,215,000
  select * into r from public.order_amounts(
    5500000, 5500000, 0, 0, 'helia', 0, 'mixed', 6215000, 0, 1.13, 5000);
  if r.o_total <> 6215000 or r.o_snapp_charge <> 6215000 or r.o_cash_charge <> 0 then raise exception 'V5B parts'; end if;
  if r.o_snapp_fee <> 715000 or r.o_snapp_deposit <> 5500000 then raise exception 'V5B fee/deposit'; end if;

  -- 7,500,000 goods via Snapp 5,000,000; cash = 7,500,000 - round(5M/1.13) ≈ 3,075,000
  select * into r from public.order_amounts(
    7500000, 7500000, 0, 0, 'helia', 0, 'mixed', 5000000, 3075000, 1.13, 5000);
  if r.o_total <> 8075000 or r.o_snapp_fee <> 575000 then raise exception 'V5C totals'; end if;
  if r.o_snapp_deposit <> 4425000 or r.o_cash_charge <> 3075000 then raise exception 'V5C deposit'; end if;

  -- discount: net = sub - discount first; fee only on the post-discount remainder
  select * into r from public.order_amounts(
    5500000, 5500000, 0, 500000, 'helia', 0, 'mixed', 5085000, 500000, 1.13, 5000);
  if r.o_net <> 5000000 or r.o_total <> 5585000 or r.o_payout <> 5000000 then raise exception 'V5D totals'; end if;
  if r.o_snapp_fee <> 585000 or r.o_snapp_deposit <> 4500000 then raise exception 'V5D fee/deposit'; end if;

  -- post shipping routed to cash, never multiplied
  select * into r from public.order_amounts(
    5500000, 5500000, 0, 0, 'helia', 190000, 'mixed', 6100000, 100000, 1.13, 5000, 'cash');
  if r.o_total <> 6390000 or r.o_payout <> 5690000 then raise exception 'V5E totals'; end if;
  if r.o_snapp_charge <> 6100000 or r.o_cash_charge <> 290000 then raise exception 'V5E parts'; end if;
  if r.o_snapp_fee <> 700000 or r.o_snapp_deposit <> 5400000 then raise exception 'V5E fee/deposit'; end if;

  -- post shipping routed to Snapp: charge = P + shipSnap, deposit = goods + shipSnap
  select * into r from public.order_amounts(
    650000, 500000, 150000, 0, 'helia', 190000, 'mixed', 374000, 325000, 1.15, 5000, 'snapp');
  if r.o_total <> 889000 or r.o_payout <> 840000 then raise exception 'V5F totals'; end if;
  if r.o_snapp_charge <> 564000 or r.o_cash_charge <> 325000 then raise exception 'V5F parts'; end if;
  if r.o_snapp_fee <> 49000 or r.o_snapp_deposit <> 515000 then raise exception 'V5F fee/deposit'; end if;

  -- tolerance boundary: exactly 5000 of drift is accepted
  select * into r from public.order_amounts(
    5500000, 5500000, 0, 0, 'helia', 0, 'mixed', 6107000, 100000, 1.13, 5000);
  if r.o_snapp_charge <> 6107000 or r.o_snapp_fee <> 707000 then raise exception 'V5 boundary'; end if;

  -- -------------------------------------------------------- v5 error cases --
  begin
    perform public.order_amounts(5500000, 5500000, 0, 0, 'helia', 0, 'mixed', 6500000, 100000, 1.13, 5000);
    raise exception 'far-from-expected snap should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی واردشده 6500000 تومان با نقدی 100000 تومان هم‌خوانی ندارد؛ مبلغ مورد انتظار اسنپ‌پی 6102000 تومان است' then raise; end if;
  end;

  begin
    perform public.order_amounts(5500000, 5500000, 0, 0, 'helia', 0, 'mixed', 6108000, 100000, 1.13, 5000);
    raise exception 'over-tolerance snap should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی واردشده 6108000 تومان با نقدی 100000 تومان هم‌خوانی ندارد؛ مبلغ مورد انتظار اسنپ‌پی 6102000 تومان است' then raise; end if;
  end;

  begin
    perform public.order_amounts(5500000, 5500000, 0, 0, 'helia', 0, 'mixed', 6102000, 5500000, 1.13, 5000);
    raise exception 'cash = net should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ نقدی نباید از مبلغ کالاها پس از تخفیف بیشتر یا برابر باشد؛ برای پرداخت کامل از روش نقدی استفاده کنید' then raise; end if;
  end;

  begin
    perform public.order_amounts(5500000, 5500000, 0, 0, 'helia', 0, 'mixed', 6102000, -1, 1.13, 5000);
    raise exception 'negative cash should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ نقدی باید عدد صحیح و ۰ یا بیشتر باشد' then raise; end if;
  end;

  -- within tolerance but the fee would turn negative (small remainder)
  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 7000, 640000, 1.15, 5000);
    raise exception 'negative fee should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی واردشده 7000 تومان از باقی‌مانده کالاها (10000 تومان) بعد از نقدی کمتر است؛ نقدی و مبلغ اسنپ‌پی را با هم بررسی کنید' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', null, 325000, 1.15, 5000);
    raise exception 'v5 snap=null should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی باید عدد صحیح و حداقل ۱ باشد' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 374000, 325000, 0, 5000);
    raise exception 'v5 mult=0 should have raised';
  exception when raise_exception then
    if SQLERRM <> 'ضریب اسنپ‌پی نامعتبر است' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'cash', 0, 325000, 1.15, 5000);
    raise exception 'cash method with a cash part should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی فقط برای پرداخت ترکیبی است' then raise; end if;
  end;

  -- ======================================================= legacy mixed rows =
  -- legacy prices: S is the customer's exact Snapp charge; the fee is paid
  -- in cash (p_cash_part null). Old stored rows must keep these numbers.
  select * into r from public.order_amounts(10000000, 8000000, 2000000, 0, 'helia', 0, 'mixed', 5000000, null, 1.15, 5000);
  if r.o_snapp_fee <> 750000 or r.o_snapp_charge <> 5000000 then raise exception 'L OWNER fee/charge'; end if;
  if r.o_cash_charge <> 5750000 or r.o_total <> 10750000 or r.o_payout <> 10000000 then raise exception 'L OWNER totals'; end if;
  if r.o_snapp_deposit <> 4250000 or r.o_owe <> 8000000 or r.o_h_share <> 2000000 then raise exception 'L OWNER shares'; end if;
  if r.o_snapp_fee_clamped then raise exception 'L OWNER clamped'; end if;

  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 325000, null, 1.15, 5000);
  if r.o_total <> 700000 or r.o_snapp_fee <> 50000 or r.o_cash_charge <> 375000 or r.o_snapp_deposit <> 275000 then raise exception 'L M1'; end if;

  select * into r from public.order_amounts(650000, 500000, 150000, 50000, 'split', 190000, 'mixed', 300000, null, 1.15, 5000);
  if r.o_total <> 835000 or r.o_snapp_fee <> 45000 or r.o_cash_charge <> 535000 or r.o_snapp_deposit <> 255000 then raise exception 'L M3'; end if;

  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 190000, 'mixed', 325000, null, 1.15, 5000, 'snapp');
  if r.o_total <> 890000 or r.o_snapp_charge <> 515000 or r.o_cash_charge <> 375000 or r.o_snapp_deposit <> 465000 then raise exception 'L mixed+shipSnap'; end if;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 650000, null, 1.15, 5000);
    raise exception 'legacy S=net should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی باید کمتر از مبلغ کالاها پس از تخفیف باشد؛ برای پرداخت کامل از روش اسنپ‌پی یا نقدی استفاده کنید' then raise; end if;
  end;

  ---------------------------------------------------------- error cases ------
  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 0, null, 1.15, 5000);
    raise exception 'S=0 should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی باید عدد صحیح و حداقل ۱ باشد' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', null, null, 1.15, 5000);
    raise exception 'S=null should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی باید عدد صحیح و حداقل ۱ باشد' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', -5, null, 1.15, 5000);
    raise exception 'S<0 should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی باید عدد صحیح و حداقل ۱ باشد' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'cash', 100, null, 1.15, 5000);
    raise exception 'cash+part should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی فقط برای پرداخت ترکیبی است' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'snapp', 100, null, 1.15, 5000);
    raise exception 'snapp+part should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی فقط برای پرداخت ترکیبی است' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 100000, 'helia', 190000, 'mixed', 600000, null, 1.15, 5000);
    raise exception 'S>net-after-discount should have raised';
  exception when raise_exception then
    if SQLERRM <> 'مبلغ اسنپ‌پی باید کمتر از مبلغ کالاها پس از تخفیف باشد؛ برای پرداخت کامل از روش اسنپ‌پی یا نقدی استفاده کنید' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 325000, null, 0, 5000);
    raise exception 'mult=0 should have raised';
  exception when raise_exception then
    if SQLERRM <> 'ضریب اسنپ‌پی نامعتبر است' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'mixed', 325000, null, 11, 5000);
    raise exception 'mult=11 should have raised';
  exception when raise_exception then
    if SQLERRM <> 'ضریب اسنپ‌پی نامعتبر است' then raise; end if;
  end;

  begin
    perform public.order_amounts(500000, 100000, 400000, 150000, 'mahdi', 190000, 'cash', null, null, 1.15, 5000);
    raise exception 'mahdi-overdiscount should have raised';
  exception when raise_exception then
    if SQLERRM <> 'تخفیف بر عهده مغازه از مبلغ کالاهای مغازه بیشتر است' then raise; end if;
  end;

  begin
    perform public.order_amounts(650000, 500000, 150000, 700000, 'helia', 0, 'mixed', 100000, null, 1.15, 5000);
    raise exception 'discount>sub should have raised';
  exception when raise_exception then
    if SQLERRM <> 'تخفیف از مبلغ کالاها بیشتر است' then raise; end if;
  end;

  -- --------------------------------------------- the 13 old examples (v2) ----
  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 190000, 'cash', null, 1.15, 5000);
  if r.o_total <> 840000 or r.o_owe <> 690000 or r.o_h_share <> 150000 then raise exception 'old1'; end if;
  if r.o_cash_charge <> 840000 or r.o_snapp_charge <> 0 or r.o_snapp_fee <> 0 or r.o_snapp_deposit <> 0 then raise exception 'old1 parts'; end if;

  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 0, 'cash', null, 1.15, 5000);
  if r.o_total <> 650000 or r.o_owe <> 500000 then raise exception 'old2'; end if;

  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 190000, 'snapp', null, 1.15, 5000);
  if r.o_total <> 940000 or r.o_payout <> 840000 then raise exception 'old3'; end if;
  if r.o_snapp_charge <> 940000 or r.o_cash_charge <> 0 or r.o_snapp_deposit <> 840000 or r.o_snapp_fee <> 0 then raise exception 'old3 parts'; end if;

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

  -- ------------------------------------------ split goods/shipping payment ----
  -- goods Snapp + shipping cash: only the goods carry the multiplier
  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 190000, 'snapp', null, 1.15, 5000, 'cash');
  if r.o_total <> 940000 or r.o_payout <> 840000 then raise exception 'split1 total'; end if;
  if r.o_snapp_charge <> 750000 or r.o_cash_charge <> 190000 then raise exception 'split1 parts'; end if;
  if r.o_snapp_deposit <> 650000 or r.o_snapp_fee <> 0 then raise exception 'split1 deposit'; end if;

  -- all cash
  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 190000, 'cash', null, 1.15, 5000, 'cash');
  if r.o_total <> 840000 or r.o_snapp_charge <> 0 or r.o_cash_charge <> 840000 or r.o_snapp_deposit <> 0 then raise exception 'split2'; end if;

  -- all Snapp
  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 190000, 'snapp', null, 1.15, 5000, 'snapp');
  if r.o_total <> 940000 or r.o_snapp_charge <> 940000 or r.o_cash_charge <> 0 or r.o_snapp_deposit <> 840000 then raise exception 'split3'; end if;

  -- cash goods + shipping Snapp: shipping is added as-is, never multiplied
  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 190000, 'cash', null, 1.15, 5000, 'snapp');
  if r.o_total <> 840000 or r.o_snapp_charge <> 190000 or r.o_cash_charge <> 650000 then raise exception 'split4 parts'; end if;
  if r.o_snapp_deposit <> 190000 then raise exception 'split4 deposit'; end if;

  -- calls without the trailing argument keep the old fallback (shipping follows goods)
  select * into r from public.order_amounts(650000, 500000, 150000, 0, 'helia', 190000, 'snapp', null, 1.15, 5000);
  if r.o_snapp_charge <> 940000 or r.o_cash_charge <> 0 then raise exception 'split old fallback'; end if;

  begin
    perform public.order_amounts(650000, 500000, 150000, 0, 'helia', 190000, 'cash', null, 1.15, 5000, 'card');
    raise exception 'invalid shipping method should have raised';
  exception when raise_exception then
    if SQLERRM <> 'روش پرداخت هزینه ارسال نامعتبر است' then raise; end if;
  end;

  -- --------------------------------------- generated invariant sweep (500) ----
  for i in 1..500 loop
    v_seed := (v_seed * 1103515245 + 12345) % 2147483648;
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
    if v_base - v_md < 0 then continue; end if;
    v_ship := case when (v_seed / 37) % 2 = 0 then 190000 else 0 end;
    v_ship_pay := case when (v_seed / 53) % 2 = 0 then 'cash' else 'snapp' end;
    case (v_seed / 41) % 3
      when 0 then v_method := 'cash';
      when 1 then v_method := 'snapp';
      else v_method := 'mixed';
    end case;
    case (v_seed / 43) % 7
      when 0 then v_mult := 1.05;
      when 1 then v_mult := 1.1;
      when 2 then v_mult := 1.125;
      when 3 then v_mult := 1.13;
      when 4 then v_mult := 1.15;
      when 5 then v_mult := 1.2;
      else v_mult := 1.25;
    end case;
    v_s := null;
    v_c := null;
    v_net := v_sub - v_disc;
    if v_method = 'mixed' then
      if v_net < 1001 then continue; end if;
      -- a valid v5 pair (tolerance-wide drift on the Snapp side)
      v_c := ((v_seed / 59) % (v_net / 2));
      v_expected := public.round_to_step((v_net - v_c)::numeric * v_mult, 1000);
      v_s := v_expected + (v_seed / 61) % 10001 - 5000;
      if v_s < 1 then v_s := 1; end if;
    end if;
    begin
      select * into r from public.order_amounts(
        v_sub, v_base, v_hp, v_disc, v_bearer, v_ship, v_method, v_s, v_c, v_mult, 5000, v_ship_pay);
    exception when raise_exception then
      if SQLERRM = 'مبلغ اسنپ‌پی واردشده ' || v_s || ' تومان با نقدی ' || v_c || ' تومان هم‌خوانی ندارد؛ مبلغ مورد انتظار اسنپ‌پی ' || v_expected || ' تومان است' then continue; end if;
      if SQLERRM = 'مبلغ اسنپ‌پی واردشده ' || v_s || ' تومان از باقی‌مانده کالاها (' || (v_net - v_c) || ' تومان) بعد از نقدی کمتر است؛ نقدی و مبلغ اسنپ‌پی را با هم بررسی کنید' then continue; end if;
      raise exception 'sweep % failed: %', i, SQLERRM;
    end;
    if (r.o_owe + r.o_h_share) <> r.o_payout then raise exception 'sweep % shares', i; end if;
    if (r.o_snapp_charge + r.o_cash_charge) <> r.o_total then raise exception 'sweep % parts', i; end if;
    if (r.o_snapp_deposit + r.o_cash_charge) <> r.o_payout then raise exception 'sweep % deposit', i; end if;
    if v_method = 'mixed' then
      if r.o_snapp_fee < 0 or r.o_snapp_deposit < 0 then raise exception 'sweep % negative', i; end if;
      if r.o_snapp_charge <> r.o_snapp_part + (case when v_ship_pay = 'snapp' then v_ship else 0 end) then
        raise exception 'sweep % charge', i;
      end if;
      if r.o_snapp_fee <> v_c + v_s - r.o_net then raise exception 'sweep % fee', i; end if;
      if r.o_snapp_deposit <> r.o_net - v_c + (case when v_ship_pay = 'snapp' then v_ship else 0 end) then
        raise exception 'sweep % deposit2', i;
      end if;
    end if;
    if v_method = 'cash' and r.o_snapp_charge <> (case when v_ship_pay = 'snapp' then v_ship else 0 end) then
      raise exception 'sweep % cash snapp', i;
    end if;
  end loop;

  raise notice 'ALL PASSED (mixed_payment.sql): v5 cases+errors, OWNER/M1-M9 legacy, errors, old13, split, 500-combo sweep';
end;
$$;
