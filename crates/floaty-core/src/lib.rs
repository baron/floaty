//! Local-first core model and pull-style FFI seam for Floaty.
//!
//! Discovery is intentionally read-only and non-fatal. Configured roots,
//! Codex/Claude session files, and optional pet metadata are scanned into a
//! lightweight snapshot; malformed or missing inputs are surfaced as warnings.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// The authoritative dashboard payload consumed by the UI.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DashboardSnapshot {
    pub generated_at: String,
    pub projects: Vec<ProjectSummary>,
    pub unassigned_sessions: Vec<AgentSessionSummary>,
    pub pets: Vec<PetAssetSummary>,
    pub warnings: Vec<CoreWarning>,
}

/// Sessions grouped under a known or inferred project root.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectSummary {
    pub root_path: String,
    pub display_name: String,
    pub root_confidence: RootConfidence,
    pub agents: Vec<AgentSessionSummary>,
    pub git: Option<GitSummary>,
}

/// Lightweight normalized summary for one local agent session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentSessionSummary {
    pub agent_kind: AgentKind,
    pub source_path: String,
    pub title: Option<String>,
    pub last_updated_at: String,
    pub status_hint: StatusHint,
    pub project_root_evidence: Option<String>,
}

/// Cheap Git state for a verified project root.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitSummary {
    pub branch: Option<String>,
    pub dirty: Option<bool>,
    pub ahead_count: Option<u32>,
    pub behind_count: Option<u32>,
    pub last_checked_at: String,
    pub error: Option<String>,
}

/// Minimal pet asset metadata. Image/frame bytes are intentionally not part of
/// the hot dashboard snapshot.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PetAssetSummary {
    pub pet_id: String,
    pub display_name: String,
    pub source_path: String,
}

