export type BuilderSetupStatus =
    | 'idle'
    | 'discovering'
    | 'clarifying'
    | 'assembling'
    | 'review_ready'
    | 'draft_created';

export type BuilderPhase = 'understand' | 'configure' | 'review';

export interface BuilderSetupState {
    status: BuilderSetupStatus;
    phase: BuilderPhase;
    summary?: string | null;
    confidence?: number | null;
}

export interface BuilderActivityItem {
    id: string;
    title: string;
    status: 'pending' | 'in_progress' | 'completed' | 'attention';
    detail?: string | null;
    agentLabel?: string | null;
    prompt?: string | null;
    parentId?: string | null;
    depth?: number | null;
}

export interface BuilderFieldOption {
    id: string;
    label: string;
    hint?: string | null;
}

interface BuilderUiFieldBase {
    key: string;
    label: string;
    required: boolean;
    value?: unknown;
}

export interface BuilderSingleSelectField extends BuilderUiFieldBase {
    type: 'single_select';
    options: BuilderFieldOption[];
    renderHint: 'chips' | 'tabs';
    allowCustom: boolean;
    placeholder?: string | null;
}

export interface BuilderMultiSelectField extends BuilderUiFieldBase {
    type: 'multi_select';
    options: BuilderFieldOption[];
    renderHint: 'chips' | 'tabs';
    allowCustom: boolean;
    placeholder?: string | null;
}

export interface BuilderTextField extends BuilderUiFieldBase {
    type: 'text' | 'long_text';
    placeholder?: string | null;
}

export interface BuilderChatPickerField extends BuilderUiFieldBase {
    type: 'chat_picker';
}

export type BuilderUiField =
    | BuilderSingleSelectField
    | BuilderMultiSelectField
    | BuilderTextField
    | BuilderChatPickerField;

export interface BuilderUiRequest {
    id: string;
    presentation: 'sheet';
    title: string;
    description?: string | null;
    submitLabel: string;
    allowSkip: boolean;
    fields: BuilderUiField[];
}

export interface BuilderReviewSection {
    id: 'identity' | 'behavior' | 'tools' | 'integrations' | 'autonomy' | 'tests' | string;
    title: string;
    summary: string;
    editable: boolean;
    requestId: string;
    fields: BuilderUiField[];
}

export interface BuilderUiResponsePayload {
    requestId: string;
    answers: Record<string, unknown>;
}
