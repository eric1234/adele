// Deliberate knowledge of the current product, Chat, and execution v1 schemas.
// These are selected diagnostic fields, not an arbitrary SQL export facility.
final class EvidenceTable {
  const EvidenceTable(
    this.name,
    this.key, {
    this.text = const [],
    this.nullableText = const [],
    this.integers = const [],
    this.nullableIntegers = const [],
    this.excluded = const [],
  });

  final String name;
  final String key;
  final List<String> text;
  final List<String> nullableText;
  final List<String> integers;
  final List<String> nullableIntegers;
  final List<String> excluded;

  List<String> get columns => [
    ...text,
    ...nullableText,
    ...integers,
    ...nullableIntegers,
  ];
}

const chatSessions = EvidenceTable(
  'adele_chat_sessions',
  'session_id',
  text: ['session_id', 'instructions'],
  integers: ['max_model_invocations', 'next_entry'],
  excluded: ['draft_request'],
);
const chatEntries = EvidenceTable(
  'adele_chat_entries',
  'sequence',
  text: ['session_id', 'entry_id', 'role', 'content'],
  nullableText: ['run_id'],
  integers: ['sequence'],
);
const productRuns = EvidenceTable(
  'adele_product_runs',
  'id',
  text: ['id', 'session_id', 'terminal_state'],
);
const executionTables = <String, EvidenceTable>{
  'root': EvidenceTable(
    'adele_execution_run_activity',
    'run_id',
    text: ['run_id'],
    integers: ['latest_sequence'],
    nullableText: [
      'failure_kind',
      'failure_message',
      'failure_provider_code',
      'failure_provider_details_json',
    ],
  ),
  'lifecycle': EvidenceTable(
    'adele_execution_run_lifecycle',
    'sequence',
    text: ['run_id', 'state'],
    integers: ['sequence'],
  ),
  'model_invocations': EvidenceTable(
    'adele_execution_model_invocations',
    'start_sequence',
    text: ['run_id', 'invocation_id'],
    integers: ['start_sequence', 'metadata_present', 'usage_present'],
    nullableIntegers: [
      'terminal_sequence',
      'input_tokens',
      'output_tokens',
      'cache_read_tokens',
      'cache_write_tokens',
    ],
    nullableText: [
      'settlement',
      'incomplete_reason',
      'effective_model',
      'provider_response_id',
      'provider_request_id',
      'provider_stop_reason',
      'usage_provider_details_json',
      'native_state_kind',
      'failure_kind',
      'failure_message',
      'failure_provider_code',
      'failure_provider_details_json',
    ],
    excluded: ['native_state_compatibility_json', 'native_state_data_json'],
  ),
  'model_outputs': EvidenceTable(
    'adele_execution_model_outputs',
    'sequence',
    text: ['run_id', 'model_invocation_id', 'kind'],
    integers: ['sequence'],
    nullableText: [
      'text_content',
      'provider_item_id',
      'native_metadata_kind',
      'presentation_kind',
      'presentation_compact_text',
      'presentation_data_json',
      'provider_call_id',
      'alias',
      'arguments_json',
    ],
    excluded: [
      'native_metadata_compatibility_json',
      'native_metadata_data_json',
    ],
  ),
  'tool_invocations': EvidenceTable(
    'adele_execution_tool_invocations',
    'prepared_sequence',
    text: [
      'run_id',
      'invocation_id',
      'model_invocation_id',
      'tool_id',
      'alias',
      'provider_call_id',
      'canonical_arguments_json',
    ],
    integers: ['prepared_sequence', 'proposal_sequence'],
  ),
  'tool_changes': EvidenceTable(
    'adele_execution_tool_changes',
    'sequence',
    text: ['run_id', 'tool_invocation_id', 'kind'],
    integers: ['sequence'],
    nullableIntegers: ['approved'],
    nullableText: [
      'policy_decision',
      'effects_json',
      'interruption_id',
      'progress_kind',
      'progress_content',
      'outcome_disposition',
      'failure_kind',
      'effect_certainty',
      'model_content',
      'host_data_json',
    ],
  ),
  'rejected_proposals': EvidenceTable(
    'adele_execution_rejected_proposals',
    'sequence',
    text: [
      'run_id',
      'model_invocation_id',
      'provider_call_id',
      'alias',
      'arguments_json',
      'failure_kind',
      'message',
    ],
    integers: ['sequence', 'proposal_sequence'],
  ),
};
