import DocsShell from '../components/docs/DocsShell';
import { agentDocsTabs } from './agentDocsShared';
import {
    DocSection,
    DocH2,
    DocH3,
    DocP,
    DocCallout,
    DocCodeBlock,
    DocCodeTabs,
    DocList,
    DocSteps,
} from '../components/docs/DocComponents';

const sections = [
    { id: 'invoke-reply',  label: 'Invoke — reply mode' },
    { id: 'invoke-send',   label: 'Invoke — send to chat' },
    { id: 'invoke-voice',  label: 'Invoke — voice output' },
    { id: 'invoke-attach', label: 'Invoke — with attachments' },
    { id: 'events-basic',  label: 'Events — basic' },
    { id: 'events-thread', label: 'Events — threading' },
    { id: 'events-integration', label: 'Events — integration secret' },
    { id: 'callback',      label: 'Callback verification' },
    { id: 'rotate',        label: 'Rotate secret' },
];

/* ── Invoke examples ──────────────────────────────────────────── */

const invokeReplyCurl = `curl -X POST "$VIBE_API_BASE_URL/api/agents/$VIBE_AGENT_IDENTIFIER/invoke" \\
  -H "Content-Type: application/json" \\
  -H "X-Vibe-Agent-Secret: $VIBE_AGENT_SECRET" \\
  -d '{
    "message": "Summarise the last 5 trade alerts",
    "source": "ops_dashboard",
    "responseMode": "reply"
  }'`;

const invokeReplyJs = `const resp = await fetch(
  \`\${process.env.VIBE_API_BASE_URL}/api/agents/\${process.env.VIBE_AGENT_IDENTIFIER}/invoke\`,
  {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Vibe-Agent-Secret': process.env.VIBE_AGENT_SECRET,
    },
    body: JSON.stringify({
      message: 'Summarise the last 5 trade alerts',
      source: 'ops_dashboard',
      responseMode: 'reply',
    }),
  }
);

const { success, invocationId, outputs } = await resp.json();
const text = outputs.find(o => o.type === 'text')?.text;
console.log(text);`;

const invokeReplyPy = `import os, requests

data = requests.post(
    f"{os.environ['VIBE_API_BASE_URL']}/api/agents/{os.environ['VIBE_AGENT_IDENTIFIER']}/invoke",
    json={
        "message": "Summarise the last 5 trade alerts",
        "source": "ops_dashboard",
        "responseMode": "reply",
    },
    headers={"X-Vibe-Agent-Secret": os.environ["VIBE_AGENT_SECRET"]},
    timeout=30,
).json()

text = next((o["text"] for o in data.get("outputs", []) if o["type"] == "text"), "")
print(text)`;

const invokeSendCurl = `# Agent must already be a participant of the target chat
curl -X POST "$VIBE_API_BASE_URL/api/agents/$VIBE_AGENT_IDENTIFIER/invoke" \\
  -H "Content-Type: application/json" \\
  -H "X-Vibe-Agent-Secret: $VIBE_AGENT_SECRET" \\
  -d '{
    "message": "Post a market open summary to the team",
    "source": "scheduler",
    "responseMode": "send",
    "vibeChatId": "73928163c120",
    "replyToId": "optional-message-id-to-thread-under"
  }'`;

const invokeVoicePy = `import os, requests

resp = requests.post(
    f"{os.environ['VIBE_API_BASE_URL']}/api/agents/{os.environ['VIBE_AGENT_IDENTIFIER']}/invoke",
    json={
        "message": "Read today's price summary aloud",
        "source": "voice_panel",
        "responseMode": "reply",
        "outputMode": "voice",      # requires "voice" in agent output_modes
    },
    headers={"X-Vibe-Agent-Secret": os.environ["VIBE_AGENT_SECRET"]},
    timeout=60,
)

data = resp.json()
voice_output = next(o for o in data["outputs"] if o["type"] == "voice")
# voice_output = { "type": "voice", "text": "...", "mediaUrl": "https://...", "metadata": { "duration": 12.4 } }
print(voice_output["mediaUrl"])`;

const invokeAttachJs = `const resp = await fetch(
  \`\${VIBE_API_BASE_URL}/api/agents/\${VIBE_AGENT_IDENTIFIER}/invoke\`,
  {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Vibe-Agent-Secret': VIBE_AGENT_SECRET,
    },
    body: JSON.stringify({
      message: 'What is in this chart?',
      source: 'chart_analyzer',
      responseMode: 'reply',
      attachments: [
        { type: 'image', url: 'https://cdn.example.com/chart-2026-03-30.png' },
      ],
    }),
  }
);`;

