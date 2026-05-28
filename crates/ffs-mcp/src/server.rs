//! ffs MCP server — tool definitions and handlers.
//!
//! Uses the `rmcp` crate's `#[tool_router]` / `#[tool_handler]` macros
//! for declarative tool registration. Each tool method directly calls
//! `ffs-core` APIs (no C FFI overhead).

use std::borrow::Cow;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use crate::cursor::CursorStore;
use crate::engine_tools::{
    EngineCallParams, EngineDepsParams, EngineDispatchParams, EngineFlowParams, EngineHolder,
    EngineImpactParams, EngineMapParams, EngineOutlineParams, EngineOverviewParams,
    EngineReadParams, EngineRefsParams, EngineSiblingsParams, EngineSymbolParams,
};
use crate::output::{GrepFormatter, OutputMode, file_suffix};
use ffs::PaginationArgs;
use ffs::grep::{GrepMode, GrepSearchOptions, has_regex_metacharacters};
use ffs::types::{FileItem, MixedItemRef};
use ffs::{FuzzySearchOptions, QueryParser, SharedFilePicker, SharedFrecency};
use ffs_query_parser::AiGrepConfig;
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::*;
use rmcp::{ServerHandler, schemars, tool, tool_handler, tool_router};

/// Normalize the caller-supplied `maxResults`.
///
/// `None`, `Some(0)`, and non-positive / non-finite values fall back to
/// `default`. Issue #400 reported that ffs_grep returned 0 items for
/// `maxResults: 0` while `ffs_find` returned the entire dataset; treating
/// 0 as "use the default" makes both tools behave consistently.
fn normalize_max_results(raw: Option<f64>, default: usize) -> usize {
    match raw {
        None => default,
        Some(v) if v <= 0.0 || !v.is_finite() => default,
        Some(v) => (v.round() as usize).max(1),
    }
}

fn cleanup_fuzzy_query(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if !matches!(c, ':' | '-' | '_') {
            out.extend(c.to_lowercase());
        }
    }
    out
}

