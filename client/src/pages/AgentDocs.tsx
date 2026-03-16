import { motion } from 'framer-motion';
import { Bot, FileText, Mic, TerminalSquare, Wand2, Webhook } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { Header } from '../components/layout/Header';
import './Home.css';
import './AgentDocs.css';

const FadeIn = ({ children, delay = 0 }: { children: React.ReactNode; delay?: number }) => (
    <motion.div
        initial={{ opacity: 0, y: 12 }}
        whileInView={{ opacity: 1, y: 0 }}
        viewport={{ once: true }}
        transition={{ duration: 0.7, delay, ease: [0.21, 0.45, 0.32, 0.9] }}
    >
        {children}
    </motion.div>
);

const invokeCurl = `curl -X POST "$VIBE_API/api/agents/agent_123/invoke" \\
  -H "Content-Type: application/json" \\
  -H "X-Vibe-Agent-Secret: vas_xxxxx" \\
  -d '{
    "source": "crm",
    "message": "Send today\\'s shipment summary",
    "responseMode": "reply"
  }'`;

const invokeJs = `const response = await fetch(\`\${API_BASE}/api/agents/\${agentId}/invoke\`, {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'X-Vibe-Agent-Secret': agentSecret,
  },
  body: JSON.stringify({
    source: 'support-panel',
    vibeChatId: chatId,
    message: 'Summarize the last file and send a voice note',
    responseMode: 'send',
  }),
});

const payload = await response.json();`;

const verifySignature = `import crypto from 'node:crypto';

const timestamp = req.header('x-vibe-agent-signature-timestamp') ?? '';
const signature = req.header('x-vibe-agent-signature') ?? '';
const rawBody = req.rawBody.toString('utf8');

const expected = crypto
  .createHmac('sha256', agentSecret)
  .update(\`\${timestamp}.\${rawBody}\`)
  .digest('hex');

const valid = crypto.timingSafeEqual(
  Buffer.from(signature),
  Buffer.from(expected),
);`;

const builderCommands = [
    '/newagent Freight Desk',
    '/username freight_ops',
    '/prompt Route operations requests to concise logistics actions.',
    '/tools search_google,create_document,edit_rows,export_rows',
    '/voice on alloy',
    '/webhook https://your-app.example/webhooks/vibe',
    '/publish',
];

