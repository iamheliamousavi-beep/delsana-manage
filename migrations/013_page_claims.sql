-- ===========================================================================
-- 013_page_claims.sql
--
-- «طلب پیج از مغازه» — the page's receivable ledger (v6/v7 model).
--   Snap Pay settles to the SHOP's account, always. The cash/card part of a
--   customer payment is received by the PAGE. So the money Snap Pay paid to
--   the shop contains the page's profit share («طلب پیج از مغازه», collected
--   per order as order_page_claim) and the money the page received in
--   cash/card contains the shop's share («بدهی پیج به مغازه», derived as
--   order_page_debt). The two accounts are NEVER netted.
--   The claim is DERIVED per order (SQL functions below, exact numeric
--   half-up) — nothing is stored per order. What IS stored: the receipts
--   the page records when the shop pays the claim back, and their
--   per-invoice allocations (partial receipts allowed).
--
--   order_page_claim(o):
--     shipSnap   = shipping_fee if shipping_payment_method = 'snapp' else 0
--     net        = (owe - shipping_fee) + h_share      (goods value after discount)
--     goodsSnap  = snapp_deposit - shipSnap            (goods money via Snap Pay)
--     claim      = 0      if net <= 0 or h_share <= 0 or goodsSnap <= 0
--                = min(goodsSnap, round_half_up(h_share * goodsSnap / net))
--   order_page_debt(o) = owe - snapp_deposit + claim        (always >= 0)
--   JS twin: Calc.pageSplit in calc.js — the tests assert both agree.
--
-- BEFORE running: export all orders as CSV from the app.
-- Every statement below is idempotent and safe to run twice.
-- Mirrored into setup.sql (fresh installs already contain the end state).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) the derived split (the single server-side implementation of section 1;
--    never store the claim per order)
-- ---------------------------------------------------------------------------
create or replace function public.order_page_claim(o public.orders)
returns bigint
language sql
immutable
set search_path = public
as $$
  select case
           when v.net <= 0 or v.h_share <= 0 or v.goods_snap <= 0 then 0::bigint
           else least(v.goods_snap, round(v.h_share * v.goods_snap / v.net))::bigint
         end
  from (
    select ((o.owe - o.shipping_fee) + o.h_share)::numeric as net,
           o.h_share::numeric as h_share,
           (o.snapp_deposit - (case when o.shipping_payment_method = 'snapp'
                                    then o.shipping_fee else 0 end))::numeric as goods_snap
  ) v;
$$;

create or replace function public.order_page_debt(o public.orders)
returns bigint
language sql
immutable
set search_path = public
as $$
  select o.owe - o.snapp_deposit + public.order_page_claim(o);
$$;

-- ---------------------------------------------------------------------------
-- 2) ledger tables (read via RLS for members; every write goes through the
--    RPCs below — no insert/update/delete policies, like `orders`)
-- ---------------------------------------------------------------------------
create table if not exists public.page_claim_receipts (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  created_by  uuid,
  received_on date not null,                -- the day the shop actually paid
  amount      bigint not null check (amount > 0),
  note        text not null default '',
  voided_at   timestamptz,                  -- set = ignored in every sum,
  voided_by   uuid                          -- but stays visible in history
);

create table if not exists public.page_claim_allocations (
  id               uuid primary key default gen_random_uuid(),
  receipt_id       uuid not null references public.page_claim_receipts(id) on delete cascade,
  order_id         uuid not null references public.orders(id) on delete restrict,
  amount           bigint not null check (amount > 0),
  customer         text not null default '',          -- snapshot for display
  order_created_at timestamptz,
  unique (receipt_id, order_id)
);

create index if not exists page_claim_allocations_order_idx
  on public.page_claim_allocations (order_id);

comment on table public.page_claim_receipts is
  'صفحه دریافت‌های پیج از مغازه برای «طلب پیج از مغازه» (migration 013)';
comment on table public.page_claim_allocations is
  'تخصیص هر دریافتی به فاکتورها؛ جمع تخصیص‌های یک دریافتی = مبلغ دریافتی';

alter table public.page_claim_receipts enable row level security;
alter table public.page_claim_allocations enable row level security;

drop policy if exists page_claim_receipts_select on public.page_claim_receipts;
create policy page_claim_receipts_select on public.page_claim_receipts
  for select to authenticated
  using (public.is_member());

drop policy if exists page_claim_allocations_select on public.page_claim_allocations;
create policy page_claim_allocations_select on public.page_claim_allocations
  for select to authenticated
  using (public.is_member());

-- no insert/update/delete policies on purpose (writes only via the RPCs)

-- ---------------------------------------------------------------------------
-- 3) invariant: a receipt's allocations always sum to the receipt amount.
--    Enforced in the RPC; this deferred constraint trigger guards any other
--    write path (owner/SQL) as well. Fires at commit, after all rows exist.
-- ---------------------------------------------------------------------------
create or replace function public.assert_page_claim_receipt_sum()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_receipt uuid;
  v_amount  bigint;
  v_sum     numeric;
