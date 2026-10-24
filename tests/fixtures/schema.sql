-- Generated from the LHStore migrator by SkillFixtureTests (LH_WRITE_FIXTURE=1). Do not edit.
CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
CREATE TABLE chat (
	id TEXT PRIMARY KEY NOT NULL,
	title TEXT NOT NULL,
	kind TEXT,
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL,
	settings_json TEXT,
	tree_json TEXT,
	origin TEXT NOT NULL DEFAULT 'native',
	version INTEGER
);
CREATE TABLE message (
	chat_id TEXT NOT NULL REFERENCES chat(id) ON DELETE CASCADE,
	seq INTEGER NOT NULL,
	id TEXT NOT NULL,
	role TEXT NOT NULL,
	custom_type TEXT,
	tool_call_id TEXT,
	tool_name TEXT,
	model TEXT,
	stop_reason TEXT,
	timestamp INTEGER NOT NULL,
	payload_json TEXT NOT NULL,
	details_json TEXT,
	usage_json TEXT,
	error_message TEXT,
	is_error INTEGER,
	display INTEGER,
	wire_ok INTEGER NOT NULL DEFAULT 1, stop_details_json TEXT,
	PRIMARY KEY (chat_id, seq)
);
CREATE UNIQUE INDEX message_chat_id ON message(chat_id, id);
CREATE TABLE message_ui (
	chat_id TEXT NOT NULL REFERENCES chat(id) ON DELETE CASCADE,
	message_id TEXT NOT NULL,
	inverted INTEGER NOT NULL,
	updated_at TEXT NOT NULL,
	PRIMARY KEY (chat_id, message_id)
);
CREATE VIRTUAL TABLE message_fts USING fts5(chat_id UNINDEXED, message_id UNINDEXED, body);
CREATE TABLE turn (
	id TEXT PRIMARY KEY NOT NULL,
	chat_id TEXT NOT NULL REFERENCES chat(id) ON DELETE CASCADE,
	seq INTEGER NOT NULL,
	message_id TEXT NOT NULL,
	at TEXT NOT NULL,
	model TEXT NOT NULL
);
CREATE INDEX turn_chat ON turn(chat_id, seq);
CREATE TABLE extraction_run (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	owner_kind TEXT NOT NULL,
	owner_id TEXT NOT NULL,
	seq INTEGER NOT NULL,
	started_at INTEGER NOT NULL,
	at TEXT NOT NULL,
	duration_ms INTEGER NOT NULL,
	stats_json TEXT,
	extractor_model TEXT NOT NULL,
	auditor_model TEXT NOT NULL,
	UNIQUE (owner_kind, owner_id, started_at)
);
CREATE TABLE usage_step (
	owner_kind TEXT NOT NULL,
	owner_id TEXT NOT NULL,
	step_index INTEGER NOT NULL,
	model TEXT NOT NULL,
	input_tokens INTEGER,
	output_tokens INTEGER,
	cache_read_tokens INTEGER,
	cache_write_tokens INTEGER,
	reasoning_tokens INTEGER,
	web_search_requests INTEGER,
	web_fetch_requests INTEGER,
	fallback_from TEXT, cache_write_1h_tokens INTEGER,
	PRIMARY KEY (owner_kind, owner_id, step_index)
);
CREATE TABLE job (
	id TEXT PRIMARY KEY NOT NULL,
	kind TEXT NOT NULL,
	chat_id TEXT NOT NULL,
	tool_call_id TEXT NOT NULL,
	status TEXT NOT NULL,
	activity TEXT NOT NULL,
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL,
	result_json TEXT,
	error TEXT,
	usage_json TEXT
);
CREATE INDEX job_chat ON job(chat_id);
CREATE TABLE steer_outbox (
	id TEXT PRIMARY KEY NOT NULL,
	chat_id TEXT NOT NULL,
	message_json TEXT NOT NULL,
	state TEXT NOT NULL,
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL
);
CREATE TABLE graph_node_line (
	seq INTEGER PRIMARY KEY AUTOINCREMENT,
	node_id TEXT NOT NULL,
	line_json TEXT NOT NULL
);
CREATE INDEX graph_node_line_id ON graph_node_line(node_id);
CREATE TABLE graph_chain_line (
	seq INTEGER PRIMARY KEY AUTOINCREMENT,
	chain_id TEXT NOT NULL,
	line_json TEXT NOT NULL
);
CREATE TABLE graph_session (
	seq INTEGER PRIMARY KEY AUTOINCREMENT,
	chat_id TEXT NOT NULL,
	line_json TEXT NOT NULL
);
CREATE TABLE coverage (
	seq INTEGER PRIMARY KEY AUTOINCREMENT,
	chat_id TEXT NOT NULL,
	fp TEXT NOT NULL,
	line_json TEXT NOT NULL
);
CREATE INDEX coverage_chat ON coverage(chat_id);
CREATE TABLE source (
	id TEXT PRIMARY KEY NOT NULL,
	seq INTEGER NOT NULL,
	file_path TEXT NOT NULL,
	imported_at TEXT NOT NULL,
	content_fp TEXT
);
CREATE TABLE node_position (
	node_id TEXT PRIMARY KEY NOT NULL,
	seq INTEGER NOT NULL,
	x REAL NOT NULL,
	y REAL NOT NULL
);
CREATE TABLE kv_settings (
	key TEXT PRIMARY KEY NOT NULL,
	value_json TEXT NOT NULL
);
CREATE TABLE prompt_override (
	segment_path TEXT PRIMARY KEY NOT NULL,
	body TEXT NOT NULL,
	updated_at TEXT NOT NULL
);
CREATE TABLE folder_bookmark (
	id TEXT PRIMARY KEY NOT NULL,
	path TEXT NOT NULL,
	bookmark BLOB NOT NULL,
	created_at TEXT NOT NULL
);
CREATE TABLE import_log (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	started_at TEXT NOT NULL,
	finished_at TEXT,
	source_path TEXT NOT NULL,
	counts_json TEXT,
	warnings_json TEXT
);
CREATE UNIQUE INDEX job_chat_tool_call ON job (chat_id, tool_call_id);
INSERT INTO grdb_migrations (identifier) VALUES ('v1');
INSERT INTO grdb_migrations (identifier) VALUES ('v2');
INSERT INTO grdb_migrations (identifier) VALUES ('v3');
