// Edge Function `telegram-webhook` — section 9.4.
//
//   POST /functions/v1/telegram-webhook   (--no-verify-jwt: Telegram calls us,
//   authentication is the secret header the platform configured)
//
//   /start <token>  -> link the chat to the app user that created the token
//   /start          -> tell the user how to link from inside the app
//   /stop           -> stop notifications for this chat
//   /help           -> short help
//   anything else   -> ignored; an unlinked chat never learns any data

import { createAdminClient, type Admin } from '../_shared/supabase.ts';
import { sendMessage } from '../_shared/telegram.ts';

type Update = {
  message?: { chat?: { id?: number | string }; text?: string };
};

const JSON_HEADERS = { 'content-type': 'application/json; charset=utf-8' };

const MSG_LINKED = '✅ اتصال برقرار شد. از این پس اعلان‌ها و فاکتورها اینجا می‌آید.';
const MSG_NOT_LINKED =
  'برای اتصال، از داخل اپ، بخش تنظیمات، دکمه «اتصال تلگرام» را بزنید.';
const MSG_STOPPED = 'اعلان‌ها متوقف شد.';
const MSG_HELP =
  'دستورات:\n' +
  '/start — اتصال حساب به اپ دلسانا\n' +
  '/stop — توقف اعلان‌ها\n' +
  '/help — همین راهنما';

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

Deno.serve(async (req) => {
  const secret = Deno.env.get('TELEGRAM_WEBHOOK_SECRET');
  const given = req.headers.get('X-Telegram-Bot-Api-Secret-Token');
  if (!secret || given !== secret) return json({ error: 'unauthorized' }, 401);

  let update: Update;
  try {
    update = await req.json();
  } catch {
    return json({ ok: true });
  }

  const message = update.message;
  const chatId = Number(message?.chat?.id ?? 0);
  const text = typeof message?.text === 'string' ? message.text.trim() : '';
  if (!chatId || !text) return json({ ok: true }); // stickers, photos, edits: ignore

  let admin: Admin;
  try {
    admin = createAdminClient();
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }

  try {
    await handleMessage(admin, chatId, text);
    return json({ ok: true });
  } catch (e) {
    // a transient failure must not be swallowed: Telegram retries a 5xx
    console.error(`telegram-webhook: ${e instanceof Error ? e.message : String(e)}`);
    return json({ error: 'internal' }, 500);
  }
});

async function handleMessage(admin: Admin, chatId: number, text: string): Promise<void> {
  const parts = text.split(/\s+/);
  // "/start@MyBot token" and "/start token" are the same command
  const command = (parts[0] ?? '').split('@')[0].toLowerCase();
  const arg = parts.slice(1).join(' ').trim();

  if (command === '/start') await handleStart(admin, chatId, arg);
  else if (command === '/stop') await handleStop(admin, chatId);
  else if (command === '/help') await sendMessage(chatId, MSG_HELP);
  // anything else: ignore, never reveal data to an unlinked chat
}

/* ------------------------------------------------------------------ /start */
async function handleStart(admin: Admin, chatId: number, token: string): Promise<void> {
  if (!token) {
    await sendMessage(chatId, MSG_NOT_LINKED);
    return;
  }

  const { data: link, error } = await admin
    .from('telegram_links')
    .select('token, user_id, expires_at, used')
    .eq('token', token)
    .maybeSingle();
  if (error) throw new Error(`telegram_links: ${error.message}`);

  const fresh = link && !link.used && new Date(link.expires_at).getTime() > Date.now();
  if (!fresh) {
    await sendMessage(chatId, MSG_NOT_LINKED);
    return;
  }

  // one Telegram chat can only belong to one app user: the newest token wins
  const { error: dropError } = await admin
    .from('telegram_chats')
    .delete()
    .eq('chat_id', chatId)
    .neq('user_id', link.user_id);
  if (dropError) throw new Error(`telegram_chats: ${dropError.message}`);

  const { error: upsertError } = await admin.from('telegram_chats').upsert(
    { user_id: link.user_id, chat_id: chatId, connected_at: new Date().toISOString(), active: true },
    { onConflict: 'user_id' },
  );
  if (upsertError) throw new Error(`telegram_chats: ${upsertError.message}`);

  const { error: usedError } = await admin
    .from('telegram_links')
    .update({ used: true })
    .eq('token', token);
  if (usedError) throw new Error(`telegram_links: ${usedError.message}`);

  await sendMessage(chatId, MSG_LINKED);
}

/* ------------------------------------------------------------------- /stop */
async function handleStop(admin: Admin, chatId: number): Promise<void> {
  const { error } = await admin
    .from('telegram_chats')
    .update({ active: false })
    .eq('chat_id', chatId)
    .eq('active', true);
  if (error) throw new Error(`telegram_chats: ${error.message}`);
  await sendMessage(chatId, MSG_STOPPED);
}
