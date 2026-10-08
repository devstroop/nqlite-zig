//! Tool schemas, descriptions, handshake result and response goldens for
//! the MCP port — GENERATED from the reference `nql-mcp` (rmcp) server by
//! `capture_mcp_oracle.py` + this generator. Do not hand-edit; re-run the
//! capture when the reference tool surface changes.
//!
//! Wire note: schemas are JSON parsed by clients (key order is not part of
//! the contract), but keeping the reference's exact texts keeps `tools/list`
//! diffable against the oracle byte-for-byte.

/// initialize result — rmcp3.5.1 defaults (verbatim from the oracle).
pub const INITIALIZE_RESULT = "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"rmcp\",\"version\":\"3.5.1\"}}";

/// Tool order as the reference serves them (alphabetical).
pub const TOOL_ORDER = [_][]const u8{ "closure", "create_table", "execute_nql", "forget", "insert_record", "match_path", "relate", "select" };

/// `closure` — description (verbatim from the oracle).
pub const DESC_CLOSURE =
    "Transitive closure: every record reachable from a start record via the named edges (any number of hops, BFS to fixpoint), optional as_of = AS OF snapshot. Scored by BFS depth (0 = start).";

/// `closure` — inputSchema (verbatim from the oracle, compact JSON).
pub const SCHEMA_CLOSURE = "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"as_of\":{\"description\":\"Temporal read: traverse the store as of this logical timestamp\\n(`AS OF <int>` — history replayed to that point, spec §2.7; issue\\n#92). Absent = current state.\",\"format\":\"int64\",\"type\":[\"integer\",\"null\"]},\"start\":{\"description\":\"Start record id (`table:id`).\",\"type\":\"string\"},\"steps\":{\"description\":\"Path steps as JSON: `[{ \\\"direction\\\": \\\"out\\\"|\\\"in\\\", \\\"name\\\": \\\"mentions\\\" }, ...]`.\"}},\"required\":[\"start\",\"steps\"],\"type\":\"object\"}";

/// `create_table` — description (verbatim from the oracle).
pub const DESC_CREATE_TABLE =
    "Declare a table, optionally with VECTOR<f32, N> dimension for embeddings.";

/// `create_table` — inputSchema (verbatim from the oracle, compact JSON).
pub const SCHEMA_CREATE_TABLE = "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"table\":{\"description\":\"Table name.\",\"type\":\"string\"},\"vector_dim\":{\"description\":\"Optional fixed embedding dimension (`VECTOR<f32, N>`).\",\"format\":\"uint\",\"minimum\":0,\"type\":[\"integer\",\"null\"]}},\"required\":[\"table\"],\"type\":\"object\"}";

/// `execute_nql` — description (verbatim from the oracle).
pub const DESC_EXECUTE_NQL =
    "Run a full nql program (CREATE/INSERT/RELATE/SELECT/MATCH/CLOSURE/FORGET/MEMORY, ';'-separated) and return all result rows as JSON. Carries the complete grammar: AS OF time travel (SELECT, MATCH, CLOSURE), comparison/range filters (< <= > >= !=, IN, BETWEEN), id-pool predicates (WHERE id = / id IN [...]), COUNT(*) and OFFSET pagination, MATCH ... COUNT walk counts, PRUNE HISTORY compaction, HISTORY SINCE deltas, MEMORY blocks (prefix EVERY statement that belongs to a block — each program starts at root), edge-property filters, hybrid retrieval. Typed tools cover the root store (select and match/closure additionally support as_of; select also memory); use this tool for scoped writes and anything the typed tools don't expose.";

/// `execute_nql` — inputSchema (verbatim from the oracle, compact JSON).
pub const SCHEMA_EXECUTE_NQL = "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"program\":{\"description\":\"`;`-separated nql statements (CREATE/INSERT/RELATE/SELECT/MATCH/CLOSURE/FORGET).\",\"type\":\"string\"}},\"required\":[\"program\"],\"type\":\"object\"}";

/// `forget` — description (verbatim from the oracle).
pub const DESC_FORGET =
    "Delete a record (table:id) and every edge incident to it.";

/// `forget` — inputSchema (verbatim from the oracle, compact JSON).
pub const SCHEMA_FORGET = "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"id\":{\"description\":\"Record id in `table:id` form.\",\"type\":\"string\"}},\"required\":[\"id\"],\"type\":\"object\"}";

/// `insert_record` — description (verbatim from the oracle).
pub const DESC_INSERT_RECORD =
    "Insert or upsert a record. Embedding is BYO: pass a JSON array of numbers.";

/// `insert_record` — inputSchema (verbatim from the oracle, compact JSON).
pub const SCHEMA_INSERT_RECORD = "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"body\":{\"description\":\"Record body as a JSON object.\"},\"embedding\":{\"description\":\"Optional embedding as a JSON array of numbers.\"},\"id\":{\"description\":\"Record id in `table:id` form.\",\"type\":\"string\"}},\"required\":[\"id\",\"body\",\"embedding\"],\"type\":\"object\"}";