begin
  v_receipt := coalesce(new.receipt_id, old.receipt_id);
  select amount into v_amount
    from public.page_claim_receipts where id = v_receipt;
  if not found then
    -- the receipt itself is being (cascade) deleted: nothing to check
    return null;
  end if;
  select coalesce(sum(amount), 0) into v_sum
    from public.page_claim_allocations where receipt_id = v_receipt;
  if v_sum <> v_amount then
    raise exception 'جمع تخصیص‌ها (%) باید دقیقاً برابر مبلغ دریافتی (%) باشد',
      v_sum, v_amount;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_page_claim_alloc_sum on public.page_claim_allocations;
create constraint trigger trg_page_claim_alloc_sum
  after insert or update or delete on public.page_claim_allocations
  deferrable initially deferred
  for each row execute function public.assert_page_claim_receipt_sum();

-- ---------------------------------------------------------------------------
-- 4) RPC: record a receipt (full or partial), automatically FIFO-allocated
--    to the oldest eligible invoices or manually allocated by the caller
-- ---------------------------------------------------------------------------
create or replace function public.record_page_claim_receipt(
  p_amount       bigint,
  p_received_on  date,
  p_note         text default null,
  p_allocations  jsonb default null       -- null = automatic FIFO; or
                                         -- [{"order_id": "...", "amount": 1}, ...]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_id    uuid;
  v_alloc jsonb;
  e       jsonb;
  v_order record;
  v_oid   uuid;
  v_amt   bigint;
  v_amt_num numeric;
  v_total bigint := 0;
  v_left  bigint;
  v_remaining bigint;
begin
  if v_uid is null then raise exception 'ابتدا وارد شوید'; end if;
  if coalesce(public.my_role(), '') not in ('helia', 'admin') then
    raise exception 'فقط پیج یا ادمین می‌تواند دریافتی ثبت کند';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'مبلغ دریافتی باید عددی مثبت باشد';
  end if;
  if p_received_on is null then
    raise exception 'تاریخ دریافت اجباری است';
  end if;
  if p_received_on > current_date then
    raise exception 'تاریخ دریافت نمی‌تواند در آینده باشد';
  end if;

  v_alloc := p_allocations;

  if v_alloc is null then
    -- -------- automatic: oldest eligible invoices first (FIFO) ------------
    v_alloc := '[]'::jsonb;
    v_left := p_amount;
    for v_order in
      select o.*
        from public.orders o
       where o.status in ('paid', 'settled', 'shipped', 'delivered')
         and public.order_page_claim(o) > 0
       order by o.created_at asc, o.id asc
       for update
    loop
      select public.order_page_claim(v_order) - coalesce(sum(a.amount), 0)
        into v_remaining
        from public.page_claim_allocations a
        join public.page_claim_receipts r on r.id = a.receipt_id
       where a.order_id = v_order.id
         and r.voided_at is null;
      if v_remaining <= 0 then continue; end if;
      v_alloc := v_alloc || jsonb_build_array(jsonb_build_object(
        'order_id', v_order.id,
        'amount', least(v_left, v_remaining)));
      v_left := v_left - least(v_left, v_remaining);
      exit when v_left = 0;
    end loop;
    if v_left > 0 then
      raise exception 'مبلغ دریافتی بیش از جمع ماندهٔ طلب‌هاست؛ حداکثر مجاز % تومان است',
        p_amount - v_left;
    end if;
  else
    -- -------- manual: validate every allocation, sum == amount ------------
    if jsonb_typeof(v_alloc) <> 'array' or jsonb_array_length(v_alloc) = 0 then
      raise exception 'تخصیص دستی باید آرایه‌ای غیرخالی از {order_id, amount} باشد';
    end if;
    for e in select value from jsonb_array_elements(v_alloc) loop
      begin
        v_oid := (e->>'order_id')::uuid;
      exception when others then
        raise exception 'شناسه فاکتور نامعتبر است';
      end;
      if e->>'amount' is null then
        raise exception 'مبلغ تخصیص باید عددی مثبت باشد';
      end if;
      begin
        v_amt_num := (e->>'amount')::numeric;
      exception when others then
        raise exception 'مبلغ تخصیص باید عددی مثبت باشد';
      end;
      if v_amt_num is null or v_amt_num <= 0 or v_amt_num <> floor(v_amt_num) then
        raise exception 'مبلغ تخصیص باید عددی مثبت و صحیح باشد';
      end if;
      v_amt := v_amt_num;
      if (select count(*) from jsonb_array_elements(v_alloc) x
           where x->>'order_id' = e->>'order_id') > 1 then
        raise exception 'هر فاکتور فقط یک بار در تخصیص‌ها می‌تواند بیاید';
      end if;

      select * into v_order from public.orders where id = v_oid for update;
      if not found then raise exception 'سفارش پیدا نشد'; end if;
      if v_order.status not in ('paid', 'settled', 'shipped', 'delivered') then
        raise exception 'این فاکتور قابل مطالبه نیست (وضعیت فعلی: %)', v_order.status;
      end if;
      select public.order_page_claim(v_order) - coalesce(sum(a.amount), 0)
        into v_remaining
        from public.page_claim_allocations a
        join public.page_claim_receipts r on r.id = a.receipt_id
       where a.order_id = v_order.id
         and r.voided_at is null;
      if v_remaining <= 0 then
        raise exception 'این فاکتور ماندهٔ قابل مطالبه ندارد';
      end if;
      if v_amt > v_remaining then
        raise exception 'مبلغ تخصیص (% تومان) از ماندهٔ این فاکتور (% تومان) بیشتر است',
          v_amt, v_remaining;
      end if;
      v_total := v_total + v_amt;
    end loop;
    if v_total <> p_amount then
      raise exception 'جمع تخصیص‌ها (% تومان) باید دقیقاً برابر مبلغ دریافتی (% تومان) باشد',
        v_total, p_amount;
    end if;
  end if;

  insert into public.page_claim_receipts (created_by, received_on, amount, note)
  values (v_uid, p_received_on, p_amount, coalesce(p_note, ''))
  returning id into v_id;

  for e in select value from jsonb_array_elements(v_alloc) loop
    select * into v_order from public.orders where id = (e->>'order_id')::uuid;
    insert into public.page_claim_allocations (receipt_id, order_id, amount,
                                               customer, order_created_at)
    values (v_id, v_order.id, (e->>'amount')::bigint,
            v_order.customer, v_order.created_at);
  end loop;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) RPC: void a receipt (idempotent) — the invoices' remaining amounts