fn make_grep_options(
    output_mode: OutputMode,
    mode: GrepMode,
    file_offset: usize,
    context: Option<usize>,
) -> (GrepSearchOptions, bool) {
    let is_usage = output_mode == OutputMode::Usage;
    let matches_per_file = match output_mode {
        OutputMode::FilesWithMatches => 1,
        _ if is_usage => 8,
        _ => 10,
    };
    let ctx_lines = if is_usage {
        context.unwrap_or(1)
    } else {
        context.unwrap_or(0)
    };
    let auto_expand = !is_usage && ctx_lines == 0;
    let after_ctx = if auto_expand { 8 } else { ctx_lines };

    (
        GrepSearchOptions {
            max_file_size: 10 * 1024 * 1024,
            max_matches_per_file: matches_per_file,
            smart_case: true,
            file_offset,
            page_limit: 50,
            mode,
            time_budget_ms: 0,
            before_context: ctx_lines,
            after_context: after_ctx,
            classify_definitions: true,
            trim_whitespace: true,
            abort_signal: None,
        },
        auto_expand,
    )
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct FindFilesParams {
    /// Fuzzy search query. Supports path prefixes and glob constraints.
    // `pattern` alias for consistency with ffs_grep's alias and the common
    // file-search parameter name (#311).
    #[serde(alias = "pattern")]
    pub query: String,
    /// Max results (default 20).
    #[serde(rename = "maxResults")]
    // this has to be float because llms are stupid
    pub max_results: Option<f64>,
    /// Cursor from previous result. Only use if previous results weren't sufficient.
    pub cursor: Option<String>,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct FindDirsParams {
    /// Fuzzy search query for directory names.
    #[serde(alias = "pattern")]
    pub query: String,
    /// Max results (default 20).
    #[serde(rename = "maxResults")]
    pub max_results: Option<f64>,
    /// Cursor from previous result.
    pub cursor: Option<String>,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct FindMixedParams {
    /// Fuzzy search query for files AND directories.
    #[serde(alias = "pattern")]
    pub query: String,
    /// Max results (default 20).
    #[serde(rename = "maxResults")]
    pub max_results: Option<f64>,
    /// Cursor from previous result.
    pub cursor: Option<String>,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct GrepParams {
    /// Search text or regex query with optional constraint prefixes.
    /// Matches within single lines only — use ONE specific term, not multiple words.
    // `pattern` alias: LLMs that have seen ffs_multi_grep (which uses `patterns`)
    // routinely call ffs_grep with `pattern`; accept it instead of erroring out
    // with an unhelpful "missing field `query`" (#311).
    #[serde(alias = "pattern")]
    pub query: String,
    /// Max matching lines (default 20).
    #[serde(rename = "maxResults")]
    pub max_results: Option<f64>, // this has to be float because llms are stupid
    /// Cursor from previous result. Only use if previous results weren't sufficient.
    pub cursor: Option<String>,
    /// Output format (default 'content').
    pub output_mode: Option<String>,
}

fn deserialize_patterns<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de;

    struct PatternsVisitor;

    impl<'de> de::Visitor<'de> for PatternsVisitor {
        type Value = Vec<String>;

        fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
            formatter.write_str("a string, an array of strings, or a stringified JSON array")
        }

        fn visit_str<E: de::Error>(self, v: &str) -> Result<Self::Value, E> {
            // Try to parse as JSON array first
            if v.starts_with('[')
                && let Ok(parsed) = serde_json::from_str::<Vec<String>>(v)
            {
                return Ok(parsed);
            }
            Ok(vec![v.to_string()])
        }

        fn visit_string<E: de::Error>(self, v: String) -> Result<Self::Value, E> {
            if v.starts_with('[')
                && let Ok(parsed) = serde_json::from_str::<Vec<String>>(&v)
            {
                return Ok(parsed);
            }
            Ok(vec![v])
        }

        fn visit_seq<A: de::SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
            let mut values = Vec::new();
            while let Some(value) = seq.next_element::<String>()? {
                values.push(value);
            }
            Ok(values)
        }
    }

    deserializer.deserialize_any(PatternsVisitor)
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct MultiGrepParams {
    /// Patterns to match (OR logic). Include all naming conventions: snake_case, PascalCase, camelCase.
    #[serde(deserialize_with = "deserialize_patterns")]
    pub patterns: Vec<String>,
    /// File constraints (e.g. '*.{ts,tsx} !test/'). ALWAYS provide when possible.
    pub constraints: Option<String>,
    /// Max matching lines (default 20).
    #[serde(rename = "maxResults")]
    pub max_results: Option<f64>,
    /// Cursor from previous result.
    pub cursor: Option<String>,
    /// Output format (default 'content').
    pub output_mode: Option<String>,
    /// Context lines before/after each match.
    pub context: Option<f64>,
}

#[derive(Clone)]
pub struct FfsServer {
    picker: SharedFilePicker,
    #[allow(dead_code)]
    frecency: SharedFrecency,
    cursor_store: Arc<Mutex<CursorStore>>,
    update_notice_sent: Arc<AtomicBool>,
    engine: Arc<EngineHolder>,
    tool_router: ToolRouter<Self>,
}

impl FfsServer {
    pub fn new(picker: SharedFilePicker, frecency: SharedFrecency) -> Self {
        Self {
            picker,
            frecency,
            cursor_store: Arc::new(Mutex::new(CursorStore::new())),
            update_notice_sent: Arc::new(AtomicBool::new(false)),
            engine: Arc::new(EngineHolder::new()),
            tool_router: Self::tool_router(),
        }
    }

    /// Resolve the repository root from the picker's base path.
    fn picker_base_path(&self) -> Result<std::path::PathBuf, ErrorData> {
        let guard = self.picker.read().map_err(|e| {
            ErrorData::internal_error(format!("Failed to acquire picker lock: {e}"), None)
        })?;
        let picker = guard
            .as_ref()
            .ok_or_else(|| ErrorData::internal_error("File picker not initialized", None))?;
        Ok(picker.base_path().to_path_buf())
    }

    #[allow(dead_code)]
    pub fn wait_for_scan(&self) {
        loop {
            let guard = self.picker.read().ok();
            let is_scanning = guard
                .as_ref()
                .and_then(|g| g.as_ref())
                .map(|p| p.is_scan_active())
                .unwrap_or(true);

            if !is_scanning {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }

    fn lock_cursors(&self) -> Result<std::sync::MutexGuard<'_, CursorStore>, ErrorData> {
        self.cursor_store.lock().map_err(|e| {
            ErrorData::internal_error(format!("Failed to acquire cursor store lock: {e}"), None)
        })
    }

    fn maybe_append_update_notice(&self, result: &mut CallToolResult) {
        if self.update_notice_sent.swap(true, Ordering::Relaxed) {
            return;
        }
        let notice = crate::update_check::get_update_notice();
        if notice.is_empty() {
            // Reset so the next call can try again (check may still be in flight)
            self.update_notice_sent.store(false, Ordering::Relaxed);
            return;
        }
        result.content.push(Content::text(notice));
    }

    fn perform_grep(
        &self,
        query: &str,
        mode: GrepMode,
        max_results: usize,
        cursor_id: Option<&str>,
        output_mode: OutputMode,
        context: Option<usize>,
    ) -> Result<CallToolResult, ErrorData> {
        let file_offset = cursor_id
            .and_then(|id| self.cursor_store.lock().ok()?.get(id))
            .unwrap_or(0);

        let (options, auto_expand) = make_grep_options(output_mode, mode, file_offset, context);
        let ctx_lines = options.before_context;

        // Acquire picker lock once for the entire operation.
        let guard = self.picker.read().map_err(|e| {
            ErrorData::internal_error(format!("Failed to acquire picker lock: {e}"), None)
        })?;
        let picker = guard
            .as_ref()
            .ok_or_else(|| ErrorData::internal_error("File picker not initialized", None))?;

        let parser = QueryParser::new(AiGrepConfig);
        let parsed = parser.parse(query);
        let result = picker.grep(&parsed, &options);

        if result.matches.is_empty() && file_offset == 0 {
            // Auto-retry: try broadening multi-word queries by dropping first non-constraint word
            let parts: Vec<&str> = query.split_whitespace().collect();
            if parts.len() >= 2 {
                let first_word = parts[0];
                let is_valid_constraint = first_word.starts_with('!')
                    || first_word.starts_with('*')
                    || first_word.ends_with('/');

                if !is_valid_constraint {
                    let rest_query = parts[1..].join(" ");
                    let rest_parsed = parser.parse(&rest_query);

                    let rest_text = rest_parsed.grep_text();
                    let retry_mode = if has_regex_metacharacters(&rest_text) {
                        GrepMode::Regex
                    } else {
                        mode
                    };

                    let (retry_options, _) = make_grep_options(output_mode, retry_mode, 0, context);
                    let retry_result = picker.grep(&rest_parsed, &retry_options);

                    if !retry_result.matches.is_empty() && retry_result.matches.len() <= 10 {
                        let mut cs = self.lock_cursors()?;
                        let text = &GrepFormatter {
                            matches: &retry_result.matches,
                            files: &retry_result.files,
                            total_matched: retry_result.matches.len(),
                            next_file_offset: retry_result.next_file_offset,
                            output_mode,
                            max_results,
                            show_context: ctx_lines > 0,
                            auto_expand_defs: auto_expand,
                            picker,
                        }
                        .format(&mut cs);
                        return Ok(CallToolResult::success(vec![Content::text(format!(
                            "0 matches for '{}'. Auto-broadened to '{}':\n{}",
                            query, rest_query, text
                        ))]));
                    }
                }
            }

            // Fuzzy fallback for typo tolerance
            let fuzzy_query = cleanup_fuzzy_query(query);
            let (fuzzy_options, _) = make_grep_options(output_mode, GrepMode::Fuzzy, 0, Some(0));
            let fuzzy_parsed = parser.parse(&fuzzy_query);
            let fuzzy_result = picker.grep(&fuzzy_parsed, &fuzzy_options);

            if !fuzzy_result.matches.is_empty() {
                let mut lines: Vec<String> = Vec::new();
                lines.push(format!(
                    "0 exact matches. {} approximate:",
                    fuzzy_result.matches.len()
                ));
                let mut current_file = String::new();
                for m in fuzzy_result.matches.iter().take(3) {
                    let file = fuzzy_result.files[m.file_index];
                    let file_rel = file.relative_path(picker);
                    if file_rel != current_file {
                        current_file = file_rel;
                        lines.push(current_file.to_string());
                    }
                    lines.push(format!(" {}: {}", m.line_number, m.line_content));
                }
                return Ok(CallToolResult::success(vec![Content::text(
                    lines.join("\n"),
                )]));
            }

            // File path fallback: if query looks like a path, suggest the matching file
            if query.contains('/') {
                let file_parser = QueryParser::default();
                let file_query = file_parser.parse(query);
                let file_opts = FuzzySearchOptions {
                    max_threads: 0,
                    current_file: None,
                    project_path: Some(picker.base_path()),
                    combo_boost_score_multiplier: 100,
                    min_combo_count: 3,
                    pagination: PaginationArgs {
                        offset: 0,
                        limit: 1,
                    },
                };
                let file_result = picker.fuzzy_search(&file_query, None, file_opts);
                if let (Some(top), Some(score)) =
                    (file_result.items.first(), file_result.scores.first())
                {
                    // Only suggest when the match is strong enough.
                    let query_len = query.len() as i32;
                    if score.base_score > query_len * 10 {
                        return Ok(CallToolResult::success(vec![Content::text(format!(
                            "0 content matches. But there is a relevant file path: {}",
                            top.relative_path(picker)
                        ))]));
                    }
                }
            }

            return Ok(CallToolResult::success(vec![Content::text(
                "0 matches.".to_string(),
            )]));
        }

        if result.matches.is_empty() {
            return Ok(CallToolResult::success(vec![Content::text(
                "0 matches.".to_string(),
            )]));
        }

        let mut cs = self.lock_cursors()?;
        let text = &GrepFormatter {
            matches: &result.matches,
            files: &result.files,
            total_matched: result.matches.len(),
            next_file_offset: result.next_file_offset,
            output_mode,
            max_results,
            show_context: ctx_lines > 0,
            auto_expand_defs: auto_expand,
            picker,
        }
        .format(&mut cs);

        Ok(CallToolResult::success(vec![Content::text(text)]))
    }
}

#[tool_router]
impl FfsServer {
    /// Fuzzy file search by name. Searches FILE NAMES, not file contents.
    /// Use it when you need to find a file, not a definition.
    /// Use ffs_grep instead for searching code content (definitions, usage patterns).
    /// Supports fuzzy matching, path prefixes ('shc/'), and glob constraints.
    /// IMPORTANT: Keep queries SHORT — prefer 1-2 terms max.
    #[tool(
        name = "ffs_find",
        description = "Fuzzy file search by name. Searches FILE NAMES, not file contents. Use it when you need to find a file, not a definition. Use ffs_grep instead for searching code content (definitions, usage patterns). Supports fuzzy matching, path prefixes ('src/'), and glob constraints ('name **/src/*.{ts,tsx} !test/'). IMPORTANT: Keep queries SHORT — prefer 1-2 terms max. Multiple words are a waterfall (each narrows results), NOT OR. If unsure, start broad with 1 term and refine."
    )]
    fn ffs_find(
        &self,
        Parameters(params): Parameters<FindFilesParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let max_results = normalize_max_results(params.max_results, 20);
        let query = &params.query;

        let page_offset = params
            .cursor
            .as_deref()
            .and_then(|id| self.cursor_store.lock().ok()?.get(id))
            .unwrap_or(0);

        let guard = self.picker.read().map_err(|e| {
            ErrorData::internal_error(format!("Failed to acquire picker lock: {e}"), None)
        })?;
        let picker = guard
            .as_ref()
            .ok_or_else(|| ErrorData::internal_error("File picker not initialized", None))?;
        let base_path = picker.base_path();
        let make_opts = |offset: usize| FuzzySearchOptions {
            max_threads: 0,
            current_file: None,
            project_path: Some(base_path),
            combo_boost_score_multiplier: 100,
            min_combo_count: 3,
            pagination: PaginationArgs {
                offset,
                limit: max_results,
            },
        };

        let parser = QueryParser::default();
        let ffs_query = parser.parse(query);
        let result = picker.fuzzy_search(&ffs_query, None, make_opts(page_offset));
        let total_files = result.total_files;

        // Auto-retry with fewer terms if 3+ words return 0 results
        let words: Vec<&str> = query.split_whitespace().collect();
        let shorter = words.get(..2).map(|w| w.join(" "));

        let (items, scores, total_matched) =
            if result.items.is_empty() && words.len() >= 3 && page_offset == 0 {
                if let Some(shorter) = &shorter {
                    let shorter_query = parser.parse(shorter);
                    let retry = picker.fuzzy_search(&shorter_query, None, make_opts(0));

                    (retry.items, retry.scores, retry.total_matched)
                } else {
                    (result.items, result.scores, result.total_matched)
                }
            } else {
                (result.items, result.scores, result.total_matched)
            };

        if items.is_empty() {
            return Ok(CallToolResult::success(vec![Content::text(format!(
                "0 results ({} indexed)",
                total_files
            ))]));
        }

        let mut lines: Vec<String> = Vec::new();
        let top_item = items[0];
        let is_exact_match = scores[0].exact_match;

        if page_offset == 0 {
            if is_exact_match {
                lines.push(format!(
                    "→ Read {} (exact match!)",
                    top_item.relative_path(picker)
                ));
            } else if scores.len() < 2 || scores[0].total > scores[1].total.saturating_mul(2) {
                lines.push(format!(
                    "→ Read {} (best match — Read this file directly)",
                    top_item.relative_path(picker)
                ));
            }
        }

        let next_offset = page_offset + items.len();
        let has_more = next_offset < total_matched;

        if has_more {
            lines.push(format!("{}/{} matches", items.len(), total_matched));
        }

        for item in &items {
            lines.push(format!(
                "{}{}",
                item.relative_path(picker),
                file_suffix(item.git_status, item.total_frecency_score())
            ));
        }

        if has_more {
            let mut cs = self.lock_cursors()?;
            let cursor_id = cs.store(next_offset);
            lines.push(format!("cursor: {}", cursor_id));
        }

        let mut result = CallToolResult::success(vec![Content::text(lines.join("\n"))]);
        self.maybe_append_update_notice(&mut result);
        Ok(result)
    }

    /// Fuzzy directory search by name. Searches DIRECTORY names, not file contents.
    #[tool(
        name = "ffs_find_dirs",
        description = "Fuzzy directory search by name. Searches DIRECTORY names only. Use ffs_find for files, ffs_find_mixed for both. Supports fuzzy matching and path prefixes ('src/'). Returns directories ranked by match quality and frecency."
    )]
    fn ffs_find_dirs(
        &self,
        Parameters(params): Parameters<FindDirsParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let max_results = normalize_max_results(params.max_results, 20);

        let page_offset = params
            .cursor
            .as_deref()
            .and_then(|id| self.cursor_store.lock().ok()?.get(id))
            .unwrap_or(0);

        let guard = self.picker.read().map_err(|e| {
            ErrorData::internal_error(format!("Failed to acquire picker lock: {e}"), None)
        })?;
        let picker = guard
            .as_ref()
            .ok_or_else(|| ErrorData::internal_error("File picker not initialized", None))?;
        let base_path = picker.base_path();

        let parser = QueryParser::default();
        let ffs_query = parser.parse(&params.query);
        let opts = FuzzySearchOptions {
            max_threads: 0,
            current_file: None,
            project_path: Some(base_path),
            combo_boost_score_multiplier: 0,
            min_combo_count: 0,
            pagination: PaginationArgs {
                offset: page_offset,
                limit: max_results,
            },
        };

        let result = picker.fuzzy_search_directories(&ffs_query, opts);
        let total_dirs = result.total_dirs;

        if result.items.is_empty() {
            return Ok(CallToolResult::success(vec![Content::text(format!(
                "0 directory results ({} indexed dirs)",
                total_dirs
            ))]));
        }

        let mut lines: Vec<String> = Vec::new();
        let next_offset = page_offset + result.items.len();
        let has_more = next_offset < result.total_matched;

        if has_more {
            lines.push(format!(
                "{}/{} matches",
                result.items.len(),
                result.total_matched
            ));
        }

        for dir in &result.items {
            let path = dir.relative_path(picker);
            let trimmed = path.trim_end_matches('/');
            lines.push(format!("{}/", trimmed));
        }

        if has_more {
            let mut cs = self.lock_cursors()?;
            let cursor_id = cs.store(next_offset);
            lines.push(format!("cursor: {}", cursor_id));
        }

        let mut out = CallToolResult::success(vec![Content::text(lines.join("\n"))]);
        self.maybe_append_update_notice(&mut out);
        Ok(out)
    }

    /// Fuzzy search across both files and directories, merged by score.
    #[tool(
        name = "ffs_find_mixed",
        description = "Fuzzy search across both files AND directories, merged and ranked by score. Use ffs_find for files only, ffs_find_dirs for directories only. Trailing '/' in query restricts to directories."
    )]
    fn ffs_find_mixed(
        &self,
        Parameters(params): Parameters<FindMixedParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let max_results = normalize_max_results(params.max_results, 20);

        let page_offset = params
            .cursor
            .as_deref()
            .and_then(|id| self.cursor_store.lock().ok()?.get(id))
            .unwrap_or(0);

        let guard = self.picker.read().map_err(|e| {
            ErrorData::internal_error(format!("Failed to acquire picker lock: {e}"), None)
        })?;
        let picker = guard
            .as_ref()
            .ok_or_else(|| ErrorData::internal_error("File picker not initialized", None))?;
        let base_path = picker.base_path();

        let parser = QueryParser::default();
        let ffs_query = parser.parse(&params.query);
        let opts = FuzzySearchOptions {
            max_threads: 0,
            current_file: None,
            project_path: Some(base_path),
            combo_boost_score_multiplier: 100,
            min_combo_count: 3,
            pagination: PaginationArgs {
                offset: page_offset,
                limit: max_results,
            },
        };

        let result = picker.fuzzy_search_mixed(&ffs_query, None, opts);

        if result.items.is_empty() {
            return Ok(CallToolResult::success(vec![Content::text(format!(
                "0 results ({} files, {} dirs)",
                result.total_files, result.total_dirs
            ))]));
        }

        let mut lines: Vec<String> = Vec::new();
        let next_offset = page_offset + result.items.len();
        let has_more = next_offset < result.total_matched;

        if has_more {
            lines.push(format!(
                "{}/{} matches",
                result.items.len(),
                result.total_matched
            ));
        }

        for item in &result.items {
            match item {
                MixedItemRef::File(f) => {
                    lines.push(format!(
                        "{}{}",
                        f.relative_path(picker),
                        file_suffix(f.git_status, f.total_frecency_score())
                    ));
                }
                MixedItemRef::Dir(d) => {
                    let path = d.relative_path(picker);
                    let trimmed = path.trim_end_matches('/');
                    lines.push(format!("{}/", trimmed));
                }
            }
        }

        if has_more {
            let mut cs = self.lock_cursors()?;
            let cursor_id = cs.store(next_offset);
            lines.push(format!("cursor: {}", cursor_id));
        }

        let mut out = CallToolResult::success(vec![Content::text(lines.join("\n"))]);
        self.maybe_append_update_notice(&mut out);
        Ok(out)
    }

    /// Search file contents for text patterns. This is the DEFAULT search tool.
    /// Prefer plain text over regex. Filter files with constraints.
    #[tool(
        name = "ffs_grep",
        description = "Search file contents. Search for bare identifiers (e.g. 'InProgressQuote', 'ActorAuth'), NOT code syntax or regex. Filter files with constraints (e.g. '*.rs query', 'src/ query'). Use filename, directory (ending with /) or glob expressions to prefilter. See server instructions for constraint syntax and core rules."
    )]
    fn grep(
        &self,
        Parameters(params): Parameters<GrepParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let max_results = normalize_max_results(params.max_results, 20);
        let output_mode = OutputMode::new(params.output_mode.as_deref());

        let parsed = QueryParser::new(AiGrepConfig).parse(&params.query);
        let grep_text = parsed.grep_text();

        let mode = if has_regex_metacharacters(&grep_text) {
            GrepMode::Regex
        } else {
            GrepMode::PlainText
        };

        let mut result = self.perform_grep(
            &params.query,
            mode,
            max_results,
            params.cursor.as_deref(),
            output_mode,
            None,
        )?;
        self.maybe_append_update_notice(&mut result);
        Ok(result)
    }

    /// Search file contents for lines matching ANY of multiple patterns (OR logic).
    /// Patterns are literal text — NEVER escape special characters.
    #[tool(
        name = "ffs_multi_grep",
        description = "Search file contents for lines matching ANY of multiple patterns (OR logic). IMPORTANT: This returns files where ANY query matches, NOT all patterns. Patterns are literal text — NEVER escape special characters (no \\( \\) \\. etc). Faster than regex alternation for literal text. See server instructions for constraint syntax."
    )]
    fn ffs_multi_grep(
        &self,
        Parameters(params): Parameters<MultiGrepParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let mut result = self.multi_grep_inner(params)?;
        self.maybe_append_update_notice(&mut result);
        Ok(result)
    }

    #[tool(
        name = "ffs_dispatch",
        description = "Auto-classify a free-form query (file path, glob, identifier, or concept phrase) and route it through the engine. Use when you don't know whether the input is a file, a symbol, or a content query."
    )]
    fn engine_dispatch(
        &self,
        Parameters(params): Parameters<EngineDispatchParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let root = self.picker_base_path()?;
        let max_tokens = normalize_max_results(params.max_tokens, 25_000) as u64;
        let _max_results = normalize_max_results(params.max_results, 50);
        let engine = self.engine.get_or_build(&root, max_tokens);
        let result = engine.dispatch(&params.query, &root);
        let text = crate::engine_tools::format_dispatch(&result);
        Ok(CallToolResult::success(vec![Content::text(text)]))
    }

    #[tool(
        name = "ffs_symbol",
        description = "Look up a symbol definition by exact name (or by prefix when the name ends with '*'). Backed by the tree-sitter symbol index over 16 languages."
    )]
    fn engine_symbol(
        &self,
        Parameters(params): Parameters<EngineSymbolParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let root = self.picker_base_path()?;
        let max_results = normalize_max_results(params.max_results, 50);
        let engine = self.engine.get_or_build(&root, 25_000);
        let name = params.name.trim();
        let text = if let Some(prefix) = name.strip_suffix('*') {
            let mut hits = engine.handles.symbols.lookup_prefix(prefix);
            hits.truncate(max_results);
            if hits.is_empty() {
                format!("[no symbols starting with '{prefix}']\n")
            } else {
                let mut out = String::new();
                for (sym, loc) in hits {
                    out.push_str(&format!(
                        "{sym}\t{}:{} [{}]\n",
                        loc.path.display(),
                        loc.line,
                        loc.kind
                    ));
                }
                out
            }
        } else {
            let mut hits = engine.handles.symbols.lookup_exact(name);
            hits.truncate(max_results);
            crate::engine_tools::format_symbol_hits(&hits, name)
        };
        Ok(CallToolResult::success(vec![Content::text(text)]))
    }

    #[tool(
        name = "ffs_callers",
        description = "Find all call sites of `name` in the workspace, narrowed by the bigram + bloom pre-filter stack and confirmed with a literal text scan. Excludes definition lines."
    )]
    fn engine_callers(
        &self,
        Parameters(params): Parameters<EngineCallParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let root = self.picker_base_path()?;
        let max_results = normalize_max_results(params.max_results, 100);
        let engine = self.engine.get_or_build(&root, 25_000);
        let hits = crate::engine_tools::find_call_sites(&engine, &root, &params.name, max_results);
        let text = crate::engine_tools::format_call_hits(&hits, "callers");
        Ok(CallToolResult::success(vec![Content::text(text)]))
    }

    #[tool(
        name = "ffs_callees",
        description = "Find all symbols referenced inside the body of `name` (i.e. the symbols `name` calls). Definitions are scanned via the symbol index; tokens that resolve to known definitions are emitted."
    )]
    fn engine_callees(
        &self,
        Parameters(params): Parameters<EngineCallParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let root = self.picker_base_path()?;
        let max_results = normalize_max_results(params.max_results, 100);
        let engine = self.engine.get_or_build(&root, 25_000);
        let hits =
            crate::engine_tools::find_callee_sites(&engine, &root, &params.name, max_results);
        let text = crate::engine_tools::format_call_hits(&hits, "callees");
        Ok(CallToolResult::success(vec![Content::text(text)]))
    }

    #[tool(
        name = "ffs_read",
        description = "Read a file with token-budget-aware truncation. The body is filtered (none / minimal / aggressive), then clipped to fit `maxTokens` (default 25000). The footer '[truncated to budget]' is preserved when the budget runs out."
    )]
    fn engine_read(
        &self,
        Parameters(params): Parameters<EngineReadParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let root = self.picker_base_path()?;
        let max_tokens = normalize_max_results(params.max_tokens, 25_000) as u64;
        let level = crate::engine_tools::parse_filter_level(params.filter.as_deref());
        let engine = self.engine.get_or_build(&root, max_tokens);

        let path_part = params
            .path
            .rsplit_once(':')
            .filter(|(_, line)| line.chars().all(|c| c.is_ascii_digit()) && !line.is_empty())
            .map(|(p, _)| p)
            .unwrap_or(&params.path);

        let path = std::path::Path::new(path_part);
        let abs_path = if path.is_absolute() {
            path.to_path_buf()
        } else {
            root.join(path)
        };

        let cfg = ffs_engine::EngineConfig {
            filter_level: level,
            total_token_budget: max_tokens,
            ..ffs_engine::EngineConfig::default()
        };
        let local_engine = ffs_engine::Engine::new(cfg);
        let _ = engine; // shared engine is the index source; we instantiate a
        // throwaway engine for the configured filter level since EngineConfig
        // is not currently mutable on the live shared instance.
        let res = local_engine.read(&abs_path);
        let text = format!("[file: {}]\n{}", res.path.display(), res.body,);
        Ok(CallToolResult::success(vec![Content::text(text)]))
    }

    #[tool(
        name = "ffs_refs",
        description = "List all definitions of `name` plus single-hop usages in one shot. Returns JSON with `definitions[]`, `usages[]`, and pagination metadata. Mirrors `ffs refs` from the CLI."
    )]
    fn engine_refs(
        &self,
        Parameters(params): Parameters<EngineRefsParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let root = self.picker_base_path()?;
        let limit = normalize_max_results(params.max_results, 100);
        let offset = params.offset.map(|v| v.round() as usize).unwrap_or(0);
        let args = vec![
            params.name,
            "--limit".into(),
            limit.to_string(),
            "--offset".into(),
            offset.to_string(),
        ];
        let text = crate::engine_tools::run_engine_subprocess("refs", &root, &args)
            .map_err(|e| ErrorData::internal_error(format!("ffs refs failed: {e}"), None))?;
        Ok(CallToolResult::success(vec![Content::text(text)]))
    }

    #[tool(
        name = "ffs_flow",
        description = "Drill-down envelope per definition: def metadata + body excerpt + top-N callees + top-N callers. Returns JSON cards with pagination. Mirrors `ffs flow` from the CLI."
    )]
    fn engine_flow(
        &self,
        Parameters(params): Parameters<EngineFlowParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let root = self.picker_base_path()?;
        let limit = normalize_max_results(params.max_results, 10);
        let offset = params.offset.map(|v| v.round() as usize).unwrap_or(0);
        let callees_top = normalize_max_results(params.callees_top, 5);
        let callers_top = normalize_max_results(params.callers_top, 5);
        let budget = params.budget.map(|v| v.round() as u64).unwrap_or(10_000);
        let args = vec![
            params.name,
            "--limit".into(),
            limit.to_string(),
            "--offset".into(),
            offset.to_string(),
            "--callees-top".into(),
            callees_top.to_string(),
            "--callers-top".into(),
            callers_top.to_string(),
            "--budget".into(),
            budget.to_string(),
        ];
        let text = crate::engine_tools::run_engine_subprocess("flow", &root, &args)
            .map_err(|e| ErrorData::internal_error(format!("ffs flow failed: {e}"), None))?;
        Ok(CallToolResult::success(vec![Content::text(text)]))
    }

    #[tool(
        name = "ffs_impact",
        description = "Rank workspace files by how much they'd be affected if `name` changed. Score = direct*3 + imports*2 + transitive*1. Returns JSON `results[]` sorted by score desc."
    )]
    fn engine_impact(
        &self,
        Parameters(params): Parameters<EngineImpactParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let root = self.picker_base_path()?;
        let limit = normalize_max_results(params.max_results, 20);
        let offset = params.offset.map(|v| v.round() as usize).unwrap_or(0);
        let hops = params
            .hops
            .map(|v| v.round().clamp(1.0, 3.0) as u32)
            .unwrap_or(3);
        let hub_guard = normalize_max_results(params.hub_guard, 50);
        let args = vec![
            params.name,
            "--limit".into(),
            limit.to_string(),
            "--offset".into(),
            offset.to_string(),
            "--hops".into(),
            hops.to_string(),
            "--hub-guard".into(),
            hub_guard.to_string(),
        ];
        let text = crate::engine_tools::run_engine_subprocess("impact", &root, &args)
            .map_err(|e| ErrorData::internal_error(format!("ffs impact failed: {e}"), None))?;
        Ok(CallToolResult::success(vec![Content::text(text)]))
    }

    #[tool(
        name = "ffs_outline",
        description = "Render a file's structural outline (functions, classes, top-level decls). Returns the agent-friendly view by default — header line, [A-B] left column, bundled imports, indented signatures. Mirrors `ffs outline` from the CLI."
    )]
    fn engine_outline(
        &self,
        Parameters(params): Parameters<EngineOutlineParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let root = self.picker_base_path()?;
        let style = params.style.unwrap_or_else(|| "agent".to_string());
        let args = vec![params.path, "--style".into(), style];
        let text = crate::engine_tools::run_engine_subprocess("outline", &root, &args)
            .map_err(|e| ErrorData::internal_error(format!("ffs outline failed: {e}"), None))?;
        Ok(CallToolResult::success(vec![Content::text(text)]))
    }

    #[tool(
        name = "ffs_siblings",
        description = "List sibling symbols (peers in the same parent scope as `name`). Useful for navigating around a definition: when you find a method, this surfaces the rest of the impl block / class. Mirrors `ffs siblings` from the CLI."
    )]
    fn engine_siblings(
        &self,
        Parameters(params): Parameters<EngineSiblingsParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let root = self.picker_base_path()?;
        let limit = normalize_max_results(params.max_results, 100);
        let offset = params.offset.map(|v| v.round() as usize).unwrap_or(0);
        let mut args = vec![
            params.name,
            "--limit".into(),
            limit.to_string(),
            "--offset".into(),
            offset.to_string(),
        ];
        if params.include_imports.unwrap_or(false) {
            args.push("--include-imports".into());
        }
        let text = crate::engine_tools::run_engine_subprocess("siblings", &root, &args)
            .map_err(|e| ErrorData::internal_error(format!("ffs siblings failed: {e}"), None))?;
        Ok(CallToolResult::success(vec![Content::text(text)]))
    }

    #[tool(
        name = "ffs_deps",
        description = "Show a file's imports (raw + resolved) and the workspace files that depend on it. Use to understand the blast radius of changing a single file. Mirrors `ffs deps` from the CLI."
    )]
    fn engine_deps(
        &self,
        Parameters(params): Parameters<EngineDepsParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let root = self.picker_base_path()?;
        let limit = normalize_max_results(params.max_results, 100);
        let offset = params.offset.map(|v| v.round() as usize).unwrap_or(0);
        let mut args = vec![
            params.target,
            "--limit".into(),
            limit.to_string(),
            "--offset".into(),
            offset.to_string(),
        ];
        if params.no_dependents.unwrap_or(false) {
            args.push("--no-dependents".into());
        }
        let text = crate::engine_tools::run_engine_subprocess("deps", &root, &args)
            .map_err(|e| ErrorData::internal_error(format!("ffs deps failed: {e}"), None))?;
        Ok(CallToolResult::success(vec![Content::text(text)]))
    }

    #[tool(
        name = "ffs_map",
        description = "Render the workspace as a tree annotated with file count and an LLM-token estimate per directory. Use to orient yourself in an unfamiliar repo before drilling into a subtree. Mirrors `ffs map` from the CLI."
    )]
    fn engine_map(
        &self,
        Parameters(params): Parameters<EngineMapParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let root = self.picker_base_path()?;
        let depth = params.depth.map(|v| v.round() as u32).unwrap_or(3);
        let symbols = params.symbols.map(|v| v.round() as u32).unwrap_or(0);
        let mut args = vec!["--depth".into(), depth.to_string()];
        if symbols > 0 {
            args.push("--symbols".into());
            args.push(symbols.to_string());
        }
        let text = crate::engine_tools::run_engine_subprocess("map", &root, &args)
            .map_err(|e| ErrorData::internal_error(format!("ffs map failed: {e}"), None))?;
        Ok(CallToolResult::success(vec![Content::text(text)]))
    }

    #[tool(
        name = "ffs_overview",
        description = "High-signal summary of the workspace: language breakdown, top-defined symbols, entry-point candidates. Run this first when an agent enters an unfamiliar repository. Mirrors `ffs overview` from the CLI."
    )]
    fn engine_overview(
        &self,
        Parameters(params): Parameters<EngineOverviewParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let root = self.picker_base_path()?;
        let top_languages = normalize_max_results(params.top_languages, 10);
        let top_symbols = normalize_max_results(params.top_symbols, 15);
        let top_entrypoints = normalize_max_results(params.top_entrypoints, 10);
        let args = vec![
            "--top-languages".into(),
            top_languages.to_string(),
            "--top-symbols".into(),
            top_symbols.to_string(),
            "--top-entrypoints".into(),
            top_entrypoints.to_string(),
        ];
        let text = crate::engine_tools::run_engine_subprocess("overview", &root, &args)
            .map_err(|e| ErrorData::internal_error(format!("ffs overview failed: {e}"), None))?;
        Ok(CallToolResult::success(vec![Content::text(text)]))
    }
}