/// `match_path` — description (verbatim from the oracle).
pub const DESC_MATCH_PATH =
    "Walk a named-edge path from a start record (1+ hops, out/in, optional per-step edge-property filter, optional as_of = AS OF snapshot) and return the reached records.";

/// `match_path` — inputSchema (verbatim from the oracle, compact JSON).
pub const SCHEMA_MATCH_PATH = "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"as_of\":{\"description\":\"Temporal read: traverse the store as of this logical timestamp\\n(`AS OF <int>` — history replayed to that point, spec §2.7; issue\\n#92). Absent = current state.\",\"format\":\"int64\",\"type\":[\"integer\",\"null\"]},\"start\":{\"description\":\"Start record id (`table:id`).\",\"type\":\"string\"},\"steps\":{\"description\":\"Path steps as JSON: `[{ \\\"direction\\\": \\\"out\\\"|\\\"in\\\", \\\"name\\\": \\\"mentions\\\" }, ...]`.\"}},\"required\":[\"start\",\"steps\"],\"type\":\"object\"}";

/// `relate` — description (verbatim from the oracle).
pub const DESC_RELATE =
    "Create a directed, named edge (from) -> :name -> (to), with optional weight and properties.";

/// `relate` — inputSchema (verbatim from the oracle, compact JSON).
pub const SCHEMA_RELATE = "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"from\":{\"description\":\"Source record id (`table:id`).\",\"type\":\"string\"},\"name\":{\"description\":\"Edge name (with or without leading `:`).\",\"type\":\"string\"},\"props\":{\"description\":\"Optional edge properties as a JSON object.\"},\"to\":{\"description\":\"Target record id (`table:id`).\",\"type\":\"string\"},\"weight\":{\"description\":\"Optional edge weight (0..=1).\",\"format\":\"float\",\"type\":[\"number\",\"null\"]}},\"required\":[\"from\",\"name\",\"to\",\"props\"],\"type\":\"object\"}";

/// `select` — description (verbatim from the oracle).
pub const DESC_SELECT =
    "Scan a table, optionally filter by field equality, rank by kNN similarity, order, and limit. Supports temporal reads (as_of = logical timestamp, AS OF) and MEMORY-block reads (memory = block name). Returns rows as JSON in deterministic order.";

/// `select` — inputSchema (verbatim from the oracle, compact JSON).
pub const SCHEMA_SELECT = "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"properties\":{\"as_of\":{\"description\":\"Temporal read: execute against the store as of this logical timestamp\\n(`SELECT ... AS OF <int>` — replays the mutation history up to it).\\nOmit for current state.\",\"format\":\"int64\",\"type\":[\"integer\",\"null\"]},\"field\":{\"description\":\"Optional `WHERE <field> = <value>` (JSON scalar).\",\"type\":[\"string\",\"null\"]},\"k\":{\"description\":\"k for kNN when `query` is given.\",\"format\":\"uint\",\"minimum\":0,\"type\":[\"integer\",\"null\"]},\"limit\":{\"description\":\"Optional row cap.\",\"format\":\"uint\",\"minimum\":0,\"type\":[\"integer\",\"null\"]},\"memory\":{\"description\":\"Read inside a `MEMORY <name>` block (spec §2.8): rows come from that\\nblock's own sub-store (created lazily). Omit for the root store.\\nScoped *writes* go through `execute_nql` with a per-statement\\n`MEMORY <name>;` prefix (each line/program boundary starts at root).\",\"type\":[\"string\",\"null\"]},\"order_by\":{\"description\":\"Optional `ORDER BY ::<op>`: similarity | salience | score | votes | feedback | recency.\",\"type\":[\"string\",\"null\"]},\"query\":{\"description\":\"Optional kNN query vector (JSON array) — enables similarity ranking.\"},\"table\":{\"description\":\"Table to scan.\",\"type\":\"string\"},\"value\":{}},\"required\":[\"table\",\"value\",\"query\"],\"type\":\"object\"}";

/// `execute_nql` golden text (the aud program from exp09 mcp_parity).
pub const EXECUTE_NQL_GOLDEN = "[\n  {\n    \"kind\": \"SELECT aud\",\n    \"rows\": [\n      {\n        \"body\": {\n          \"text\": \"v1\"\n        },\n        \"id\": \"aud:1\",\n        \"score\": 0.0\n      }\n    ]\n  }\n]";

/// `select` golden text ({"table": "aud"} after the aud program).
pub const SELECT_GOLDEN = "{\n  \"rows\": [\n    {\n      \"body\": {\n        \"text\": \"v1\"\n      },\n      \"id\": \"aud:1\",\n      \"score\": 0.0\n    }\n  ]\n}";
