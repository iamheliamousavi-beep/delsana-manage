// Edge Function `send-invoice` — section 9.4 (JWT verification ON).
//
//   POST /functions/v1/send-invoice   body { order_id }
//
// The caller must be one of the two partners and must have linked Telegram;
// the full invoice (8.3) goes to their own private chat.

import * as F from '../_shared/format.ts';
import { createAdminClient, createUserClient, type Admin } from '../_shared/supabase.ts';
import { sendMessage } from '../_shared/telegram.ts';

const JSON_HEADERS = { 'content-type': 'application/json; charset=utf-8' };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  let body: { order_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: 'bad request' }, 400);
  }
  const orderId = typeof body?.order_id === 'string' ? body.order_id.trim() : '';
  if (!orderId) return json({ error: 'order_id is required' }, 400);

  const authorization = req.headers.get('authorization') ?? '';
  if (!authorization) return json({ error: 'unauthorized' }, 401);

  let admin: Admin;
  let caller: string | null = null;
  try {
    const userClient = createUserClient(authorization);
    const { data, error } = await userClient.auth.getUser();
    if (error || !data?.user) return json({ error: 'unauthorized' }, 401);
    caller = data.user.id;
    admin = createAdminClient();
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }

  try {
    const { data: profile, error: profileError } = await admin
      .from('profiles')
      .select('user_id')
      .eq('user_id', caller)
      .maybeSingle();
    if (profileError) throw new Error(`profiles: ${profileError.message}`);
    if (!profile) return json({ error: 'forbidden' }, 403); // no profile, no membership

    const { data: chat, error: chatError } = await admin
      .from('telegram_chats')
      .select('chat_id')
      .eq('user_id', caller)
      .eq('active', true)
      .maybeSingle();
    if (chatError) throw new Error(`telegram_chats: ${chatError.message}`);
    if (!chat) return json({ ok: false, reason: 'not_connected' });

    const { data: order, error: orderError } = await admin
      .from('orders')
      .select('*')
      .eq('id', orderId)
      .maybeSingle();
    if (orderError) throw new Error(`orders: ${orderError.message}`);
    if (!order) return json({ ok: false, reason: 'not_found' }, 404);

    await sendMessage(Number(chat.chat_id), F.buildInvoice(order));
    return json({ ok: true });
  } catch (e) {
    console.error(`send-invoice: ${e instanceof Error ? e.message : String(e)}`);
    return json({ error: 'internal' }, 500);
  }
});