--    reappear; the row stays visible in history
-- ---------------------------------------------------------------------------
create or replace function public.void_page_claim_receipt(
  p_receipt_id uuid,
  p_reason     text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(public.my_role(), '') not in ('helia', 'admin') then
    raise exception 'فقط پیج یا ادمین می‌تواند دریافتی را ابطال کند';
  end if;
  if p_receipt_id is null then
    raise exception 'دریافتی پیدا نشد';
  end if;
  if not exists (select 1 from public.page_claim_receipts where id = p_receipt_id) then
    raise exception 'دریافتی پیدا نشد';
  end if;
  update public.page_claim_receipts
     set voided_at = now(),
         voided_by = auth.uid(),
         note = case when coalesce(p_reason, '') = '' then note
                     else note || ' — ابطال: ' || p_reason end
   where id = p_receipt_id
     and voided_at is null;
  -- already voided: idempotent no-op
end;
$$;

-- ---------------------------------------------------------------------------
-- 6) admin_delete_order: refuse orders that carry receipt allocations
--    (financial history pins the order; the FK is ON DELETE RESTRICT too).
--    admin_restore_order keeps working unchanged.
-- ---------------------------------------------------------------------------
create or replace function public.admin_delete_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o record;
begin
  if not public.is_admin() then
    raise exception 'دسترسی غیرمجاز';
  end if;

  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'سفارش پیدا نشد'; end if;

  if exists (select 1 from public.page_claim_allocations where order_id = p_order_id) then
    raise exception 'این سفارش تخصیصِ دریافتی دارد؛ ابتدا دریافتی مربوط را ابطال یا جابه‌جا کنید';
  end if;

  insert into public.audit_log (actor, entity, entity_id, action, before, after)
  values (auth.uid(), 'order', p_order_id, 'delete', to_jsonb(o), null);

  insert into public.outbox (kind, order_id, actor, payload)
  values ('order_deleted', p_order_id, auth.uid(),
          jsonb_build_object('customer', o.customer,
                             'tg_channel_msg_id', o.tg_channel_msg_id,
                             'total', o.total,
                             'status', o.status));

  -- the order is gone: never retry its other pending rows
  update public.outbox set processed_at = now()
   where order_id = p_order_id and processed_at is null and kind <> 'order_deleted';

  delete from public.orders where id = p_order_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7) grants (authenticated only, never anon) — like bulk_set_status
-- ---------------------------------------------------------------------------
revoke all on function public.order_page_claim(public.orders) from PUBLIC, anon, authenticated;
grant execute on function public.order_page_claim(public.orders) to authenticated, service_role;

revoke all on function public.order_page_debt(public.orders) from PUBLIC, anon, authenticated;
grant execute on function public.order_page_debt(public.orders) to authenticated, service_role;

revoke all on function public.record_page_claim_receipt(bigint, date, text, jsonb)
  from PUBLIC, anon, authenticated;
grant execute on function public.record_page_claim_receipt(bigint, date, text, jsonb)
  to authenticated, service_role;

revoke all on function public.void_page_claim_receipt(uuid, text)
  from PUBLIC, anon, authenticated;
grant execute on function public.void_page_claim_receipt(uuid, text)
  to authenticated, service_role;

notify pgrst, 'reload schema';
