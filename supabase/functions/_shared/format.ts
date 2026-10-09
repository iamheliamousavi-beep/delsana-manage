// Pure helpers for every message the notify function sends (sections 8 and 9).
// Nothing here touches the network or Deno globals, so format.test.ts can run
// the whole message pipeline without a database or a Telegram token.

export type Order = {
  id: string;
  created_at: string;
  customer: string;
  phone: string;
  address: string;
  postal_code: string;
  items: { product_id?: string; name: string; qty: number; base: number; hp: number }[];
  shipping_method: string;
  shipping_fee: number;
  method: string;
  discount: number;
  discount_bearer: string;
  total: number;
  owe: number;
  h_share: number;
  payout: number | null;
  status: string;
  tracking: string;
  note: string;
};

export type OutboxRow = {
  id: number;
  kind: string;
  order_id: string | null;
  actor: string | null;
  payload: Record<string, unknown>;
};

/* ------------------------------------------------------------------ labels */
export const STATUS_LABEL: Record<string, string> = {
  new: 'جدید',
  awaiting_snapp: 'در انتظار اسنپ‌پی',
  paid: 'پرداخت شده',
  settled: 'تسویه شده',
  shipped: 'ارسال شده',
  delivered: 'تحویل شده',
  cancelled: 'لغو شده',
};

export const BEARER_LABEL: Record<string, string> = {
  helia: 'پیج',
  mahdi: 'مغازه',
  split: 'نصف‌نصف',
};

export function statusLabel(s: string): string {
  return STATUS_LABEL[s] ?? s;
}
export function bearerLabel(b: string): string {
  return BEARER_LABEL[b] ?? b;
}
export function shippingLabel(s: string): string {
  return s === 'post' ? 'پست' : 'پیک';
}
export function methodLabel(m: string): string {
  return m === 'snapp' ? 'اسنپ‌پی' : 'نقدی';
}

/* --------------------------------------------------------------- formatting */
const moneyFmt = new Intl.NumberFormat('fa-IR');

/** Persian digits with the Persian thousands separator: ۸۴۰٬۰۰۰ */
export function money(value: number | null | undefined): string {
  return moneyFmt.format(Number(value ?? 0));
}

/** Persian digits for small numbers (counts, days). */
export function faNum(value: number | null | undefined): string {
  return moneyFmt.format(Number(value ?? 0));
}

const dateFmt = new Intl.DateTimeFormat('fa-IR-u-ca-persian', {
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  timeZone: 'Asia/Tehran',
});

const timeFmt = new Intl.DateTimeFormat('fa-IR', {
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
  timeZone: 'Asia/Tehran',
});

/** Jalali date in Asia/Tehran — ۱۴۰۵/۰۷/۱۷ */
export function jalaliDate(iso: string | Date): string {
  return dateFmt.format(toDate(iso));
}

/** Jalali date and time — ۱۴۰۵/۰۷/۱۷ — ۱۳:۰۰ */
export function jalaliDateTime(iso: string | Date): string {
  const d = toDate(iso);
  return `${jalaliDate(d)} — ${timeFmt.format(d)}`;
}

/** Hours elapsed since a timestamp, rounded down. */
export function hoursSince(iso: string | Date): number {
  return Math.max(0, Math.floor((Date.now() - toDate(iso).getTime()) / 3600000));
}

function toDate(v: string | Date): Date {
  return v instanceof Date ? v : new Date(v);
}