/// Non-fatal issue surfaced to the UI instead of crashing the dashboard.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoreWarning {
    pub code: String,
    pub message: String,
    pub source_path: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RootConfidence {
    Verified,
    Inferred,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentKind {
    Codex,
    ClaudeCode,
    OpenCode,
    Hermes,
    Other(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StatusHint {
    Active,
    Idle,
    Unknown,
}

/// Read-only local discovery inputs. All paths are optional/configurable so
/// tests and future preferences can provide fixture-safe locations.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiscoveryConfig {
    pub configured_roots: Vec<String>,
    pub codex_sessions_dir: Option<String>,
    pub claude_projects_dir: Option<String>,
    pub codex_pets_dir: Option<String>,
}

#[derive(Debug, Clone)]
struct DiscoveredSession {
    summary: AgentSessionSummary,
    claimed_root: Option<String>,
    confidence: RootConfidence,
}

/// In-process core cache. The current MVP holds one immutable snapshot and a
/// monotonically increasing version.
#[derive(Debug, Clone)]
pub struct Core {
    snapshot: DashboardSnapshot,
    version: u64,
    discovery_config: DiscoveryConfig,
}

impl Core {
    /// Creates a local core seeded with a privacy-safe mock snapshot.
    pub fn new() -> Self {
        Self {
            snapshot: mock_snapshot(1),
            version: 1,
            discovery_config: DiscoveryConfig::default(),
        }
    }

    /// Creates a core from explicit read-only discovery paths.
    pub fn with_discovery_config(discovery_config: DiscoveryConfig) -> Self {
        let snapshot = discover_snapshot(&discovery_config);
        Self {
            snapshot,
            version: 1,
            discovery_config,
        }
    }

    /// Returns the current immutable snapshot.
    pub fn snapshot(&self) -> &DashboardSnapshot {
        &self.snapshot
    }

    /// Returns the current snapshot version.
    pub fn version(&self) -> u64 {
        self.version
    }

    /// Triggers a local refresh and publishes a new immutable snapshot.
    pub fn refresh(&mut self) -> u64 {
        self.version = self.version.saturating_add(1);
        self.snapshot = if self.discovery_config == DiscoveryConfig::default() {
            mock_snapshot(self.version)
        } else {
            discover_snapshot(&self.discovery_config)
        };
        self.version
    }

    /// Serializes the latest snapshot as UTF-8 JSON bytes for the FFI pull API.
    pub fn snapshot_json_bytes(&self) -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec(&self.snapshot)
    }
}

impl Default for Core {
    fn default() -> Self {
        Self::new()
    }
}

/// Builds a dashboard snapshot from configured read-only local sources.
pub fn discover_snapshot(config: &DiscoveryConfig) -> DashboardSnapshot {
    let generated_at = timestamp_now();
    let mut warnings = Vec::new();
    let configured_roots = existing_configured_roots(&config.configured_roots, &mut warnings);
    let mut sessions = Vec::new();

    if let Some(dir) = &config.codex_sessions_dir {
        sessions.extend(discover_agent_sessions(
            AgentKind::Codex,
            Path::new(dir),
            &configured_roots,
            &mut warnings,
        ));
    }

    if let Some(dir) = &config.claude_projects_dir {
        sessions.extend(discover_agent_sessions(
            AgentKind::ClaudeCode,
            Path::new(dir),
            &configured_roots,
            &mut warnings,
        ));
    }

    let pets = config
        .codex_pets_dir
        .as_ref()
        .map(|dir| discover_pets(Path::new(dir), &mut warnings))
        .unwrap_or_default();

    let mut grouped: BTreeMap<String, ProjectSummary> = configured_roots
        .iter()
        .map(|root| {
            let root_path = path_string(root);
            (
                root_path.clone(),
                ProjectSummary {
                    display_name: display_name(root),
                    root_path,
                    root_confidence: RootConfidence::Verified,
                    agents: Vec::new(),
                    git: None,
                },
            )
        })
        .collect();
    let mut unassigned_sessions = Vec::new();

    for session in sessions {
        match (session.confidence, session.claimed_root.as_ref()) {
            (RootConfidence::Verified | RootConfidence::Inferred, Some(root)) => {
                let entry = grouped.entry(root.clone()).or_insert_with(|| ProjectSummary {
                    root_path: root.clone(),
                    display_name: display_name(Path::new(root)),
                    root_confidence: session.confidence,
                    agents: Vec::new(),
                    git: None,
                });
                if entry.root_confidence != RootConfidence::Verified {
                    entry.root_confidence = session.confidence;
                }
                entry.agents.push(session.summary);
            }
            _ => unassigned_sessions.push(session.summary),
        }
    }

    DashboardSnapshot {
        generated_at,
        projects: grouped.into_values().collect(),
        unassigned_sessions,
        pets,
        warnings,
    }
}

fn existing_configured_roots(paths: &[String], warnings: &mut Vec<CoreWarning>) -> Vec<PathBuf> {
    paths
        .iter()
        .filter_map(|path| {
            let root = PathBuf::from(path);
            if root.is_dir() {
                Some(root)
            } else {
                warnings.push(CoreWarning {
                    code: "configured_root_missing".to_string(),
                    message: "Configured project root is missing or not a directory.".to_string(),
                    source_path: Some(path.clone()),
                });
                None
            }
        })
        .collect()
}

fn discover_agent_sessions(
    agent_kind: AgentKind,
    dir: &Path,
    configured_roots: &[PathBuf],
    warnings: &mut Vec<CoreWarning>,
) -> Vec<DiscoveredSession> {
    let files = discover_session_files(dir, warnings);
    files
        .into_iter()
        .filter_map(|file| parse_session_file(agent_kind.clone(), &file, configured_roots, warnings))
        .collect()
}

fn discover_session_files(dir: &Path, warnings: &mut Vec<CoreWarning>) -> Vec<PathBuf> {
    let mut files = Vec::new();
    visit_session_dir(dir, 0, &mut files, warnings);
    files.sort();
    files
}

fn visit_session_dir(
    dir: &Path,
    depth: usize,
    files: &mut Vec<PathBuf>,
    warnings: &mut Vec<CoreWarning>,
) {
    if depth > 6 {
        return;
    }

    let Ok(entries) = fs::read_dir(dir) else {
        warnings.push(CoreWarning {
            code: "source_unreadable".to_string(),
            message: "Session source directory is missing or unreadable.".to_string(),
            source_path: Some(path_string(dir)),
        });
        return;
    };

    for entry in entries {
        let Ok(entry) = entry else {
            warnings.push(CoreWarning {
                code: "source_entry_unreadable".to_string(),
                message: "A session source entry could not be read.".to_string(),
                source_path: Some(path_string(dir)),
            });
            continue;
        };
        let path = entry.path();
        if path.is_dir() {
            visit_session_dir(&path, depth + 1, files, warnings);
        } else if matches!(path.extension().and_then(|ext| ext.to_str()), Some("jsonl" | "json")) {
            files.push(path);
        }
    }
}

fn parse_session_file(
    agent_kind: AgentKind,
    path: &Path,
    configured_roots: &[PathBuf],
    warnings: &mut Vec<CoreWarning>,
) -> Option<DiscoveredSession> {
    let content = match fs::read_to_string(path) {
        Ok(content) => content,
        Err(_) => {
            warnings.push(CoreWarning {
                code: "session_unreadable".to_string(),
                message: "Session file could not be read.".to_string(),
                source_path: Some(path_string(path)),
            });
            return None;
        }
    };

    let mut claimed_root = None;
    let mut title = None;
    let mut parsed_any = false;

    for line in content.lines().take(64) {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(trimmed) else {
            warnings.push(CoreWarning {
                code: "session_parse_error".to_string(),
                message: "Session file contains invalid JSONL.".to_string(),
                source_path: Some(path_string(path)),
            });
            continue;
        };
        parsed_any = true;
        title = title.or_else(|| first_string(&value, &["title", "summary", "name"]));
        claimed_root = claimed_root.or_else(|| {
            first_string(
                &value,
                &[
                    "project_root",
                    "projectRoot",
                    "cwd",
                    "current_working_directory",
                    "workspace",
                    "root_path",
                ],
            )
        });
    }

    if !parsed_any {
        warnings.push(CoreWarning {
            code: "session_unknown_schema".to_string(),
            message: "Session file did not contain readable metadata.".to_string(),
            source_path: Some(path_string(path)),
        });
    }

    let (root, confidence, evidence) = classify_root(claimed_root.as_deref(), configured_roots);
    Some(DiscoveredSession {
        claimed_root: root,
        confidence,
        summary: AgentSessionSummary {
            agent_kind,
            source_path: path_string(path),
            title,
            last_updated_at: modified_at(path),
            status_hint: StatusHint::Unknown,
            project_root_evidence: evidence,
        },
    })
}

fn first_string(value: &Value, keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Some(found) = value.get(*key).and_then(Value::as_str) {
            if !found.trim().is_empty() {
                return Some(found.to_string());
            }
        }
        if let Some(found) = value
            .get("metadata")
            .and_then(|metadata| metadata.get(*key))
            .and_then(Value::as_str)
        {
            if !found.trim().is_empty() {
                return Some(found.to_string());
            }
        }
    }
    None
}