impl FfsServer {
    fn multi_grep_inner(&self, params: MultiGrepParams) -> Result<CallToolResult, ErrorData> {
        let max_results = normalize_max_results(params.max_results, 20);
        let context = params.context.map(|v| v.round() as usize);
        let output_mode = OutputMode::new(params.output_mode.as_deref());

        let file_offset = params
            .cursor
            .as_deref()
            .and_then(|id| self.cursor_store.lock().ok()?.get(id))
            .unwrap_or(0);

        let (options, auto_expand) =
            make_grep_options(output_mode, GrepMode::PlainText, file_offset, context);

        let ctx_lines = options.before_context;
        let constraint_query = params.constraints.as_deref().unwrap_or("");
        let guard = self.picker.read().map_err(|e| {
            ErrorData::internal_error(format!("Failed to acquire picker lock: {e}"), None)
        })?;
        let picker = guard
            .as_ref()
            .ok_or_else(|| ErrorData::internal_error("File picker not initialized", None))?;
        let patterns_refs: Vec<&str> = params.patterns.iter().map(|s| s.as_str()).collect();

        let parser = ffs_query_parser::QueryParser::new(ffs_query_parser::AiGrepConfig);
        let parsed_constraints = parser.parse(constraint_query);
        let constraints = parsed_constraints.constraints.as_slice();

        let result = picker.multi_grep(&patterns_refs, constraints, &options);
        let file_refs: Vec<&FileItem> = result.files.to_vec();

        if result.matches.is_empty() && file_offset == 0 {
            // Fallback: try individual patterns with plain grep
            let (fallback_options, _) =
                make_grep_options(output_mode, GrepMode::PlainText, 0, context);

            let fallback_options = GrepSearchOptions {
                time_budget_ms: 3000,
                before_context: 0,
                ..fallback_options
            };

            for pat in &params.patterns {
                let full_query: Cow<str> = if !constraint_query.is_empty() {
                    Cow::Owned(format!("{} {}", constraint_query, pat))
                } else {
                    Cow::Borrowed(pat)
                };

                let parsed = parser.parse(&full_query);
                let fb_result = picker.grep(&parsed, &fallback_options);

                if !fb_result.matches.is_empty() {
                    let fb_file_refs: Vec<&FileItem> = fb_result.files.to_vec();
                    let mut cs = self.lock_cursors()?;
                    let text = &GrepFormatter {
                        matches: &fb_result.matches,
                        files: &fb_file_refs,
                        total_matched: fb_result.matches.len(),
                        next_file_offset: fb_result.next_file_offset,
                        output_mode,
                        max_results,
                        show_context: false,
                        auto_expand_defs: auto_expand,
                        picker,
                    }
                    .format(&mut cs);
                    return Ok(CallToolResult::success(vec![Content::text(format!(
                        "0 multi-pattern matches. Plain ffs_grep fallback for \"{}\":\n{}",
                        pat, text
                    ))]));
                }
            }

            return Ok(CallToolResult::success(vec![Content::text(
                "0 matches.".to_string(),
            )]));
        }

        if result.matches.is_empty() {
            return Ok(CallToolResult::success(vec![Content::text(
                "0 matches.".to_string(),
            )]));
        }

        let mut cs = self.lock_cursors()?;
        let text = &GrepFormatter {
            matches: &result.matches,
            files: &file_refs,
            total_matched: result.matches.len(),
            next_file_offset: result.next_file_offset,
            output_mode,
            max_results,
            show_context: ctx_lines > 0,
            auto_expand_defs: auto_expand,
            picker,
        }
        .format(&mut cs);

        Ok(CallToolResult::success(vec![Content::text(text)]))
    }
}

