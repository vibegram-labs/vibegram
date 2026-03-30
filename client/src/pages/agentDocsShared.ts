export interface AgentDocsTab {
    label: string;
    path: string;
    description: string;
}

export const agentDocsTabs: AgentDocsTab[] = [
    {
        label: 'Overview',
        path: '/docs/agents',
        description: 'Create, publish, invoke, and send events to standalone agents.',
    },
    {
        label: 'Config',
        path: '/docs/agents/config',
        description: 'Identity, prompt, tools, delivery, and security fields.',
    },
    {
        label: 'Examples',
        path: '/docs/agents/examples',
        description: 'cURL, JavaScript, Python, and callback verification examples.',
    },
    {
        label: 'Env',
        path: '/docs/agents/env',
        description: 'How to get the env pack and what each variable means.',
    },
];