fn classify_root(
    claimed_root: Option<&str>,
    configured_roots: &[PathBuf],
) -> (Option<String>, RootConfidence, Option<String>) {
    let Some(claimed_root) = claimed_root.filter(|root| !root.trim().is_empty()) else {
        return (None, RootConfidence::Unknown, None);
    };
    let claimed = PathBuf::from(claimed_root);

    for configured in configured_roots {
        if claimed == *configured || claimed.starts_with(configured) {
            return (
                Some(path_string(configured)),
                RootConfidence::Verified,
                Some("session metadata matched configured root".to_string()),
            );
        }
    }

    if claimed.is_dir() {
        (
            Some(path_string(&claimed)),
            RootConfidence::Inferred,
            Some("session metadata referenced existing root".to_string()),
        )
    } else {
        (
            None,
            RootConfidence::Unknown,
            Some("session metadata root was missing or unverified".to_string()),
        )
    }
}

fn discover_pets(dir: &Path, warnings: &mut Vec<CoreWarning>) -> Vec<PetAssetSummary> {
    let Ok(entries) = fs::read_dir(dir) else {
        warnings.push(CoreWarning {
            code: "pets_unreadable".to_string(),
            message: "Codex pets directory is missing or unreadable.".to_string(),
            source_path: Some(path_string(dir)),
        });
        return Vec::new();
    };

    let mut pets = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let manifest = path.join("pet.json");
        if !manifest.is_file() {
            warnings.push(CoreWarning {
                code: "pet_manifest_missing".to_string(),
                message: "Pet folder does not contain pet.json.".to_string(),
                source_path: Some(path_string(&path)),
            });
            continue;
        }

        let display_name = fs::read_to_string(&manifest)
            .ok()
            .and_then(|content| serde_json::from_str::<Value>(&content).ok())
            .and_then(|value| first_string(&value, &["display_name", "displayName", "name"]))
            .unwrap_or_else(|| display_name(&path));

        pets.push(PetAssetSummary {
            pet_id: path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("pet")
                .to_string(),
            display_name,
            source_path: path_string(&manifest),
        });
    }
    pets.sort_by(|a, b| a.pet_id.cmp(&b.pet_id));
    pets
}

fn display_name(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or("/")
        .to_string()
}

fn path_string(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

fn timestamp_now() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    format!("unix-{seconds}")
}