/* ── Events examples ──────────────────────────────────────────── */

const eventsBasicCurl = `curl -X POST "$VIBE_API_BASE_URL/api/agents/$VIBE_AGENT_IDENTIFIER/events" \\
  -H "Content-Type: application/json" \\
  -H "X-Vibe-Agent-Secret: $VIBE_AGENT_SECRET" \\
  -d '{
    "eventId":   "alert_8821",
    "eventType": "alert.critical",
    "source":    "monitoring",
    "title":     "CPU > 95% on prod-web-01",
    "text":      "CPU usage has exceeded 95% for 5 consecutive minutes.",
    "data":      { "host": "prod-web-01", "value": 97.4 },
    "destinationChatId": "73928163c120"
  }'`;

const eventsThreadPy = `import os, requests

base = os.environ["VIBE_API_BASE_URL"]
agent = os.environ["VIBE_AGENT_IDENTIFIER"]
secret = os.environ["VIBE_AGENT_SECRET"]
chat = os.environ["VIBE_DESTINATION_CHAT_ID"]

def post_event(event_id, event_type, title, text, data):
    return requests.post(
        f"{base}/api/agents/{agent}/events",
        json={
            "eventId":           event_id,
            "eventType":         event_type,
            "threadKey":         "trade_10022",   # groups under one thread
            "source":            "tradeai",
            "title":             title,
            "text":              text,
            "data":              data,
            "destinationChatId": chat,
        },
        headers={"X-Vibe-Agent-Secret": secret},
        timeout=10,
    ).json()

# Three events — same thread, different types
post_event("trade_10022_open",  "trade.opened",  "EURUSD opened",  "Buy 0.5 lots at 1.0875", {"entry": 1.0875})
post_event("trade_10022_sl",    "trade.sl_moved", "SL adjusted",   "SL moved to 1.0855",      {"sl": 1.0855})
post_event("trade_10022_close", "trade.closed",  "EURUSD closed",  "Closed at 1.0920, +45 pips",{"exit": 1.092})`;

const eventsIntegrationCurl = `# Use X-Vibe-Integration-Secret to identify a specific integration
curl -X POST "$VIBE_API_BASE_URL/api/agents/$VIBE_AGENT_IDENTIFIER/events" \\
  -H "Content-Type: application/json" \\
  -H "X-Vibe-Integration-Secret: $VIBE_INTEGRATION_SECRET" \\
  -d '{
    "eventId":   "pd_inc_9183",
    "eventType": "incident.triggered",
    "source":    "pager_duty",
    "title":     "Database connection pool exhausted",
    "text":      "PagerDuty alert #9183: DB pool at 100% utilisation on us-east-1.",
    "data":      { "service": "db-primary", "severity": "critical" }
  }'`;

/* ── Callback verification ────────────────────────────────────── */

const callbackNode = `import crypto from 'node:crypto';
import express from 'express';

const app = express();
app.use(express.raw({ type: 'application/json' }));

app.post('/vibe-callbacks', (req, res) => {
  const timestamp = req.headers['x-vibe-agent-signature-timestamp'] ?? '';
  const signature = req.headers['x-vibe-agent-signature'] ?? '';
  const rawBody   = req.body.toString('utf8');

  // Reconstruct the expected signature
  const expected = crypto
    .createHmac('sha256', process.env.VIBE_AGENT_SECRET)
    .update(\`\${timestamp}.\${rawBody}\`)
    .digest('hex');

  // Use constant-time comparison to prevent timing attacks
  const isValid = crypto.timingSafeEqual(
    Buffer.from(signature, 'hex'),
    Buffer.from(expected, 'hex'),
  );

  if (!isValid) return res.status(401).send('Invalid signature');

  const payload = JSON.parse(rawBody);
  console.log('Callback event type:', payload.event_type);
  // "agent.invocation.completed" | "agent.message.delivered" | "agent.message.failed"

  res.status(200).json({ received: true });
});`;

