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
    DocParamTable,
    DocSteps,
} from '../components/docs/DocComponents';

const sections = [
    { id: 'get-env',    label: 'Get the env pack' },
    { id: 'variables',  label: 'Variables reference' },
    { id: 'dotenv',     label: '.env file' },
    { id: 'loading',    label: 'Loading in code' },
    { id: 'destination', label: 'Destination chat' },
    { id: 'security',   label: 'Security practices' },
];

/* ── Code examples ──────────────────────────────────────────── */

const dotenvFull = `# Vibe Agent — backend environment config

# Base URL of the Vibe API (no trailing slash, no /api suffix)
VIBE_API_BASE_URL=https://api.vibegram.io

# Your agent identifier — UUID or @username
VIBE_AGENT_IDENTIFIER=bd35d022-ad48-461a-ac44-f09d165a4232

# The invoke/events secret (prefix: vas_)
# Copy from the config panel immediately after create/rotate — stored plaintext nowhere else
VIBE_AGENT_SECRET=vas_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Optional: default destination for event ingestion
# Required when the agent has no default_destination_chat_id configured
VIBE_DESTINATION_CHAT_ID=73928163c120

# Optional: integration-specific secret if using named integrations
# VIBE_INTEGRATION_SECRET=vas_yyyyyyyyyyyyyyyyyyyyyyyyyyyy

# Short producer label stored on each invocation record
VIBE_SOURCE=tradeai

# HTTP client timeout for invoke calls (seconds)
# Events endpoint is typically faster; invoke may run longer AI completions
VIBE_TIMEOUT_SECONDS=30`;

const loadNodeJs = `import 'dotenv/config';

// Validate required values at startup — fail fast
const required = [
  'VIBE_API_BASE_URL',
  'VIBE_AGENT_IDENTIFIER',
  'VIBE_AGENT_SECRET',
];

for (const key of required) {
  if (!process.env[key]) {
    throw new Error(\`Missing required env var: \${key}\`);
  }
}

export const vibeConfig = {
  baseUrl:     process.env.VIBE_API_BASE_URL!,
  identifier:  process.env.VIBE_AGENT_IDENTIFIER!,
  secret:      process.env.VIBE_AGENT_SECRET!,
  chatId:      process.env.VIBE_DESTINATION_CHAT_ID,
  source:      process.env.VIBE_SOURCE ?? 'backend',
  timeout:     parseInt(process.env.VIBE_TIMEOUT_SECONDS ?? '30', 10),
} as const;`;

const loadPython = `import os
from dataclasses import dataclass
from typing import Optional

@dataclass(frozen=True)
class VibeConfig:
    base_url:    str
    identifier:  str
    secret:      str
    chat_id:     Optional[str]
    source:      str
    timeout:     int

def load_config() -> VibeConfig:
    missing = [
        k for k in ("VIBE_API_BASE_URL", "VIBE_AGENT_IDENTIFIER", "VIBE_AGENT_SECRET")
        if not os.environ.get(k)
    ]
    if missing:
        raise EnvironmentError(f"Missing required env vars: {missing}")

    return VibeConfig(
        base_url=   os.environ["VIBE_API_BASE_URL"],
        identifier= os.environ["VIBE_AGENT_IDENTIFIER"],
        secret=     os.environ["VIBE_AGENT_SECRET"],
        chat_id=    os.getenv("VIBE_DESTINATION_CHAT_ID"),
        source=     os.getenv("VIBE_SOURCE", "backend"),
        timeout=    int(os.getenv("VIBE_TIMEOUT_SECONDS", "30")),
    )

config = load_config()`;

const invokeHelper = `// Minimal typed invoke helper — drop into your project
import { vibeConfig } from './config';

interface InvokeOptions {
  message: string;
  source?: string;
  responseMode?: 'reply' | 'send';
  vibeChatId?: string;
}

interface InvokeResult {
  success: boolean;
  invocationId: string;
  outputs: Array<{ type: string; text?: string; mediaUrl?: string }>;
}

export async function invokeAgent(opts: InvokeOptions): Promise<InvokeResult> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), vibeConfig.timeout * 1000);

  try {
    const resp = await fetch(
      \`\${vibeConfig.baseUrl}/api/agents/\${vibeConfig.identifier}/invoke\`,
      {
        method: 'POST',
        signal: controller.signal,
        headers: {
          'Content-Type': 'application/json',
          'X-Vibe-Agent-Secret': vibeConfig.secret,
        },
        body: JSON.stringify({
          message:      opts.message,
          source:       opts.source ?? vibeConfig.source,
          responseMode: opts.responseMode ?? 'reply',
          vibeChatId:   opts.vibeChatId,
        }),
      }
    );

    if (!resp.ok) {
      const err = await resp.json().catch(() => ({ error: resp.statusText }));
      throw new Error(\`Vibe invoke failed \${resp.status}: \${err.error}\`);
    }

    return resp.json();
  } finally {
    clearTimeout(timeout);
  }
}`;

