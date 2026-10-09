// Section 12, tests 3-6 — run with:
//   deno test supabase/functions/_shared/format.test.ts
//
// Deliberately import-free so it runs without fetching anything.

import {
  buildChannelText,
  buildEventDm,
  buildInvoice,
  buildProductEventDm,
  buildPush,
  buildTrackingMissingDm,
  channelAction,
  escapeHtml,
  faNum,
  jalaliDate,
  jalaliDateTime,
  mergeEvents,
  money,
  type Order,
  type OutboxRow,
} from './format.ts';

/* ------------------------------------------------------------- tiny asserts */
function assert(cond: boolean, label: string, detail = '') {
  if (cond) {
    console.log('  PASS  ' + label);
  } else {
    throw new Error(label + (detail ? ' :: ' + detail : ''));
  }
}
function assertEquals<T>(actual: T, expected: T, label: string) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  assert(a === e, label, `expected ${e} got ${a}`);
}
function includes(haystack: string, needle: string, label: string) {
  assert(haystack.includes(needle), label, `missing ${JSON.stringify(needle)} in ${JSON.stringify(haystack)}`);
}
function excludes(haystack: string, needle: string, label: string) {
  assert(!haystack.includes(needle), label, `${JSON.stringify(needle)} should not appear`);
}

/* ------------------------------------------------------------------ fixture */
const order: Order = {
  id: 'ord-1',
  created_at: '2026-10-09T09:30:00Z',
  customer: 'مشتری تست',
  phone: '09121234567',
  address: 'تهران، خیابان آزادی، پلاک ۱',
  postal_code: '1234567890',
  items: [{ name: 'کالای نمونه', qty: 1, base: 500000, hp: 150000 }],
  shipping_method: 'post',
  shipping_fee: 190000,
  method: 'cash',
  discount: 0,
  discount_bearer: 'helia',
  total: 840000,
  owe: 690000,
  h_share: 150000,
  payout: null,
  status: 'shipped',
  tracking: 'POST-123',
  note: '',
};

function row(kind: string, payload: Record<string, unknown>, actor: string | null = 'user-h'): OutboxRow {
  return { id: 1, kind, order_id: 'ord-1', actor, payload };
}

/* ------------------------------------------ 12.3) Jalali date and formatting */
Deno.test('12.3 jalali date for a known timestamp in Asia/Tehran', () => {
  assertEquals(jalaliDate('2024-03-20T12:00:00Z'), '۱۴۰۳/۰۱/۰۱', 'Nowruz day is 1 Farvardin 1403');
  assertEquals(jalaliDate('2026-10-09T09:30:00Z'), '۱۴۰۵/۰۷/۱۷', 'October 2026 is Mehr 1405');
  assertEquals(jalaliDate('2023-03-21T00:00:00Z'), '۱۴۰۲/۰۱/۰۱', 'a timestamp before noon Tehran rolls back a day');
  assertEquals(jalaliDateTime('2026-10-09T09:30:00Z'), '۱۴۰۵/۰۷/۱۷ — ۱۳:۰۰', 'date and time');
  assertEquals(money(840000), '۸۴۰٬۰۰۰', 'Persian money format');
  assertEquals(faNum(14), '۱۴', 'Persian digits');
  assertEquals(escapeHtml('<b> & "x"'), '&lt;b&gt; &amp; &quot;x&quot;', 'html escaping');
});

