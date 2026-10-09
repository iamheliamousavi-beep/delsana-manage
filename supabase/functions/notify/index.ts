// Edge Function `notify` — section 9.2.
//
//   POST /functions/v1/notify   (header x-webhook-secret, deployed with
//   --no-verify-jwt because the caller is our own database, not a browser)
//
// 1. claim up to 50 pending outbox rows atomically (attempts is incremented
//    inside claim_outbox, so overlapping invocations never double-send);
// 2. group by order_id, apply the merge rule, load the order, work out who
//    has to hear about it;
// 3. send the Telegram DMs, the pushes and create/edit the channel message;
// 4. mark success with processed_at, keep failures pending with last_error;
// 5. answer {processed, failed}.

import * as F from '../_shared/format.ts';
import { createAdminClient, type Admin } from '../_shared/supabase.ts';
import {
  channelId,
  editMessageText,
  sendMessage,
  TelegramError,
} from '../_shared/telegram.ts';
import { pushEnabled, PushError, sendPush, type Subscription } from '../_shared/push.ts';

type Row = F.OutboxRow & { attempts: number; processed_at: string | null };
type Profile = { user_id: string; role: 'mahdi' | 'helia' };
type OrderRow = F.Order & {
  tg_channel_msg_id: number | null;
  tg_channel_hash: string | null;
  status_history?: { status: string; at: string }[];
};

const MAX_ROUNDS = 20;
const JSON_HEADERS = { 'content-type': 'application/json; charset=utf-8' };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function baseUrl(): string {
  return (Deno.env.get('APP_URL') ?? '').replace(/\/+$/, '');
}

Deno.serve(async (req) => {
  const secret = Deno.env.get('WEBHOOK_SECRET');
  const given = req.headers.get('x-webhook-secret');
  if (!secret || given !== secret) return json({ error: 'unauthorized' }, 401);

  let admin: Admin;
  try {
    admin = createAdminClient();
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }

  const profiles = await loadProfiles(admin);
  const base = baseUrl();
  let processed = 0;
  let failed = 0;

  // "the function always processes ALL pending rows" (9.1): keep claiming
  // batches until the outbox is empty or every row has burned its retries.
  for (let round = 0; round < MAX_ROUNDS; round++) {
    const { data, error } = await admin.rpc('claim_outbox', { p_limit: 50 });
    if (error) return json({ error: error.message, processed, failed }, 500);
    const rows = (data ?? []) as Row[];
    if (rows.length === 0) break;

    for (const group of groupRows(rows)) {
      try {
        const problems = await handleGroup(admin, group, profiles, base);
        if (problems.length) {
          await markFailed(admin, group, problems.join(' | '));
          failed += group.length;
        } else {
          await markProcessed(admin, group);
          processed += group.length;
        }
      } catch (e) {
        await markFailed(admin, group, e instanceof Error ? e.message : String(e));
        failed += group.length;
      }
    }
  }

  return json({ processed, failed });
});

/* ------------------------------------------------------------------ groups */
function groupRows(rows: Row[]): Row[][] {
  const byKey = new Map<string, Row[]>();
  for (const r of rows) {
    // orders merge by order_id; product / reminder rows have no order, so they
    // merge per kind and never mix two different products in one message.
    const key = r.order_id ?? `${r.kind}`;
    const list = byKey.get(key);
    if (list) list.push(r);
    else byKey.set(key, [r]);
  }
  return [...byKey.values()];
}

/* -------------------------------------------------------------- recipients */
async function loadProfiles(admin: Admin): Promise<Profile[]> {
  const { data, error } = await admin.from('profiles').select('user_id, role');
  if (error) throw new Error(`profiles: ${error.message}`);
  return (data ?? []) as Profile[];
}

/**
 * 8.1: the actor is never notified; product events reach the page; events
 * without an actor reach both partners.
 */
function recipientsFor(m: F.Merged, profiles: Profile[]): Profile[] {
  if (m.isProductEvent) return profiles.filter((p) => p.role === 'helia');
  if (m.actors.length === 0) return profiles;
  return profiles.filter((p) => !m.actors.includes(p.user_id));
}

function actorRole(m: F.Merged, profiles: Profile[]): 'mahdi' | 'helia' | null {
  const actor = m.actors[0];
  if (!actor) return null;
  return profiles.find((p) => p.user_id === actor)?.role ?? null;
}

/* ----------------------------------------------------------------- group */
async function handleGroup(
  admin: Admin,
  group: Row[],
  profiles: Profile[],
  base: string,
): Promise<string[]> {
  const m = F.mergeEvents(group);
  const problems: string[] = [];

  let order: OrderRow | null = null;
  if (group[0].order_id) {
    const { data, error } = await admin
      .from('orders')
      .select('*')
      .eq('id', group[0].order_id)
      .maybeSingle();
    if (error) throw new Error(`orders: ${error.message}`);
    order = data as OrderRow | null;
    if (!order) throw new Error(`order ${group[0].order_id} not found`);
  }

  /* 1) Telegram DMs ------------------------------------------------- */
  const dm = await buildDm(admin, order, m, base);
  const role = actorRole(m, profiles);
  for (const person of recipientsFor(m, profiles)) {
    try {
      await deliverDm(admin, person, dm);
    } catch (e) {
      problems.push(`dm ${person.role}: ${message(e)}`);
    }
    if (pushEnabled()) {
      try {
        await deliverPush(admin, person, order, m, base, role);
      } catch (e) {
        problems.push(`push ${person.role}: ${message(e)}`);
      }
    }
  }

  /* 2) the private channel ------------------------------------------ */
  if (order && m.touchesChannel) {
    try {
      await syncChannel(admin, order, m);
    } catch (e) {
      problems.push(`channel: ${message(e)}`);
    }
  }

  return problems;
}