const callbackPython = `import hashlib, hmac, os
from flask import Flask, request, abort

app = Flask(__name__)

@app.post("/vibe-callbacks")
def handle_callback():
    timestamp = request.headers.get("X-Vibe-Agent-Signature-Timestamp", "")
    signature = request.headers.get("X-Vibe-Agent-Signature", "")
    raw_body  = request.get_data()

    secret = os.environ["VIBE_AGENT_SECRET"].encode()
    message = f"{timestamp}.{raw_body.decode()}".encode()
    expected = hmac.new(secret, message, hashlib.sha256).hexdigest()

    if not hmac.compare_digest(signature, expected):
        abort(401)

    payload = request.json
    print("Callback event:", payload.get("event_type"))
    return {"received": True}`;

/* ── Rotate secret ──────────────────────────────────────────── */

const rotateSecret = `# Rotate the agent secret (owner auth required)
curl -X POST "$VIBE_API_BASE_URL/api/agents/$AGENT_ID/secret/rotate" \\
  -H "Authorization: Bearer $USER_TOKEN"

# Response includes the new secret — store it immediately
{
  "agent": { ... },
  "secret": "vas_NEW_SECRET_VALUE_HERE"
}`;

export default function AgentExamplesDocs() {
    return (
        <DocsShell
            eyebrow="Agents"
            title="Code examples"
            intro="Working code for every common integration pattern — invoke in reply and send modes, voice output, image attachments, event threading, integration secrets, callback verification, and secret rotation."
            tabs={agentDocsTabs}
            sections={sections}
        >
            {/* ── Invoke — reply ────────────────────────────────── */}
            <DocSection id="invoke-reply">
                <DocH2>Invoke — reply mode</DocH2>
                <DocP>
                    <code>responseMode: "reply"</code> is the default. The agent processes the message and
                    returns outputs in the HTTP response body. No Vibe chat bubble is created. Use this when
                    your backend wants the output for its own processing.
                </DocP>
                <DocCodeTabs tabs={[
                    { label: 'cURL',       code: invokeReplyCurl, lang: 'bash'       },
                    { label: 'JavaScript', code: invokeReplyJs,   lang: 'javascript' },
                    { label: 'Python',     code: invokeReplyPy,   lang: 'python'     },
                ]} />
            </DocSection>

            {/* ── Invoke — send ─────────────────────────────────── */}
            <DocSection id="invoke-send">
                <DocH2>Invoke — send to Vibe chat</DocH2>
                <DocP>
                    <code>responseMode: "send"</code> posts the agent's output as a real chat bubble in the
                    specified Vibe chat. The agent must already be a participant of the target chat.
                </DocP>
                <DocCallout type="warning">
                    If the agent is not a participant of <code>vibeChatId</code>, the server returns{' '}
                    <code>403 Agent not attached to target chat</code>. Attach the agent to the chat from the
                    native config panel before using send mode.
                </DocCallout>
                <DocCodeBlock lang="bash" code={invokeSendCurl} />
            </DocSection>

            {/* ── Invoke — voice ────────────────────────────────── */}
            <DocSection id="invoke-voice">
                <DocH2>Invoke — voice output</DocH2>
                <DocP>
                    Pass <code>outputMode: "voice"</code> to request audio output. The agent generates text,
                    then synthesises it using OpenAI TTS. The response includes a <code>mediaUrl</code> pointing
                    to the audio file. The agent's <code>output_modes</code> array must include{' '}
                    <code>"voice"</code>.
                </DocP>
                <DocCallout type="note">
                    Voice synthesis requires <code>OPENAI_API_KEY</code> in the server environment. If it is not
                    set, publishing with voice mode enabled will fail.
                </DocCallout>
                <DocCodeBlock lang="python" code={invokeVoicePy} />
            </DocSection>

            {/* ── Invoke — attachments ──────────────────────────── */}
            <DocSection id="invoke-attach">
                <DocH2>Invoke — image attachments</DocH2>
                <DocP>
                    Pass image URLs in the <code>attachments</code> array. The runtime fetches the images and
                    includes them as vision context for the model. Supported types: PNG, JPEG, WEBP, GIF.
                </DocP>
                <DocCodeBlock lang="javascript" code={invokeAttachJs} />
            </DocSection>

            {/* ── Events — basic ────────────────────────────────── */}
            <DocSection id="events-basic">
                <DocH2>Events — basic ingestion</DocH2>
                <DocP>
                    A minimal event push. The server authenticates the secret, looks up the agent, and runs the
                    event through the autonomy + runbook pipeline. If a destination chat is configured, the agent
                    posts a message there.
                </DocP>
                <DocCodeBlock lang="bash" code={eventsBasicCurl} />
            </DocSection>

            {/* ── Events — threading ───────────────────────────── */}
            <DocSection id="events-thread">
                <DocH2>Events — thread grouping</DocH2>
                <DocP>
                    Use <code>threadKey</code> to group related events into one <code>AgentEventThread</code>.
                    The agent sees the full event history for that key when processing each new event — enabling
                    coherent trade lifecycle tracking, incident timelines, and similar stateful workflows.
                </DocP>
                <DocCallout type="tip">
                    Choose a stable, meaningful threadKey — a trade ID, ticket number, or session ID. Events
                    with different threadKeys always create separate threads even if they arrive from the same
                    source.
                </DocCallout>
                <DocCodeBlock lang="python" code={eventsThreadPy} />
            </DocSection>

            {/* ── Events — integration secret ───────────────────── */}
            <DocSection id="events-integration">
                <DocH2>Events — integration secret</DocH2>
                <DocP>
                    If you created a named integration under the agent, you can use that integration's own
                    secret (<code>X-Vibe-Integration-Secret</code>) instead of the main agent secret. The server
                    will identify the integration and apply its autonomy mode, routing rules, and destination
                    overrides automatically.
                </DocP>
                <DocCodeBlock lang="bash" code={eventsIntegrationCurl} />
            </DocSection>

            {/* ── Callback verification ─────────────────────────── */}
            <DocSection id="callback">
                <DocH2>Callback signature verification</DocH2>
                <DocP>
                    When a <code>callbackUrl</code> is configured, Vibe signs each outbound delivery with
                    HMAC-SHA256. The signature is computed as:
                </DocP>
                <DocCodeBlock lang="text" code={`HMAC-SHA256(secret, "{timestamp}.{rawBody}")\n→ hex-encoded`} />
                <DocP>
                    Two headers are sent with every delivery: <code>X-Vibe-Agent-Signature-Timestamp</code> and
                    <code>X-Vibe-Agent-Signature</code>. Verify both using constant-time comparison.
                </DocP>
                <DocCallout type="warning">
                    Always use <strong>constant-time comparison</strong> (<code>timingSafeEqual</code> or{' '}
                    <code>hmac.compare_digest</code>). String equality operators are vulnerable to timing attacks.
                </DocCallout>
                <DocCodeTabs tabs={[
                    { label: 'Node.js', code: callbackNode,   lang: 'javascript' },
                    { label: 'Python',  code: callbackPython, lang: 'python'     },
                ]} />

                <DocH3>Callback event types</DocH3>
                <DocList items={[
                    <><code>agent.invocation.completed</code> — Fired after a successful invoke call. Payload includes the invocation ID and the full outputs object.</>,
                    <><code>agent.message.delivered</code> — Fired after a Vibe chat message is successfully posted.</>,
                    <><code>agent.message.failed</code> — Fired if message delivery to Vibe chat fails after retries.</>,
                ]} />
            </DocSection>

            {/* ── Rotate secret ─────────────────────────────────── */}
            <DocSection id="rotate">
                <DocH2>Rotate the agent secret</DocH2>
                <DocP>
                    <code>POST /api/agents/:id/secret/rotate</code> generates a new secret, stores its hash and
                    encrypted form, and returns the plaintext once. The previous secret is immediately invalid —
                    update all backend services before rotating in production.
                </DocP>

                <DocSteps items={[
                    { title: 'Rotate via API or config panel', body: 'Call the rotate endpoint or tap Rotate in the native config panel. The new secret value is returned in the response.' },
                    { title: 'Update your backend secrets', body: 'Replace VIBE_AGENT_SECRET in all workers, notifiers, and secret managers immediately. The old secret no longer works.' },
                    { title: 'Verify with secretHint', body: 'After deployment, GET /api/agents/:id and check that secretHint matches the last 6 chars of your new value.' },
                ]} />

                <DocCodeBlock lang="bash" code={rotateSecret} />

                <DocCallout type="danger">
                    There is no grace period. The old secret stops working the instant rotation completes.
                    Always have your backend services updated before rotating in production.
                </DocCallout>
            </DocSection>
        </DocsShell>
    );
}
