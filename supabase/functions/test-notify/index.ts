// Edge Function `test-notify` — section 9.4 (JWT verification ON).
//
//   POST /functions/v1/test-notify
//
// Sends the caller a test DM and a test push on every registered device and
// reports which of them worked, so the Settings button can say what happened.

import { createAdminClient, createUserClient, type Admin } from '../_shared/supabase.ts';
import { sendMessage } from '../_shared/telegram.ts';
import { pushEnabled, PushError, sendPush, type Subscription } from '../_shared/push.ts';

const TEXT = '🔔 اعلان آزمایشی دلسانا';
const BODY = 'اعلان روی گوشی درست کار می‌کند.';

const JSON_HEADERS = { 'content-type': 'application/json; charset=utf-8' };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function appUrl(view: string): string {
  const base = (Deno.env.get('APP_URL') ?? '').replace(/\/+$/, '');
  return base ? `${base}/?view=${view}` : `/?view=${view}`;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

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
    if (!profile) return json({ error: 'forbidden' }, 403);

    /* ---------------------------------------------------------- telegram */
    let telegram: 'sent' | 'not_connected' = 'not_connected';
    const { data: chat, error: chatError } = await admin
      .from('telegram_chats')
      .select('chat_id')
      .eq('user_id', caller)
      .eq('active', true)
      .maybeSingle();
    if (chatError) throw new Error(`telegram_chats: ${chatError.message}`);
    if (chat) {
      await sendMessage(Number(chat.chat_id), TEXT);
      telegram = 'sent';
    }

    /* -------------------------------------------------------------- push */
    const push = { sent: 0, failed: 0 };
    if (pushEnabled()) {
      const { data: rows, error: subError } = await admin
        .from('push_subscriptions')
        .select('id, endpoint, p256dh, auth')
        .eq('user_id', caller);
      if (subError) throw new Error(`push_subscriptions: ${subError.message}`);
      const payload = { title: TEXT, body: BODY, url: appUrl('settings'), tag: 'test-notify' };
      for (const sub of (rows ?? []) as Subscription[]) {
        try {
          await sendPush(sub, payload);
          push.sent++;
          await admin.from('push_subscriptions').update({ last_ok_at: new Date().toISOString() })
            .eq('id', sub.id);
        } catch (e) {
          const status = e instanceof PushError ? e.status : 0;
          if (status === 404 || status === 410) {
            await admin.from('push_subscriptions').delete().eq('id', sub.id);
          }
          push.failed++;
        }
      }
    }

    return json({ ok: true, telegram, push });
  } catch (e) {
    console.error(`test-notify: ${e instanceof Error ? e.message : String(e)}`);
    return json({ error: 'internal' }, 500);
  }
});