async function buildDm(
  admin: Admin,
  order: OrderRow | null,
  m: F.Merged,
  base: string,
): Promise<{ text: string; url: string }> {
  if (m.has('tracking_missing')) {
    const entries = await loadReminderEntries(admin, m.reminderOrderIds);
    return { text: F.buildTrackingMissingDm(entries), url: F.appUrl(base, 'orders') };
  }
  if (m.isProductEvent) {
    return { text: F.buildProductEventDm(m), url: F.appUrl(base, 'products') };
  }
  if (!order) throw new Error('an order event without an order');
  const built = F.buildEventDm(order, m);
  return { text: built.text, url: F.appUrl(base, 'orders', order.id) };
}

async function deliverDm(
  admin: Admin,
  person: Profile,
  dm: { text: string; url: string },
): Promise<void> {
  const { data, error } = await admin
    .from('telegram_chats')
    .select('chat_id')
    .eq('user_id', person.user_id)
    .eq('active', true)
    .maybeSingle();
  if (error) throw new Error(`telegram_chats: ${error.message}`);
  if (!data) return; // this partner never linked Telegram
  await sendMessage(Number(data.chat_id), dm.text, [{ text: 'باز کردن در اپ', url: dm.url }]);
}

async function deliverPush(
  admin: Admin,
  person: Profile,
  order: OrderRow | null,
  m: F.Merged,
  base: string,
  role: 'mahdi' | 'helia' | null,
): Promise<void> {
  const { data, error } = await admin
    .from('push_subscriptions')
    .select('id, endpoint, p256dh, auth')
    .eq('user_id', person.user_id);
  if (error) throw new Error(`push_subscriptions: ${error.message}`);
  const subs = (data ?? []) as Subscription[];
  if (subs.length === 0) return;

  const payload = F.buildPush(order, m, base, role);
  for (const sub of subs) {
    try {
      await sendPush(sub, payload);
      await admin.from('push_subscriptions').update({ last_ok_at: new Date().toISOString() })
        .eq('id', sub.id);
    } catch (e) {
      const status = e instanceof PushError ? e.status : 0;
      if (status === 404 || status === 410) {
        // the browser dropped the subscription: stop sending to it
        await admin.from('push_subscriptions').delete().eq('id', sub.id);
        continue;
      }
      throw e;
    }
  }
}

async function loadReminderEntries(
  admin: Admin,
  ids: string[],
): Promise<{ customer: string; days: number }[]> {
  if (ids.length === 0) return [];
  const { data, error } = await admin
    .from('orders')
    .select('customer, status_history, created_at')
    .in('id', ids);
  if (error) throw new Error(`orders: ${error.message}`);
  return ((data ?? []) as OrderRow[]).map((o) => ({
    customer: o.customer,
    days: shippedDays(o),
  }));
}

function shippedDays(o: OrderRow): number {
  const shipped = [...(o.status_history ?? [])].reverse().find((h) => h.status === 'shipped');
  const at = shipped?.at ?? o.created_at;
  const days = Math.floor((Date.now() - new Date(at).getTime()) / 86400000);
  return Math.max(0, days);
}

/* ------------------------------------------------------- channel message 9.3 */
async function syncChannel(admin: Admin, order: OrderRow, m: F.Merged): Promise<void> {
  const chat = channelId();
  const text = F.buildChannelText(order, m.statusTo === 'cancelled');
  const hash = await sha256(text);
  const buttons = [{ text: 'باز کردن در اپ', url: F.appUrl(baseUrl(), 'orders', order.id) }];

  const action = F.channelAction(order.tg_channel_msg_id, order.tg_channel_hash, hash);
  if (action === 'skip') return;

  if (action === 'edit') {
    const out = await editMessageText(chat, order.tg_channel_msg_id!, text, buttons);
    if (out.status !== 'missing') {
      await saveChannelRef(admin, order.id, out.messageId, hash);
      return;
    }
    // the message is gone (deleted, or the bot was re-added): post a new one
  }

  const messageId = await sendMessage(chat, text, buttons);
  await saveChannelRef(admin, order.id, messageId, hash);
}

async function saveChannelRef(
  admin: Admin,
  orderId: string,
  messageId: number,
  hash: string,
): Promise<void> {
  const { error } = await admin
    .from('orders')
    .update({ tg_channel_msg_id: messageId, tg_channel_hash: hash })
    .eq('id', orderId);
  if (error) throw new Error(`save channel ref: ${error.message}`);
}

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/* ------------------------------------------------------------ bookkeeping */
async function markProcessed(admin: Admin, group: Row[]): Promise<void> {
  const { error } = await admin
    .from('outbox')
    .update({ processed_at: new Date().toISOString() })
    .in('id', group.map((r) => r.id));
  if (error) throw new Error(`outbox: ${error.message}`);
}

async function markFailed(admin: Admin, group: Row[], reason: string): Promise<void> {
  const { error } = await admin
    .from('outbox')
    .update({ last_error: reason.slice(0, 500) })
    .in('id', group.map((r) => r.id));
  if (error) console.error(`outbox last_error: ${error.message}`);
}

function message(e: unknown): string {
  if (e instanceof TelegramError) return e.message;
  if (e instanceof Error) return e.message;
  return String(e);
}