#[tool_handler]
impl ServerHandler for FfsServer {
    fn get_info(&self) -> ServerInfo {
        let notice = crate::update_check::get_update_notice();
        let instructions = if notice.is_empty() {
            crate::MCP_INSTRUCTIONS.to_string()
        } else {
            format!("{}{}", crate::MCP_INSTRUCTIONS, notice)
        };

        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("ffs", env!("CARGO_PKG_VERSION")))
            .with_instructions(instructions)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_max_results_none_uses_default() {
        assert_eq!(normalize_max_results(None, 20), 20);
    }

    #[test]
    fn normalize_max_results_zero_uses_default() {
        // Issue #400: `maxResults: 0` must not return zero items for ffs_grep
        // while `ffs_find` returns the full set. Both tools now map 0 to
        // the default limit.
        assert_eq!(normalize_max_results(Some(0.0), 20), 20);
    }

    #[test]
    fn normalize_max_results_negative_uses_default() {
        assert_eq!(normalize_max_results(Some(-5.0), 20), 20);
    }

    #[test]
    fn normalize_max_results_non_finite_uses_default() {
        assert_eq!(normalize_max_results(Some(f64::NAN), 20), 20);
        assert_eq!(normalize_max_results(Some(f64::INFINITY), 20), 20);
    }

    #[test]
    fn normalize_max_results_rounds_and_clamps() {
        assert_eq!(normalize_max_results(Some(0.4), 20), 1);
        assert_eq!(normalize_max_results(Some(10.0), 20), 10);
        assert_eq!(normalize_max_results(Some(10.7), 20), 11);
    }

    #[test]
    fn grep_params_accepts_pattern_alias() {
        // Issue #311: LLMs flip between `query` and `pattern`; accept both.
        let via_query: GrepParams =
            serde_json::from_str(r#"{"query":"foo"}"#).expect("query field");
        assert_eq!(via_query.query, "foo");

        let via_pattern: GrepParams =
            serde_json::from_str(r#"{"pattern":"foo"}"#).expect("pattern alias");
        assert_eq!(via_pattern.query, "foo");
    }

    #[test]
    fn find_files_params_accepts_pattern_alias() {
        let via_query: FindFilesParams =
            serde_json::from_str(r#"{"query":"foo"}"#).expect("query field");
        assert_eq!(via_query.query, "foo");

        let via_pattern: FindFilesParams =
            serde_json::from_str(r#"{"pattern":"foo"}"#).expect("pattern alias");
        assert_eq!(via_pattern.query, "foo");
    }
}