/* ---------------------------------------------- 12.4) channel message (9.3) */
Deno.test('12.4 channel message builder', () => {
  const withCode = buildChannelText(order);
  assertEquals(
    withCode,
    '📦 سفارش جدید\n' +
      '👤 مشتری: <b>مشتری تست</b>\n' +
      '📅 تاریخ ثبت: ۱۴۰۵/۰۷/۱۷\n' +
      '🚚 کد رهگیری: <code>POST-123</code>',
    'the message holds exactly customer, Jalali date and code',
  );
  excludes(withCode, '09121234567', 'the channel never shows a phone number');
  excludes(withCode, 'تهران، خیابان', 'the channel never shows an address');
  excludes(withCode, '۸۴۰٬۰۰۰', 'the channel never shows an amount');

  const noCode = buildChannelText({ ...order, tracking: '' });
  includes(noCode, '🚚 کد رهگیری: ⏳ هنوز ثبت نشده', 'an empty code falls back to the hourglass');
  excludes(noCode, '<code>', 'no code tag when there is no code');

  const cancelled = buildChannelText({ ...order, status: 'cancelled' });
  includes(cancelled, '❌ این سفارش لغو شد', 'a cancelled order gets the cancelled line');

  const evil = buildChannelText({ ...order, customer: 'آقا <b>علی</b>' });
  includes(evil, '👤 مشتری: <b>آقا &lt;b&gt;علی&lt;/b&gt;</b>', 'customer names are html escaped');
  excludes(evil, 'آقا <b>علی', 'the raw tag never reaches Telegram');
});

/* ------------------------------------------------------- 12.5) invoice DM 8.3 */
Deno.test('12.5 invoice DM builder', () => {
  const text = buildInvoice(order);
  includes(text, 'به مغازه: ۶۹۰٬۰۰۰', 'the invoice carries the amount owed to the shop');
  includes(text, 'سهم پیج: ۱۵۰٬۰۰۰', 'the invoice carries the page share');
  includes(text, '💰 مبلغ کل مشتری: ۸۴۰٬۰۰۰ تومان', 'the customer total');
  includes(text, '🚚 کد رهگیری: POST-123', 'the tracking line');
  includes(text, '📌 وضعیت: ارسال شده', 'the Persian status label');
  includes(text, '💳 پرداخت: نقدی', 'the payment method label');

  excludes(text, 'سود مغازه', 'never mentions the shop profit');
  excludes(text, 'سود پیج', 'never mentions the page profit');
  excludes(text, 'cost', 'never mentions a cost column');
  excludes(text, 'مبلغ خرید', 'never mentions the purchase cost');

  const snapp = buildInvoice({ ...order, method: 'snapp', payout: 840000, owe: 690000 });
  includes(snapp, '💳 پرداخت: اسنپ‌پی', 'snapp payment label');
  includes(snapp, 'تسویه اسنپ‌پی: ۸۴۰٬۰۰۰ تومان', 'the snapp settlement line only exists for snapp');

  const discounted = buildInvoice({ ...order, discount: 50000, discount_bearer: 'split' });
  includes(discounted, '🏷 تخفیف: ۵۰٬۰۰۰ (بر عهده نصف‌نصف)', 'the discount line with its bearer');

  const noNote = buildInvoice(order);
  excludes(noNote, '📝 یادداشت', 'no note line when there is no note');
  const withNote = buildInvoice({ ...order, note: 'زنگ در نزنید' });
  includes(withNote, '📝 یادداشت: زنگ در نزنید', 'the note line when there is a note');
});

