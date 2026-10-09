// iOS / browser Web Push (section 9.5). Subscriptions live in
// public.push_subscriptions; only the Edge Functions may touch them.

import webpush from 'npm:web-push@3';

export type Subscription = {
  id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
};

export type PushPayload = {
  title: string;
  body: string;
  url: string;
  tag: string;
};

export class PushError extends Error {
  status: number;
  constructor(message: string, status = 0) {
    super(message);
    this.name = 'PushError';
    this.status = status;
  }
}

function vapid() {
  const publicKey = Deno.env.get('VAPID_PUBLIC_KEY');
  const privateKey = Deno.env.get('VAPID_PRIVATE_KEY');
  const subject = Deno.env.get('VAPID_SUBJECT') ?? 'mailto:support@delsana.example';
  if (!publicKey || !privateKey) return null;
  return { publicKey, privateKey, subject };
}

/** True when the project has VAPID keys; otherwise notify simply skips push. */
export function pushEnabled(): boolean {
  return vapid() !== null;
}

/**
 * Send one push. HTTP 404 / 410 mean the subscription is gone for good —
 * the caller must delete the row (section 9.5).
 */
export async function sendPush(sub: Subscription, payload: PushPayload): Promise<void> {
  const cfg = vapid();
  if (!cfg) throw new PushError('VAPID keys are not configured', 0);
  try {
    await webpush.sendNotification(
      { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
      JSON.stringify(payload),
      {
        TTL: 86400,
        vapidDetails: { subject: cfg.subject, publicKey: cfg.publicKey, privateKey: cfg.privateKey },
        headers: { Urgency: 'normal', TTL: '86400' },
      },
    );
  } catch (e) {
    const status = (e as { statusCode?: number })?.statusCode ?? 0;
    throw new PushError(e instanceof Error ? e.message : String(e), status);
  }
}