fn modified_at(path: &Path) -> String {
    fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .map(|duration| format!("unix-{}", duration.as_secs()))
        .unwrap_or_else(timestamp_now)
}

/// Opaque handle owned by FFI callers until passed to `floaty_core_free`.
#[repr(C)]
pub struct FloatyCore {
    core: Mutex<Core>,
}

/// Rust-owned byte buffer returned over FFI.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FloatyByteBuffer {
    pub data: *mut u8,
    pub len: usize,
}

impl FloatyByteBuffer {
    fn empty() -> Self {
        Self {
            data: ptr::null_mut(),
            len: 0,
        }
    }

    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self::empty();
        }

        let mut boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        let data = boxed.as_mut_ptr();
        std::mem::forget(boxed);
        Self { data, len }
    }
}

#[no_mangle]
pub extern "C" fn floaty_core_new() -> *mut FloatyCore {
    catch_unwind(|| {
        Box::into_raw(Box::new(FloatyCore {
            core: Mutex::new(Core::new()),
        }))
    })
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn floaty_core_free(core: *mut FloatyCore) {
    if core.is_null() {
        return;
    }

    unsafe {
        drop(Box::from_raw(core));
    }
}

#[no_mangle]
pub extern "C" fn floaty_core_snapshot_version(core: *const FloatyCore) -> u64 {
    if core.is_null() {
        return 0;
    }

    catch_unwind(AssertUnwindSafe(|| unsafe {
        (*core)
            .core
            .lock()
            .map(|guard| guard.version())
            .unwrap_or(0)
    }))
    .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn floaty_core_refresh(core: *mut FloatyCore) -> u64 {
    if core.is_null() {
        return 0;
    }

    catch_unwind(AssertUnwindSafe(|| unsafe {
        (*core)
            .core
            .lock()
            .map(|mut guard| guard.refresh())
            .unwrap_or(0)
    }))
    .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn floaty_core_snapshot_json(core: *const FloatyCore) -> FloatyByteBuffer {
    if core.is_null() {
        return FloatyByteBuffer::empty();
    }

    catch_unwind(AssertUnwindSafe(|| unsafe {
        (*core)
            .core
            .lock()
            .ok()
            .and_then(|guard| guard.snapshot_json_bytes().ok())
            .map(FloatyByteBuffer::from_vec)
            .unwrap_or_else(FloatyByteBuffer::empty)
    }))
    .unwrap_or_else(|_| FloatyByteBuffer::empty())
}

#[no_mangle]
pub extern "C" fn floaty_core_buffer_free(buffer: FloatyByteBuffer) {
    if buffer.data.is_null() || buffer.len == 0 {
        return;
    }

    unsafe {
        let slice = ptr::slice_from_raw_parts_mut(buffer.data, buffer.len);
        drop(Box::from_raw(slice));
    }
}

/// Produces deterministic, privacy-safe mock data with no filesystem reads.
pub fn mock_snapshot(version: u64) -> DashboardSnapshot {
    let generated_at = format!("mock-2026-06-26T00:00:{:02}Z", version % 60);
    let checked_at = generated_at.clone();

    DashboardSnapshot {
        generated_at: generated_at.clone(),
        projects: vec![ProjectSummary {
            root_path: "/tmp/floaty-demo".to_string(),
            display_name: "floaty-demo".to_string(),
            root_confidence: RootConfidence::Verified,
            agents: vec![AgentSessionSummary {
                agent_kind: AgentKind::Codex,
                source_path: "/tmp/floaty-demo/.codex/sessions/mock-session.jsonl".to_string(),
                title: Some("Mock Codex planning session".to_string()),
                last_updated_at: generated_at.clone(),
                status_hint: StatusHint::Idle,
                project_root_evidence: Some("mock configured root".to_string()),
            }],
            git: Some(GitSummary {
                branch: Some("main".to_string()),
                dirty: Some(false),
                ahead_count: Some(0),
                behind_count: Some(0),
                last_checked_at: checked_at,
                error: None,
            }),
        }],
        unassigned_sessions: vec![AgentSessionSummary {
            agent_kind: AgentKind::ClaudeCode,
            source_path: "/tmp/floaty-unassigned/claude/mock-session.jsonl".to_string(),
            title: Some("Mock unassigned session".to_string()),
            last_updated_at: generated_at,
            status_hint: StatusHint::Unknown,
            project_root_evidence: None,
        }],
        pets: vec![PetAssetSummary {
            pet_id: "mock-cat".to_string(),
            display_name: "Mock Cat".to_string(),
            source_path: "/tmp/floaty-pets/mock-cat/pet.json".to_string(),
        }],
        warnings: vec![CoreWarning {
            code: "mock_data".to_string(),
            message: "Floaty core is returning mocked local-only data.".to_string(),
            source_path: None,
        }],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::slice;

    #[test]
    fn mock_snapshot_matches_lightweight_shape() {
        let snapshot = mock_snapshot(1);

        assert!(!snapshot.generated_at.is_empty());
        assert_eq!(snapshot.projects.len(), 1);
        assert_eq!(snapshot.projects[0].root_path, "/tmp/floaty-demo");
        assert_eq!(
            snapshot.projects[0].root_confidence,
            RootConfidence::Verified
        );
        assert_eq!(snapshot.projects[0].agents.len(), 1);
        assert!(snapshot.projects[0].git.is_some());
        assert_eq!(snapshot.unassigned_sessions.len(), 1);
        assert_eq!(snapshot.pets.len(), 1);
        assert_eq!(snapshot.warnings.len(), 1);
    }

    #[test]
    fn discovery_groups_configured_codex_and_claude_sessions_and_pets() {
        let fixture = TestFixture::new("groups");
        let configured_root = fixture.mkdir("work/floaty");
        let inferred_root = fixture.mkdir("other/inferred");
        let codex_dir = fixture.mkdir("codex/sessions");
        let claude_dir = fixture.mkdir("claude/projects");
        let pets_dir = fixture.mkdir("codex/pets");
        fixture.write(
            "codex/sessions/session.jsonl",
            &format!(
                "{{\"cwd\":\"{}\",\"title\":\"Codex Fixture\"}}\n",
                configured_root.display()
            ),
        );
        fixture.write(
            "claude/projects/session.jsonl",
            &format!(
                "{{\"metadata\":{{\"project_root\":\"{}\"}},\"summary\":\"Claude Fixture\"}}\n",
                inferred_root.display()
            ),
        );
        fixture.write("codex/pets/otter/pet.json", "{\"name\":\"Otter\"}");

        let snapshot = discover_snapshot(&DiscoveryConfig {
            configured_roots: vec![path_string(&configured_root)],
            codex_sessions_dir: Some(path_string(&codex_dir)),
            claude_projects_dir: Some(path_string(&claude_dir)),
            codex_pets_dir: Some(path_string(&pets_dir)),
        });

        let verified = snapshot
            .projects
            .iter()
            .find(|project| project.root_path == path_string(&configured_root))
            .expect("configured root should be present");
        assert_eq!(verified.root_confidence, RootConfidence::Verified);
        assert_eq!(verified.agents[0].agent_kind, AgentKind::Codex);
        assert_eq!(verified.agents[0].title.as_deref(), Some("Codex Fixture"));

        let inferred = snapshot
            .projects
            .iter()
            .find(|project| project.root_path == path_string(&inferred_root))
            .expect("inferred root should be present");
        assert_eq!(inferred.root_confidence, RootConfidence::Inferred);
        assert_eq!(inferred.agents[0].agent_kind, AgentKind::ClaudeCode);
        assert_eq!(snapshot.unassigned_sessions.len(), 0);
        assert_eq!(snapshot.pets.len(), 1);
        assert_eq!(snapshot.pets[0].display_name, "Otter");
    }

    #[test]
    fn discovery_keeps_unknown_roots_unassigned_and_warns() {
        let fixture = TestFixture::new("warnings");
        let codex_dir = fixture.mkdir("codex/sessions");
        fixture.write(
            "codex/sessions/unknown.jsonl",
            "{\"project_root\":\"/definitely/missing/floaty\",\"title\":\"Unknown\"}\nnot json\n",
        );

        let snapshot = discover_snapshot(&DiscoveryConfig {
            configured_roots: vec![path_string(&fixture.root.join("missing-root"))],
            codex_sessions_dir: Some(path_string(&codex_dir)),
            claude_projects_dir: Some(path_string(&fixture.root.join("missing-claude"))),
            codex_pets_dir: Some(path_string(&fixture.root.join("missing-pets"))),
        });

        assert_eq!(snapshot.unassigned_sessions.len(), 1);
        assert_eq!(
            snapshot.unassigned_sessions[0].project_root_evidence.as_deref(),
            Some("session metadata root was missing or unverified")
        );
        assert!(snapshot
            .warnings
            .iter()
            .any(|warning| warning.code == "configured_root_missing"));
        assert!(snapshot
            .warnings
            .iter()
            .any(|warning| warning.code == "source_unreadable"));
        assert!(snapshot
            .warnings
            .iter()
            .any(|warning| warning.code == "pets_unreadable"));
        assert!(snapshot
            .warnings
            .iter()
            .any(|warning| warning.code == "session_parse_error"));
    }

    #[test]
    fn core_refresh_increments_version_and_replaces_snapshot() {
        let mut core = Core::new();
        let initial_version = core.version();
        let initial_generated_at = core.snapshot().generated_at.clone();

        let refreshed_version = core.refresh();

        assert_eq!(refreshed_version, initial_version + 1);
        assert_eq!(core.version(), refreshed_version);
        assert_ne!(core.snapshot().generated_at, initial_generated_at);
    }

    #[test]
    fn configured_core_refresh_uses_discovery_config() {
        let fixture = TestFixture::new("core-refresh");
        let root = fixture.mkdir("project");
        let codex_dir = fixture.mkdir("codex/sessions");
        fixture.write(
            "codex/sessions/session.jsonl",
            &format!("{{\"cwd\":\"{}\"}}\n", root.display()),
        );
        let mut core = Core::with_discovery_config(DiscoveryConfig {
            configured_roots: vec![path_string(&root)],
            codex_sessions_dir: Some(path_string(&codex_dir)),
            claude_projects_dir: None,
            codex_pets_dir: None,
        });

        assert_eq!(core.snapshot().projects[0].agents.len(), 1);
        fixture.write("codex/sessions/second.jsonl", &format!("{{\"cwd\":\"{}\"}}\n", root.display()));
        assert_eq!(core.refresh(), 2);
        assert_eq!(core.snapshot().projects[0].agents.len(), 2);
    }

    #[test]
    fn core_serializes_snapshot_as_json() {
        let core = Core::new();
        let bytes = core
            .snapshot_json_bytes()
            .expect("snapshot should serialize");
        let json: Value = serde_json::from_slice(&bytes).expect("snapshot should be valid JSON");

        assert!(json.get("generated_at").is_some());
        assert!(json.get("projects").and_then(Value::as_array).is_some());
        assert!(json
            .get("unassigned_sessions")
            .and_then(Value::as_array)
            .is_some());
        assert!(json.get("pets").and_then(Value::as_array).is_some());
        assert!(json.get("warnings").and_then(Value::as_array).is_some());
    }

    #[test]
    fn ffi_returns_and_frees_serialized_snapshot() {
        let handle = floaty_core_new();
        assert!(!handle.is_null());
        assert_eq!(floaty_core_snapshot_version(handle), 1);

        let buffer = floaty_core_snapshot_json(handle);
        assert!(!buffer.data.is_null());
        assert!(buffer.len > 0);

        let bytes = unsafe { slice::from_raw_parts(buffer.data, buffer.len) };
        let snapshot: DashboardSnapshot =
            serde_json::from_slice(bytes).expect("FFI snapshot should be valid JSON");
        assert_eq!(snapshot.projects[0].display_name, "floaty-demo");

        floaty_core_buffer_free(buffer);
        assert_eq!(floaty_core_refresh(handle), 2);
        floaty_core_free(handle);
    }

    #[test]
    fn ffi_null_inputs_are_safe_noops() {
        assert_eq!(floaty_core_snapshot_version(ptr::null()), 0);
        assert_eq!(floaty_core_refresh(ptr::null_mut()), 0);

        let buffer = floaty_core_snapshot_json(ptr::null());
        assert!(buffer.data.is_null());
        assert_eq!(buffer.len, 0);

        floaty_core_buffer_free(buffer);
        floaty_core_free(ptr::null_mut());
    }

    struct TestFixture {
        root: PathBuf,
    }

    impl TestFixture {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!(
                "floaty-core-{name}-{}",
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .expect("time should be available")
                    .as_nanos()
            ));
            fs::create_dir_all(&root).expect("fixture root should be created");
            Self { root }
        }

        fn mkdir(&self, relative: &str) -> PathBuf {
            let path = self.root.join(relative);
            fs::create_dir_all(&path).expect("fixture directory should be created");
            path
        }

        fn write(&self, relative: &str, content: &str) {
            let path = self.root.join(relative);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).expect("fixture parent should be created");
            }
            fs::write(path, content).expect("fixture file should be written");
        }
    }

    impl Drop for TestFixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}
