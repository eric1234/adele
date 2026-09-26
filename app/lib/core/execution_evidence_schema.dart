// Application-private execution owner baseline. Product remains at version 1.
const executionEvidenceSchema = '''
CREATE TABLE adele_execution_run_activity (
  run_id TEXT NOT NULL PRIMARY KEY REFERENCES adele_product_runs(id),
  latest_sequence INTEGER NOT NULL CHECK (latest_sequence >= 0),
  failure_kind TEXT,
  failure_message TEXT,
  failure_provider_code TEXT,
  failure_provider_details_json TEXT
);
CREATE TABLE adele_execution_run_lifecycle (
  run_id TEXT NOT NULL REFERENCES adele_execution_run_activity(run_id),
  sequence INTEGER NOT NULL CHECK (sequence >= 0),
  state TEXT NOT NULL,
  PRIMARY KEY (run_id, sequence)
);
CREATE TABLE adele_execution_model_invocations (
  run_id TEXT NOT NULL REFERENCES adele_execution_run_activity(run_id),
  invocation_id TEXT NOT NULL,
  start_sequence INTEGER NOT NULL CHECK (start_sequence >= 0),
  terminal_sequence INTEGER CHECK (terminal_sequence >= 0),
  settlement TEXT,
  incomplete_reason TEXT,
  metadata_present INTEGER NOT NULL CHECK (metadata_present IN (0, 1)),
  effective_model TEXT,
  provider_response_id TEXT,
  provider_request_id TEXT,
  provider_stop_reason TEXT,
  usage_present INTEGER NOT NULL CHECK (usage_present IN (0, 1)),
  input_tokens INTEGER CHECK (input_tokens >= 0),
  output_tokens INTEGER CHECK (output_tokens >= 0),
  cache_read_tokens INTEGER CHECK (cache_read_tokens >= 0),
  cache_write_tokens INTEGER CHECK (cache_write_tokens >= 0),
  usage_provider_details_json TEXT,
  native_state_kind TEXT,
  native_state_compatibility_json TEXT,
  native_state_data_json TEXT,
  failure_kind TEXT,
  failure_message TEXT,
  failure_provider_code TEXT,
  failure_provider_details_json TEXT,
  PRIMARY KEY (run_id, invocation_id),
  UNIQUE (run_id, start_sequence)
);
CREATE TABLE adele_execution_model_outputs (
  run_id TEXT NOT NULL,
  model_invocation_id TEXT NOT NULL,
  sequence INTEGER NOT NULL CHECK (sequence >= 0),
  kind TEXT NOT NULL CHECK (kind IN ('text', 'toolProposal', 'native')),
  text_content TEXT,
  provider_item_id TEXT,
  native_metadata_kind TEXT,
  native_metadata_compatibility_json TEXT,
  native_metadata_data_json TEXT,
  presentation_kind TEXT,
  presentation_compact_text TEXT,
  presentation_data_json TEXT,
  provider_call_id TEXT,
  alias TEXT,
  arguments_json TEXT,
  PRIMARY KEY (run_id, sequence),
  FOREIGN KEY (run_id, model_invocation_id)
    REFERENCES adele_execution_model_invocations(run_id, invocation_id)
);
CREATE TABLE adele_execution_tool_invocations (
  run_id TEXT NOT NULL REFERENCES adele_execution_run_activity(run_id),
  invocation_id TEXT NOT NULL,
  prepared_sequence INTEGER NOT NULL CHECK (prepared_sequence >= 0),
  model_invocation_id TEXT NOT NULL,
  proposal_sequence INTEGER NOT NULL CHECK (proposal_sequence >= 0),
  tool_id TEXT NOT NULL,
  alias TEXT NOT NULL,
  provider_call_id TEXT NOT NULL,
  canonical_arguments_json TEXT NOT NULL,
  PRIMARY KEY (run_id, invocation_id),
  UNIQUE (run_id, prepared_sequence),
  FOREIGN KEY (run_id, model_invocation_id)
    REFERENCES adele_execution_model_invocations(run_id, invocation_id),
  FOREIGN KEY (run_id, proposal_sequence)
    REFERENCES adele_execution_model_outputs(run_id, sequence)
);
CREATE TABLE adele_execution_tool_changes (
  run_id TEXT NOT NULL,
  tool_invocation_id TEXT NOT NULL,
  sequence INTEGER NOT NULL CHECK (sequence >= 0),
  kind TEXT NOT NULL,
  policy_decision TEXT,
  effects_json TEXT,
  interruption_id TEXT,
  approved INTEGER CHECK (approved IN (0, 1)),
  progress_kind TEXT,
  progress_content TEXT,
  outcome_disposition TEXT,
  failure_kind TEXT,
  effect_certainty TEXT,
  model_content TEXT,
  host_data_json TEXT,
  PRIMARY KEY (run_id, sequence),
  FOREIGN KEY (run_id, tool_invocation_id)
    REFERENCES adele_execution_tool_invocations(run_id, invocation_id)
);
CREATE TABLE adele_execution_rejected_proposals (
  run_id TEXT NOT NULL REFERENCES adele_execution_run_activity(run_id),
  sequence INTEGER NOT NULL CHECK (sequence >= 0),
  model_invocation_id TEXT NOT NULL,
  proposal_sequence INTEGER NOT NULL CHECK (proposal_sequence >= 0),
  provider_call_id TEXT NOT NULL,
  alias TEXT NOT NULL,
  arguments_json TEXT NOT NULL,
  failure_kind TEXT NOT NULL,
  message TEXT NOT NULL,
  PRIMARY KEY (run_id, sequence),
  FOREIGN KEY (run_id, model_invocation_id)
    REFERENCES adele_execution_model_invocations(run_id, invocation_id),
  FOREIGN KEY (run_id, proposal_sequence)
    REFERENCES adele_execution_model_outputs(run_id, sequence)
);
''';
