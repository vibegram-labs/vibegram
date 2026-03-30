import DocsShell from '../components/docs/DocsShell';
import { agentDocsTabs } from './agentDocsShared';

const sections = [
    { id: 'overview', label: 'Overview' },
    { id: 'identity', label: 'Identity' },
    { id: 'behavior', label: 'Behavior' },
    { id: 'delivery', label: 'Delivery' },
    { id: 'security', label: 'Security' },
];

const configGroups = [
    {
        id: 'identity',
        title: 'Identity',
        rows: [
            ['display_name', 'Human-readable name shown in the home list, config panel, and notifications.'],
            ['username', 'Optional public `@handle` used as a stable invoke identifier when set.'],
            ['agent_id', 'Canonical internal id that always works in owner APIs and config operations.'],
            ['status', 'Draft, published, or archived state.'],
            ['prompt_status', 'Quick state for whether the prompt/config is complete enough to publish.'],
        ],
    },
    {
        id: 'behavior',
        title: 'Prompt & Behavior',
        rows: [
            ['system_prompt', 'The full instruction set that controls how the agent behaves.'],
            ['prompt_preview', 'Condensed summary used in cards and previews.'],
            ['enabled_tools', 'Registry tools the agent is allowed to call.'],
            ['output_modes', 'Allowed response types such as text, file, media, and voice.'],
            ['voice_profile', 'Voice preset used when voice output is enabled.'],
        ],
    },
    {
        id: 'delivery',
        title: 'Delivery & Inbox',
        rows: [
            ['default_destination_chat', 'Default Vibe destination for external events when a payload does not provide `destinationChatId`.'],
            ['attached_chats', 'Owner-visible chats already attached to the agent.'],
            ['approval_rules.event_inbox.mode', '`per_event` posts one bubble per event. `batched_summary` stores events and posts summaries on cadence.'],
            ['approval_rules.event_inbox.summary_window_hours', 'Summary cadence for batched mode. Current owner UI exposes 4h and daily.'],
            ['relatedMessageIds', 'Optional metadata returned with inbox-query answers so the main chat can jump to linked messages.'],
        ],
    },
    {
        id: 'security',
        title: 'Security & Integration',
        rows: [
            ['secret_hint', 'Suffix-only reference for the invoke secret when the full value stays hidden.'],
            ['latest_secret', 'Only exposed to the owner right after creation/rotation or via the authenticated secret endpoint.'],
            ['callback_url', 'Optional outbound webhook target for invocation and delivery updates.'],
            ['invoke_url', 'Direct execution endpoint for request-response workflows.'],
            ['events_url', 'Structured event ingestion endpoint for external notification streams.'],
        ],
    },
];

export default function AgentConfigDocs() {
    return (
        <DocsShell
            eyebrow="AGENT_CONFIG"
            title="Standalone agent config reference"
            intro="A field-by-field reference for the config model exposed across the builder, native owner panel, and external integration pack."
            tabs={agentDocsTabs}
            sections={sections}
        >
            <section className="docs-article-section" id="overview">
                <span className="section-label">OVERVIEW</span>
                <h2 className="docs-article-title">The same config model is shared across builder cards, native owner UI, and backend payloads.</h2>
                <p className="docs-article-copy">
                    This is the authoritative document for what the agent config actually contains. The native config
                    sheet, builder cards, and owner APIs should all line up with these fields rather than inventing
                    separate representations.
                </p>
            </section>

            {configGroups.map((group) => (
                <section className="docs-article-section" id={group.id} key={group.id}>
                    <span className="section-label">{group.title.toUpperCase().replace(/ & /g, '_')}</span>
                    <h2 className="docs-article-title">{group.title}</h2>
                    <div className="docs-table-card">
                        {group.rows.map(([label, description]) => (
                            <div className="docs-table-row docs-table-row-stack" key={label}>
                                <code>{label}</code>
                                <span>{description}</span>
                            </div>
                        ))}
                    </div>
                </section>
            ))}
        </DocsShell>
    );
}