/** Escape the five characters Telegram parses as markup. */
export function escapeHtml(s: string | null | undefined): string {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/** `${APP_URL}/?view=orders&order=…` — never a trailing slash before `?`. */
export function appUrl(baseUrl: string, view: 'orders' | 'products', orderId?: string | null): string {
  const base = (baseUrl ?? '').replace(/\/+$/, '');
  return orderId ? `${base}/?view=${view}&order=${orderId}` : `${base}/?view=${view}`;
}

export const NO_TRACKING = '⏳ هنوز ثبت نشده';

/* ------------------------------------------------------- outbox group merge */
export type Merged = {
  rows: OutboxRow[];
  kinds: string[];
  has: (kind: string) => boolean;
  actors: string[];
  /** status_changed payload */
  statusFrom: string | null;
  statusTo: string | null;
  /** tracking_changed payload */
  trackingFrom: string | null;
  trackingTo: string | null;
  pinned: boolean | null;
  pinNote: string | null;
  productName: string | null;
  productId: string | null;
  available: boolean | null;
  priceCount: number | null;
  reminderOrderIds: string[];
  /** the channel message has to be created or edited */
  touchesChannel: boolean;
  /** price / availability events, caused by the shop only */
  isProductEvent: boolean;
};

/** Section 9.2 step 2: several rows of one order become ONE message. */
export function mergeEvents(rows: OutboxRow[]): Merged {
  const kinds: string[] = [];
  for (const r of rows) if (!kinds.includes(r.kind)) kinds.push(r.kind);
  const has = (k: string) => kinds.includes(k);
  const find = (k: string) => rows.find((r) => r.kind === k);

  const st = find('status_changed')?.payload ?? {};
  const tr = find('tracking_changed')?.payload ?? {};
  const pin = find('pin_changed')?.payload ?? {};
  const av = find('availability_changed')?.payload ?? {};
  const pr = find('prices_changed')?.payload ?? {};
  const tm = find('tracking_missing')?.payload ?? {};

  const statusTo = typeof st.to === 'string' ? (st.to as string) : null;
  const cancelled = statusTo === 'cancelled';

  return {
    rows,
    kinds,
    has,
    actors: [...new Set(rows.map((r) => r.actor).filter((a): a is string => !!a))],
    statusFrom: typeof st.from === 'string' ? (st.from as string) : null,
    statusTo,
    trackingFrom: typeof tr.from === 'string' ? (tr.from as string) : null,
    trackingTo: typeof tr.to === 'string' ? (tr.to as string) : null,
    pinned: typeof pin.pinned === 'boolean' ? (pin.pinned as boolean) : null,
    pinNote: typeof pin.note === 'string' ? (pin.note as string) : null,
    productName: typeof av.name === 'string' ? (av.name as string) : null,
    productId: typeof av.product_id === 'string' ? (av.product_id as string) : null,
    available: typeof av.available === 'boolean' ? (av.available as boolean) : null,
    priceCount: typeof pr.count === 'number' ? (pr.count as number) : null,
    reminderOrderIds: Array.isArray(tm.order_ids) ? (tm.order_ids as string[]) : [],
    touchesChannel: has('order_created') || has('tracking_changed') || cancelled,
    isProductEvent: has('prices_changed') || has('availability_changed'),
  };
}

/* ------------------------------------------------- channel message (9.3) */
export type ChannelAction = 'create' | 'edit' | 'skip';

/**
 * Idempotency rule of section 9.3: the final text is hashed, and Telegram is
 * only called when something actually changed.
 *   no message yet           -> create
 *   message, same hash       -> skip
 *   message, different hash  -> edit (the caller falls back to create when
 *                               Telegram reports the message is gone)
 */
export function channelAction(
  currentMessageId: number | null,
  currentHash: string | null,
  nextHash: string,
): ChannelAction {
  if (!currentMessageId) return 'create';
  return currentHash === nextHash ? 'skip' : 'edit';
}

export function buildChannelText(order: Order, cancelledLine = false): string {
  const lines = [
    '📦 سفارش جدید',
    `👤 مشتری: <b>${escapeHtml(order.customer)}</b>`,
    `📅 تاریخ ثبت: ${jalaliDate(order.created_at)}`,
    `🚚 کد رهگیری: ${order.tracking ? `<code>${escapeHtml(order.tracking)}</code>` : NO_TRACKING}`,
  ];
  if (cancelledLine || order.status === 'cancelled') lines.push('❌ این سفارش لغو شد');
  return lines.join('\n');
}

/* ------------------------------------------------------- invoice DM (8.3) */
export function buildInvoice(order: Order): string {
  const lines: string[] = [];
  lines.push(`🧾 فاکتور سفارش — ${jalaliDateTime(order.created_at)}`);
  lines.push(`👤 مشتری: ${escapeHtml(order.customer)}`);
  lines.push(`📞 تلفن: ${escapeHtml(order.phone)}`);
  lines.push(`📍 آدرس: ${escapeHtml(order.address)}`);
  lines.push(`📮 کد پستی: ${escapeHtml(order.postal_code)}`);
  lines.push('');
  lines.push('🛍 کالاها:');
  for (const it of order.items) {
    lines.push(`• ${escapeHtml(it.name)} × ${faNum(it.qty)} — ${money((it.base ?? 0) + (it.hp ?? 0))} تومان`);
  }
  if ((order.discount ?? 0) > 0) {
    lines.push(`🏷 تخفیف: ${money(order.discount)} (بر عهده ${bearerLabel(order.discount_bearer)})`);
  }
  lines.push(`🚚 ارسال: ${shippingLabel(order.shipping_method)} — ${money(order.shipping_fee)} تومان`);
  lines.push(`💳 پرداخت: ${methodLabel(order.method)}`);
  lines.push(`💰 مبلغ کل مشتری: ${money(order.total)} تومان`);
  if (order.method === 'snapp') lines.push(`تسویه اسنپ‌پی: ${money(order.payout ?? 0)} تومان`);
  lines.push('');
  lines.push('📊 حساب‌وکتاب');
  lines.push(`به مغازه: ${money(order.owe)}`);
  lines.push(`سهم پیج: ${money(order.h_share)}`);
  lines.push('');
  lines.push(`📌 وضعیت: ${statusLabel(order.status)}`);
  lines.push(`🚚 کد رهگیری: ${order.tracking ? escapeHtml(order.tracking) : NO_TRACKING}`);
  if (order.note) lines.push(`📝 یادداشت: ${escapeHtml(order.note)}`);
  return lines.join('\n');
}

/* ------------------------------------------------------- event DM (8.2) */
export type DmMessage =
  | { kind: 'invoice'; text: string }
  | { kind: 'event'; text: string };

/** Price / availability text — these groups have no order attached. */
export function buildProductEventDm(m: Merged): string {
  if (m.has('prices_changed')) return `قیمت ${faNum(m.priceCount ?? 0)} محصول از مغازه به‌روز شد`;
  if (m.has('availability_changed')) {
    return m.available
      ? `«${escapeHtml(m.productName)}» دوباره موجود شد`
      : `«${escapeHtml(m.productName)}» ناموجود شد`;
  }
  return 'به‌روزرسانی محصولات';
}

/** One merged group produces exactly one message (9.2 step 3). */
export function buildEventDm(order: Order, m: Merged): DmMessage {
  if (m.has('order_created')) return { kind: 'invoice', text: buildInvoice(order) };
  if (m.isProductEvent) return { kind: 'event', text: buildProductEventDm(m) };

  const customer = order.customer;
  const lines: string[] = [];

  if (m.statusTo === 'cancelled') {
    lines.push(`❌ سفارش ${customer} لغو شد`);
  } else if (m.statusTo === 'shipped') {
    lines.push(`📦 سفارش ${customer} ارسال شد`);
    lines.push(order.tracking ? `🚚 کد رهگیری: <code>${escapeHtml(order.tracking)}</code>` : `⏳ کد رهگیری هنوز ثبت نشده`);
  } else if (m.statusTo === 'delivered') {
    lines.push(`✅ سفارش ${customer} تحویل شد`);
  } else if (m.statusTo === 'settled') {
    lines.push(`✅ تسویه شد. سفارش ${customer} آماده ارسال است`);
  } else if (m.statusTo === 'paid') {
    lines.push(`💵 پول سفارش ${customer} رسید`);
  } else if (m.has('tracking_changed')) {
    lines.push(
      m.trackingTo
        ? `🚚 کد رهگیری سفارش ${customer}: <code>${escapeHtml(m.trackingTo)}</code>`
        : `🚚 کد رهگیری سفارش ${customer} پاک شد`,
    );
  } else if (m.pinned !== null) {
    lines.push(
      m.pinned
        ? `📌 سفارش ${customer} سنجاق شد${m.pinNote ? `: ${escapeHtml(m.pinNote)}` : ''}`
        : `سنجاق سفارش ${customer} برداشته شد`,
    );
  } else {
    lines.push(`به‌روزرسانی سفارش ${customer}`);
  }

  return { kind: 'event', text: lines.join('\n') };
}

/** Daily reminder: up to 10 customers with the days since shipping (8.2). */
export function buildTrackingMissingDm(entries: { customer: string; days: number }[]): string {
  const shown = entries.slice(0, 10);
  const list = shown.map((e) => `• ${e.customer} (${faNum(e.days)} روز)`).join('\n');
  const more = entries.length > shown.length ? `\n+ ${faNum(entries.length - shown.length)} مورد دیگر` : '';
  return `⏳ این سفارش‌ها هنوز کد رهگیری ندارند:\n${list}${more}`;
}

/* ------------------------------------------------------------- push (8.4) */
export type PushMessage = {
  title: string;
  body: string;
  tag: string;
  url: string;
  orderIds: string[];
};

export function buildPush(
  order: Order | null,
  m: Merged,
  baseUrl: string,
  actorRole: 'mahdi' | 'helia' | null = null,
): PushMessage {
  const customer = order?.customer ?? '';
  const orderId = order?.id ?? null;
  const view: 'orders' | 'products' = m.isProductEvent ? 'products' : 'orders';
  let title = 'دلسانا';
  let body = '';

  if (m.has('order_created')) {
    title = actorRole === 'helia' ? 'سفارش جدید از پیج' : 'سفارش جدید از مغازه';
    body = customer;
  } else if (m.statusTo === 'cancelled') {
    title = 'سفارش لغو شد';
    body = customer;
  } else if (m.statusTo === 'settled') {
    title = 'آماده ارسال';
    body = customer;
  } else if (m.statusTo === 'shipped' || m.has('tracking_changed')) {
    title = 'کد رهگیری ثبت شد';
    body = customer;
  } else if (m.statusTo === 'paid') {
    title = 'پول سفارش رسید';
    body = customer;
  } else if (m.pinned !== null) {
    title = m.pinned ? 'سفارش سنجاق شد' : 'سنجاق سفارش برداشته شد';
    body = customer;
  } else if (m.has('availability_changed')) {
    title = m.available ? 'محصول موجود شد' : 'محصول ناموجود شد';
    body = m.productName ?? '';
  } else if (m.has('prices_changed')) {
    title = 'قیمت‌ها به‌روز شد';
    body = `${faNum(m.priceCount ?? 0)} محصول از مغازه به‌روز شد`;
  } else {
    title = 'به‌روزرسانی';
    body = customer;
  }

  const tag = m.isProductEvent
    ? m.productId
      ? `product:${m.productId}`
      : 'products:update'
    : `${orderId ?? 'order'}:${m.kinds[0] ?? 'event'}`;

  return {
    title,
    body,
    tag,
    url: appUrl(baseUrl, view, m.isProductEvent ? null : orderId),
    orderIds: orderId ? [orderId] : [],
  };
}
