// Minimal Telegram Bot API client: send and edit messages, with the retry
// behaviour section 9.2 requires (429 -> wait retry_after, at most 3 times).

const API = 'https://api.telegram.org';
const MAX_RETRIES = 3;

export type TgResult = {
  ok: boolean;
  result?: { message_id: number; [k: string]: unknown };
  error_code?: number;
  description?: string;
  parameters?: { retry_after?: number };
};

export class TelegramError extends Error {
  code: number;
  retryAfter?: number;
  constructor(message: string, code = 0, retryAfter?: number) {
    super(message);
    this.name = 'TelegramError';
    this.code = code;
    this.retryAfter = retryAfter;
  }
}

function token(): string {
  const t = Deno.env.get('TELEGRAM_BOT_TOKEN');
  if (!t) throw new TelegramError('TELEGRAM_BOT_TOKEN is not configured', 0);
  return t;
}

/** One call to the Bot API, retrying HTTP 429 with the server's retry_after. */
export async function callApi(method: string, payload: unknown): Promise<TgResult> {
  const url = `${API}/bot${token()}/${method}`;
  let lastError = new TelegramError(`${method} failed`, 0);
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    let res: Response;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(payload),
      });
    } catch (e) {
      lastError = new TelegramError(`${method}: ${e instanceof Error ? e.message : String(e)}`);
      await sleep(500 * (attempt + 1));
      continue;
    }

    if (res.status === 429) {
      const body = (await res.json().catch(() => ({}))) as TgResult;
      const wait = body.parameters?.retry_after ?? 1;
      lastError = new TelegramError(`${method}: too many requests`, 429, wait);
      if (attempt < MAX_RETRIES) {
        await sleep(Math.min(wait, 30) * 1000);
        continue;
      }
      throw lastError;
    }

    const body = (await res.json().catch(() => ({ ok: false }))) as TgResult;
    if (res.ok && body.ok) return body;
    throw new TelegramError(
      `${method}: ${body.description ?? res.statusText}`,
      body.error_code ?? res.status,
      body.parameters?.retry_after,
    );
  }
  throw lastError;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

export type InlineButton = { text: string; url: string };

export async function sendMessage(
  chatId: number | string,
  text: string,
  buttons: InlineButton[] = [],
): Promise<number> {
  const out = await callApi('sendMessage', {
    chat_id: chatId,
    text,
    parse_mode: 'HTML',
    disable_web_page_preview: true,
    ...(buttons.length ? { reply_markup: { inline_keyboard: [buttons] } } : {}),
  });
  return out.result?.message_id ?? 0;
}

export type EditOutcome =
  | { status: 'edited'; messageId: number }
  | { status: 'unchanged'; messageId: number }
  | { status: 'missing'; messageId: number };

/**
 * Edit a message. "message is not modified" counts as success (the hash did
 * its job); a message that Telegram no longer knows about is reported as
 * `missing` so the caller can post a new one.
 */
export async function editMessageText(
  chatId: number | string,
  messageId: number,
  text: string,
  buttons: InlineButton[] = [],
): Promise<EditOutcome> {
  try {
    await callApi('editMessageText', {
      chat_id: chatId,
      message_id: messageId,
      text,
      parse_mode: 'HTML',
      ...(buttons.length ? { reply_markup: { inline_keyboard: [buttons] } } : {}),
    });
    return { status: 'edited', messageId };
  } catch (e) {
    const err = e instanceof TelegramError ? e : null;
    const description = err?.message ?? String(e);
    if (description.includes('message is not modified')) {
      return { status: 'unchanged', messageId };
    }
    if (
      description.includes('message to edit not found') ||
      description.includes("message can't be edited") ||
      description.includes('message identifier is not specified') ||
      description.includes('message to delete not found')
    ) {
      return { status: 'missing', messageId };
    }
    throw e;
  }
}

/** Channel chat id, e.g. -1001234567890 */
export function channelId(): string {
  const id = Deno.env.get('TELEGRAM_CHANNEL_ID');
  if (!id) throw new TelegramError('TELEGRAM_CHANNEL_ID is not configured', 0);
  return id;
}