const AgentDocs = () => {
    const navigate = useNavigate();

    return (
        <div className="landing-page luxury-light docs-page">
            <Header />

            <section className="docs-hero" id="overview">
                <div className="docs-hero-copy">
                    <FadeIn>
                        <span className="section-label">AGENTS_V1</span>
                        <h1 className="docs-title">Build agents that live inside Vibe, not beside it.</h1>
                        <p className="docs-subtitle">
                            Create a standalone agent with `@vibeagent`, give it a prompt, tools, voice, and a webhook,
                            then invoke it from your own backend or invite it directly into Vibe chats.
                        </p>
                        <div className="hero-cta-group">
                            <button className="luxe-button-primary" onClick={() => navigate('/app')}>
                                Open Vibe
                            </button>
                            <button
                                className="luxe-button-secondary"
                                onClick={() => document.getElementById('integrate')?.scrollIntoView({ behavior: 'smooth', block: 'start' })}
                            >
                                API Guide
                            </button>
                        </div>
                    </FadeIn>
                </div>

                <FadeIn delay={0.1}>
                    <div className="docs-hero-panel">
                        <div className="docs-status-row">
                            <span>agent_id</span>
                            <strong>agent_1234</strong>
                        </div>
                        <div className="docs-status-row">
                            <span>@username</span>
                            <strong>@freight_ops</strong>
                        </div>
                        <div className="docs-status-row">
                            <span>outputs</span>
                            <strong>text, file, voice</strong>
                        </div>
                        <div className="docs-status-row">
                            <span>auth</span>
                            <strong>secret + HMAC</strong>
                        </div>
                    </div>
                </FadeIn>
            </section>

            <section className="docs-card-grid">
                <FadeIn>
                    <article className="docs-card">
                        <Bot size={18} />
                        <h2>Create In Vibe</h2>
                        <p>Use `@vibeagent` to create the agent, reserve its global `@username`, and publish it.</p>
                    </article>
                </FadeIn>
                <FadeIn delay={0.05}>
                    <article className="docs-card">
                        <TerminalSquare size={18} />
                        <h2>Integrate From Code</h2>
                        <p>Call `POST /api/agents/:identifier/invoke` with the agent secret and get normalized outputs back.</p>
                    </article>
                </FadeIn>
                <FadeIn delay={0.1}>
                    <article className="docs-card">
                        <Wand2 size={18} />
                        <h2>Customize Behavior</h2>
                        <p>Control persona, system prompt, tools, callback URL, and voice output without BotFather-style setup friction.</p>
                    </article>
                </FadeIn>
            </section>

            <section className="docs-section" id="integrate">
                <div className="docs-section-head">
                    <span className="section-label">INTEGRATE</span>
                    <h2 className="section-title">Call your agent from any backend.</h2>
                    <p className="section-desc">
                        Every published agent exposes a signed invoke endpoint. Use `responseMode: "reply"` when your app wants the outputs
                        back directly, or `responseMode: "send"` when the agent should post inside an attached Vibe chat.
                    </p>
                </div>

                <div className="docs-code-grid">
                    <div className="docs-code-card">
                        <div className="docs-code-label">cURL</div>
                        <pre><code>{invokeCurl}</code></pre>
                    </div>
                    <div className="docs-code-card">
                        <div className="docs-code-label">JavaScript</div>
                        <pre><code>{invokeJs}</code></pre>
                    </div>
                </div>
            </section>

            <section className="docs-section docs-alt" id="customize">
                <div className="docs-section-head">
                    <span className="section-label">CUSTOMIZE</span>
                    <h2 className="section-title">Shape the agent with prompts, tools, and output modes.</h2>
                    <p className="section-desc">
                        The builder is chat-driven. Owners can configure the agent through natural language or explicit slash commands and publish
                        once the prompt, username, and output modes are ready.
                    </p>
                </div>

                <div className="docs-customize-grid">
                    <article className="docs-detail-card">
                        <FileText size={18} />
                        <h3>Builder Commands</h3>
                        <ul className="docs-command-list">
                            {builderCommands.map((command) => (
                                <li key={command}><code>{command}</code></li>
                            ))}
                        </ul>
                    </article>

                    <article className="docs-detail-card">
                        <Mic size={18} />
                        <h3>Output Types</h3>
                        <p>Agents can return normalized `text`, `image`, `file`, and `voice` outputs.</p>
                        <p>
                            Document tools can generate files directly. Voice mode uses the configured profile and returns a normal Vibe voice-note style message.
                        </p>
                    </article>
                </div>
            </section>

            <section className="docs-section" id="callbacks">
                <div className="docs-section-head">
                    <span className="section-label">CALLBACKS</span>
                    <h2 className="section-title">Verify outbound events with the same agent secret.</h2>
                    <p className="section-desc">
                        When `callbackUrl` is configured, Vibe signs outbound delivery events with{' '}
                        <code>{'hex(hmac_sha256(secret, "{timestamp}.{rawBody}"))'}</code>.
                        Verify the signature before processing the callback.
                    </p>
                </div>

                <div className="docs-callback-panel">
                    <div className="docs-callback-copy">
                        <Webhook size={18} />
                        <p>`agent.invocation.completed`, `agent.message.delivered`, and `agent.message.failed` are retried with exponential backoff.</p>
                    </div>
                    <div className="docs-code-card">
                        <div className="docs-code-label">Node Signature Check</div>
                        <pre><code>{verifySignature}</code></pre>
                    </div>
                </div>
            </section>

            <footer className="luxe-footer docs-footer">
                <div className="footer-inner">
                    <div className="footer-top">
                        <span className="logo-small">vibe</span>
                        <div className="footer-nav">
                            <a href="#overview">Overview</a>
                            <a href="#integrate">Integrate</a>
                            <a href="#customize">Customize</a>
                        </div>
                    </div>
                    <div className="footer-bottom">
                        <span>Standalone agents for Vibe chat, external apps, and signed delivery flows.</span>
                        <span>AGENTS_V1</span>
                    </div>
                </div>
            </footer>
        </div>
    );
};

export default AgentDocs;