const eventsHelper = `import os, requests
from typing import Any, Optional

config = load_config()  # from config module above

def post_event(
    event_id:   str,
    event_type: str,
    title:      str,
    text:       str,
    data:       dict[str, Any],
    thread_key: Optional[str] = None,
    chat_id:    Optional[str] = None,
) -> dict:
    payload = {
        "eventId":   event_id,
        "eventType": event_type,
        "source":    config.source,
        "title":     title,
        "text":      text,
        "data":      data,
    }
    if thread_key:
        payload["threadKey"] = thread_key
    if chat_id or config.chat_id:
        payload["destinationChatId"] = chat_id or config.chat_id

    resp = requests.post(
        f"{config.base_url}/api/agents/{config.identifier}/events",
        json=payload,
        headers={"X-Vibe-Agent-Secret": config.secret},
        timeout=config.timeout,
    )
    resp.raise_for_status()
    return resp.json()`;

export default function AgentEnvDocs() {
    return (
        <DocsShell
            eyebrow="Agents"
            title="Environment variables"
            intro="How to get the integration pack from the Vibe config panel, what each variable means, and how to load them safely in Node.js and Python backends."
            tabs={agentDocsTabs}
            sections={sections}
        >
            {/* ── Get env pack ──────────────────────────────────── */}
            <DocSection id="get-env">
                <DocH2>Get the env pack from the config panel</DocH2>
                <DocP>
                    The authoritative source for your env pack is the <strong>agent config panel</strong> in
                    Vibe. Never reconstruct the pack manually — the identifier and destination chat ID may change
                    if you rename the agent or reattach it.
                </DocP>

                <DocSteps items={[
                    {
                        title: 'Open the agent config panel',
                        body: 'In Vibe, tap the agent in your list → tap the settings icon → open the Config tab. On web, use the owner dashboard.',
                    },
                    {
                        title: 'Copy the integration pack',
                        body: 'Tap "Copy env pack" or "Copy integration" — this puts the full .env block on your clipboard with the correct VIBE_API_BASE_URL, VIBE_AGENT_IDENTIFIER, and VIBE_DESTINATION_CHAT_ID pre-filled.',
                    },
                    {
                        title: 'Copy the secret separately',
                        body: 'The secret is only shown right after create or rotate. If you missed it, tap "Rotate secret" to get a new one. Immediately paste it into your secrets manager.',
                    },
                    {
                        title: 'Paste into your .env or secrets manager',
                        body: 'Never commit the secret to source control. Use a secrets manager (Vault, AWS Secrets Manager, Railway variables, Doppler) or a .env file that is in .gitignore.',
                    },
                ]} />

                <DocCallout type="note">
                    The <code>VIBE_AGENT_IDENTIFIER</code> in the pack is always the UUID — you can also use your
                    agent's <code>@username</code> as the identifier if you prefer a stable human-readable value.
                    The server resolves both formats identically.
                </DocCallout>
            </DocSection>

            {/* ── Variables reference ───────────────────────────── */}
            <DocSection id="variables">
                <DocH2>Variables reference</DocH2>

                <DocParamTable params={[
                    {
                        name: 'VIBE_API_BASE_URL',
                        type: 'string',
                        required: true,
                        desc: 'Base origin of the Vibe API, e.g. "https://api.vibegram.io". No trailing slash. Do not append /api — the helpers do that. Copy from the integration pack.',
                    },
                    {
                        name: 'VIBE_AGENT_IDENTIFIER',
                        type: 'string',
                        required: true,
                        desc: 'UUID or @username of the published agent. Used as the :identifier path segment in /invoke and /events. Copy from the integration pack.',
                    },
                    {
                        name: 'VIBE_AGENT_SECRET',
                        type: 'string',
                        required: true,
                        desc: 'The current agent invoke/events secret. Prefix: vas_. Passed as X-Vibe-Agent-Secret on every external call. Rotate from the config panel if compromised.',
                    },
                    {
                        name: 'VIBE_DESTINATION_CHAT_ID',
                        type: 'string',
                        required: false,
                        desc: 'Vibe chat ID to post event messages into. Required for the /events endpoint when the agent has no default_destination_chat_id set. Optional otherwise.',
                    },
                    {
                        name: 'VIBE_INTEGRATION_SECRET',
                        type: 'string',
                        required: false,
                        desc: 'Per-integration secret (prefix: vas_) if using named integrations. Passed as X-Vibe-Integration-Secret. Allows the server to apply integration-specific autonomy and routing overrides.',
                    },
                    {
                        name: 'VIBE_SOURCE',
                        type: 'string',
                        required: false,
                        desc: 'Short producer label stored in each invocation record, e.g. "tradeai", "crm_sync", "ops_panel". Used for filtering and debugging in the owner delivery log. Defaults to "backend".',
                    },
                    {
                        name: 'VIBE_TIMEOUT_SECONDS',
                        type: 'integer',
                        required: false,
                        desc: 'HTTP client timeout in seconds. Invoke calls run full AI completions and may take 15–30 seconds on complex prompts. Events endpoint is typically faster. Default: 30.',
                    },
                ]} />
            </DocSection>

            {/* ── .env file ─────────────────────────────────────── */}
            <DocSection id="dotenv">
                <DocH2>Complete .env file</DocH2>
                <DocP>
                    A fully annotated <code>.env</code> file you can paste into your project. Remove the
                    optional lines you do not need.
                </DocP>
                <DocCodeBlock lang="bash" code={dotenvFull} />
                <DocCallout type="warning">
                    Add <code>.env</code> to your <code>.gitignore</code>. Never commit secrets to version
                    control — use environment-level secret injection in production (Railway, Render, Docker, etc.).
                </DocCallout>
            </DocSection>

            {/* ── Loading in code ───────────────────────────────── */}
            <DocSection id="loading">
                <DocH2>Loading env vars in your backend</DocH2>
                <DocP>
                    Both examples validate required variables at startup and export a typed config object.
                    They also include a minimal helper for invoke and events calls.
                </DocP>

                <DocH3>Config module</DocH3>
                <DocCodeTabs tabs={[
                    { label: 'TypeScript', code: loadNodeJs,  lang: 'typescript' },
                    { label: 'Python',     code: loadPython,  lang: 'python'     },
                ]} />

                <DocH3>Invoke helper</DocH3>
                <DocCodeBlock lang="typescript" code={invokeHelper} />

                <DocH3>Events helper</DocH3>
                <DocCodeBlock lang="python" code={eventsHelper} />
            </DocSection>

            {/* ── Destination chat ─────────────────────────────── */}
            <DocSection id="destination">
                <DocH2>Understanding the destination chat</DocH2>
                <DocP>
                    The destination chat controls where event messages appear in Vibe. There are two ways to
                    configure it — and they can be layered.
                </DocP>

                <DocParamTable params={[
                    {
                        name: 'Agent-level default',
                        type: 'config panel',
                        required: false,
                        desc: 'Set default_destination_chat_id in the agent config panel. All event ingestion calls that do not include a destinationChatId in the body will use this value. Recommended for single-source agents.',
                    },
                    {
                        name: 'Per-request override',
                        type: 'request body',
                        required: false,
                        desc: 'Pass destinationChatId in the event payload. Overrides the agent-level default for that call only. Useful for dynamic routing to different DMs or groups.',
                    },
                    {
                        name: 'Integration-level default',
                        type: 'integration config',
                        required: false,
                        desc: 'Each named integration can also have its own default_destination_chat_id. This overrides the agent-level default when the event arrives via that integration\'s secret.',
                    },
                ]} />

                <DocCallout type="tip">
                    The priority order is: <strong>per-request body</strong> &gt;{' '}
                    <strong>integration-level default</strong> &gt;{' '}
                    <strong>agent-level default</strong>. If none resolve, the server returns{' '}
                    <code>422 Missing destination chat</code>.
                </DocCallout>
            </DocSection>

            {/* ── Security practices ────────────────────────────── */}
            <DocSection id="security">
                <DocH2>Security practices</DocH2>

                <DocH3>Never log the secret</DocH3>
                <DocP>
                    The HMAC secret is the only thing between your agent and unauthenticated callers. Request
                    loggers that dump headers will expose it. Redact <code>X-Vibe-Agent-Secret</code> from all
                    log outputs and tracing spans.
                </DocP>

                <DocH3>Rotate when compromised</DocH3>
                <DocP>
                    If a secret is exposed, rotate it immediately from the config panel. The old value becomes
                    invalid the instant the rotation completes. Update all consumers before rotating in
                    production to avoid a brief outage — or update them in parallel with blue-green deployment.
                </DocP>

                <DocH3>Use HTTPS only</DocH3>
                <DocP>
                    The Vibe API only accepts HTTPS. The secret is sent in a plaintext header — non-TLS
                    transports will expose it. Your callback URL is also required to be HTTPS.
                </DocP>

                <DocH3>Verify callback signatures</DocH3>
                <DocP>
                    If you register a <code>callbackUrl</code>, always verify the{' '}
                    <code>X-Vibe-Agent-Signature</code> header before processing the payload. See the
                    Examples page for Node.js and Python verification code.
                </DocP>
            </DocSection>
        </DocsShell>
    );
}