/* --------------------------------------------- 12.6) merge rule (9.2 step 2) */
Deno.test('12.6 merge rule produces a single message', () => {
  const rows = [
    row('status_changed', { from: 'settled', to: 'shipped' }),
    row('tracking_changed', { from: '', to: 'POST-123' }),
  ];
  const m = mergeEvents(rows);
  assertEquals(m.kinds, ['status_changed', 'tracking_changed'], 'both kinds are seen');
  assert(m.touchesChannel, 'the channel message has to be edited');

  const dm = buildEventDm(order, m);
  assertEquals(dm.kind, 'event', 'the group is one event message');
  assert(dm.kind === 'event', 'typed as an event');
  const text = dm.kind === 'event' ? dm.text : '';
  includes(text, '📦 سفارش مشتری تست ارسال شد', 'the status text is there');
  includes(text, '<code>POST-123</code>', 'the new code is there');
  assertEquals(text.split('\n').length, 2, 'exactly two lines: one message, not two');

  // the actor never reaches the message pipeline (8.1)
  assertEquals(m.actors, ['user-h'], 'the actor is known so it can be filtered out');

  // order_created alone must become the full invoice
  const created = mergeEvents([row('order_created', {}, 'user-m')]);
  const invoiceDm = buildEventDm(order, created);
  assertEquals(invoiceDm.kind, 'invoice', 'order_created produces the invoice');
  includes(invoiceDm.text, '🧾 فاکتور سفارش', 'the invoice header');

  // product events carry no order
  const product = mergeEvents([{
    id: 9,
    kind: 'availability_changed',
    order_id: null,
    actor: 'user-m',
    payload: { name: 'کالای نمونه', available: false, product_id: 'p-1' },
  }]);
  assert(product.isProductEvent, 'a product event is recognised');
  assertEquals(buildProductEventDm(product), '«کالای نمونه» ناموجود شد', 'unavailable text');
  const prices = mergeEvents([{
    id: 10,
    kind: 'prices_changed',
    order_id: null,
    actor: 'user-m',
    payload: { count: 3 },
  }]);
  assertEquals(buildProductEventDm(prices), 'قیمت ۳ محصول از مغازه به‌روز شد', 'price text');

  // the daily reminder lists at most ten customers
  const many = Array.from({ length: 12 }, (_, i) => ({ customer: `مشتری ${i}`, days: 4 }));
  const reminder = buildTrackingMissingDm(many);
  assert(reminder.split('•').length - 1 === 10, 'at most ten customers are listed', reminder);
  includes(reminder, 'این سفارش‌ها هنوز کد رهگیری ندارند', 'the reminder headline');
});

/* --------------------------------- channel idempotency (9.3) / 12.3 code path */
Deno.test('9.3 the channel is only touched when the text changed', () => {
  assertEquals(channelAction(null, null, 'h1'), 'create', 'first time posts a message');
  assertEquals(channelAction(77, 'h1', 'h1'), 'skip', 'an unchanged text is never re-sent');
  assertEquals(channelAction(77, 'h1', 'h2'), 'edit', 'the tracking edit is an edit');

  // the tracking-added-later flow: the same order, code now present
  const before = buildChannelText({ ...order, tracking: '' });
  const after = buildChannelText({ ...order, tracking: 'POST-123' });
  assert(before !== after, 'adding the code changes the channel text');
  assertEquals(channelAction(77, before, after), 'edit', 'so the message is edited, not reposted');
});

/* ------------------------------------------------------- push text (8.4 / 11) */
Deno.test('8.4 push payload is lock-screen safe', () => {
  const created = mergeEvents([row('order_created', {}, 'user-h')]);
  const push = buildPush(order, created, 'https://example.app', 'helia');
  assertEquals(push.title, 'سفارش جدید از پیج', 'the title names the sender');
  assertEquals(push.body, 'مشتری تست', 'the body is only the customer name');
  assertEquals(push.tag, 'ord-1:order_created', 'tag = order_id:kind');
  assertEquals(push.url, 'https://example.app/?view=orders&order=ord-1', 'deep link');

  for (const value of [push.title, push.body]) {
    excludes(value, '09121234567', 'no phone number in a push');
    excludes(value, 'تهران', 'no address in a push');
    excludes(value, '۸۴۰٬۰۰۰', 'no amount in a push');
    excludes(value, '۶۹۰٬۰۰۰', 'no amount in a push');
  }

  const product = mergeEvents([{
    id: 9,
    kind: 'availability_changed',
    order_id: null,
    actor: 'user-m',
    payload: { name: 'کالای نمونه', available: false, product_id: 'p-1' },
  }]);
  const productPush = buildPush(null, product, 'https://example.app', 'mahdi');
  assertEquals(productPush.title, 'محصول ناموجود شد', 'product push title');
  assertEquals(productPush.body, 'کالای نمونه', 'product push body');
  assertEquals(productPush.tag, 'product:p-1', 'product tag = product:<id>');
  assertEquals(productPush.url, 'https://example.app/?view=products', 'product deep link');
});
