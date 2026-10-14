use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread;
use std::time::{Duration, Instant};

use eframe::egui::{self, Key, RichText, TextEdit};
use eframe::{App, Frame};
use egui::text::{CCursor, CCursorRange};

use crate::config::EditorSettings;
use crate::document::Document;
use crate::project_search::{SearchResults, search_project};
use crate::quick_open::{QuickOpenResults, search_files};
use crate::session::{self, SessionDocument};
use crate::workspace::Workspace;
use rhun_native_core::LaunchOptions;

#[derive(Clone, Copy)]
enum CloseAfter {
    Document,
    Exit,
    All,
}

#[derive(Clone, Copy)]
struct PendingClose {
    document_id: u64,
    after: CloseAfter,
}

struct ClosedDocument {
    path: PathBuf,
    index: usize,
    anchor: usize,
    cursor: usize,
}

#[derive(Clone, Copy)]
enum CloseChoice {
    Save,
    Discard,
    Cancel,
}

pub struct RhunApp {
    documents: Vec<Document>,
    active: Option<usize>,
    closed_documents: Vec<ClosedDocument>,
    pending_close: Option<PendingClose>,
    close_approved: bool,
    next_document_id: u64,
    workspace: Option<Workspace>,
    expanded_directories: HashSet<PathBuf>,
    project_root: Option<PathBuf>,
    editor_settings: EditorSettings,
    session_enabled: bool,
    path_input: String,
    save_as_pending: bool,
    open_folder_pending: bool,
    find_input: String,
    replace_input: String,
    find_open: bool,
    replace_open: bool,
    project_search_open: bool,
    focus_project_search_input: bool,
    project_search_input: String,
    project_search_root: Option<PathBuf>,
    project_search_results: Vec<crate::project_search::SearchMatch>,
    project_search_receiver: Option<Receiver<io::Result<SearchResults>>>,
    project_search_status: String,
    quick_open_open: bool,
    focus_quick_open_input: bool,
    quick_open_input: String,
    quick_open_root: Option<PathBuf>,
    quick_open_results: Vec<crate::quick_open::QuickOpenMatch>,
    quick_open_receiver: Option<Receiver<io::Result<QuickOpenResults>>>,
    quick_open_status: String,
    focus_path_input: bool,
    focus_find_input: bool,
    go_to_line_open: bool,
    go_to_line_input: String,
    focus_go_to_line_input: bool,
    message: String,
    last_file_check: Instant,
}

impl RhunApp {
    pub fn new(options: LaunchOptions) -> Self {
        let editor_settings = match EditorSettings::load() {
            Ok(settings) => settings,
            Err(error) => {
                eprintln!("rhun: could not load editor settings: {error}");
                EditorSettings::default()
            }
        };
        Self::with_editor_settings(options, editor_settings)
    }

    fn with_editor_settings(options: LaunchOptions, editor_settings: EditorSettings) -> Self {
        let mut app = Self {
            documents: Vec::new(),
            active: None,
            closed_documents: Vec::new(),
            pending_close: None,
            close_approved: false,
            next_document_id: 1,
            workspace: None,
            expanded_directories: HashSet::new(),
            project_root: None,
            editor_settings,
            session_enabled: !options.empty || !options.paths.is_empty(),
            path_input: String::new(),
            save_as_pending: false,
            open_folder_pending: false,
            find_input: String::new(),
            replace_input: String::new(),
            find_open: false,
            replace_open: false,
            project_search_open: false,
            focus_project_search_input: false,
            project_search_input: String::new(),
            project_search_root: None,
            project_search_results: Vec::new(),
            project_search_receiver: None,
            project_search_status: String::new(),
            quick_open_open: false,
            focus_quick_open_input: false,
            quick_open_input: String::new(),
            quick_open_root: None,
            quick_open_results: Vec::new(),
            quick_open_receiver: None,
            quick_open_status: String::new(),
            focus_path_input: false,
            focus_find_input: false,
            go_to_line_open: false,
            go_to_line_input: String::new(),
            focus_go_to_line_input: false,
            message: "Ready".into(),
            last_file_check: Instant::now(),
        };
        let restore_session = !options.empty
            && (options.paths.is_empty()
                || (options.paths.len() == 1 && PathBuf::from(&options.paths[0]).is_dir()));
        app.load_start_paths(&options.paths, options.empty);
        if options.empty && options.paths.is_empty() {
            app.session_enabled = false;
        }
        if restore_session {
            app.restore_project_session();
        }
        if app.documents.is_empty() && !options.empty {
            app.new_document();
        }
        app
    }

    fn new_document(&mut self) {
        self.session_enabled = true;
        let document = Document::untitled(self.next_document_id);
        self.next_document_id += 1;
        self.documents.push(document);
        self.active = Some(self.documents.len() - 1);
    }

    fn load_start_paths(&mut self, paths: &[std::ffi::OsString], empty: bool) {
        let mut found_directory = false;
        for path in paths {
            let path = PathBuf::from(path);
            if path.is_dir() {
                found_directory = true;
                self.set_project(&path);
            } else if path.is_file() {
                self.open_file(&path);
            } else {
                self.message = format!("Could not open {}: path does not exist", path.display());
            }
        }
        if !found_directory && paths.is_empty() && !empty {
            if let Ok(path) = std::env::current_dir() {
                self.set_project(&path);
            }
        } else if !found_directory
            && let Some(path) = paths.first().map(PathBuf::from)
            && let Some(parent) = path.parent()
        {
            self.set_project(parent);
        }
    }

    fn set_project(&mut self, path: &Path) {
        self.project_root = Some(fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf()));
        self.session_enabled = true;
        self.set_workspace(path);
    }

    fn set_workspace(&mut self, path: &Path) {
        match Workspace::open(path) {
            Ok(workspace) => {
                self.message = format!("Project: {}", workspace.root.display());
                self.workspace = Some(workspace);
                self.expanded_directories.clear();
            }
            Err(error) => self.message = format!("Could not browse {}: {error}", path.display()),
        }
    }

    fn open_file(&mut self, path: &Path) {
        self.session_enabled = true;
        let key = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        if let Some((index, _)) = self.documents.iter().enumerate().find(|(_, doc)| {
            doc.path
                .as_deref()
                .map(|open_path| fs::canonicalize(open_path).unwrap_or_else(|_| open_path.into()))
                .as_deref()
                == Some(key.as_path())
        }) {
            self.active = Some(index);
            return;
        }
        match Document::open(self.next_document_id, path) {
            Ok(document) => {
                self.next_document_id += 1;
                self.documents.push(document);
                self.active = Some(self.documents.len() - 1);
                if self.workspace.is_none()
                    && let Some(parent) = path.parent()
                {
                    self.set_project(parent);
                }
                self.message = format!("Opened {}", path.display());
            }
            Err(error) => self.message = format!("Could not open {}: {error}", path.display()),
        }
    }

    fn save_document(&mut self, index: usize) -> bool {
        let path = if self.save_as_pending {
            if self.path_input.trim().is_empty() {
                self.message = "Enter a file path above, then choose Save".into();
                self.focus_path_input = true;
                return false;
            }
            Some(PathBuf::from(self.path_input.trim()))
        } else if self.documents[index].path.is_some() {
            None
        } else if self.path_input.trim().is_empty() {
            self.message = "Enter a file path above, then choose Save".into();
            self.focus_path_input = true;
            return false;
        } else {
            Some(PathBuf::from(self.path_input.trim()))
        };
        match self.documents[index].save_with_options(
            path.as_deref(),
            self.editor_settings.trim_trailing_whitespace,
            self.editor_settings.final_newline,
        ) {
            Ok(()) => {
                self.save_as_pending = false;
                let project_parent = if self.project_root.is_none() {
                    self.documents[index]
                        .path
                        .as_deref()
                        .and_then(Path::parent)
                        .map(Path::to_path_buf)
                } else {
                    None
                };
                if let Some(parent) = project_parent {
                    self.set_project(&parent);
                }
                self.message = format!(
                    "Saved {}",
                    self.documents[index]
                        .path
                        .as_deref()
                        .unwrap_or_else(|| Path::new("Untitled"))
                        .display()
                );
                true
            }
            Err(error) => {
                self.message = format!("Could not save file: {error}");
                false
            }
        }
    }

    fn save_active(&mut self) {
        let Some(index) = self.active else {
            self.message = "There is no open document to save".into();
            return;
        };
        self.save_document(index);
    }

    fn save_active_as(&mut self) {
        let Some(index) = self.active else {
            self.message = "There is no open document to save".into();
            return;
        };
        if let Some(path) = &self.documents[index].path {
            self.path_input = path.to_string_lossy().into_owned();
        }
        self.save_as_pending = true;
        self.focus_path_input = true;
        self.message = "Choose a path above, then choose Save".into();
    }

    fn request_close_document(&mut self, index: usize) {
        let Some(document) = self.documents.get(index) else {
            return;
        };
        if document.is_dirty() {
            self.pending_close = Some(PendingClose {
                document_id: document.id,
                after: CloseAfter::Document,
            });
        } else {
            self.remove_document(index, true);
        }
    }

    fn remove_document(&mut self, index: usize, remember: bool) {
        let document = self.documents.remove(index);
        let anchor = document.cursor_anchor_byte_offset();
        let cursor = document.cursor_byte_offset();
        if remember && let Some(path) = document.path {
            self.closed_documents.retain(|closed| {
                fs::canonicalize(&closed.path).unwrap_or_else(|_| closed.path.clone())
                    != fs::canonicalize(&path).unwrap_or_else(|_| path.clone())
            });
            self.closed_documents.push(ClosedDocument {
                path,
                index,
                anchor,
                cursor,
            });
            if self.closed_documents.len() > 20 {
                self.closed_documents.remove(0);
            }
        }
        self.active = match self.active {
            Some(active) if active > index => Some(active - 1),
            Some(active) if active == index && self.documents.is_empty() => None,
            Some(active) if active == index => Some(index.min(self.documents.len() - 1)),
            active => active,
        };
    }

    fn close_all_documents(&mut self) {
        if let Some(document_id) = first_dirty_document(&self.documents) {
            self.pending_close = Some(PendingClose {
                document_id,
                after: CloseAfter::All,
            });
            self.active = self
                .documents
                .iter()
                .position(|document| document.id == document_id);
        } else {
            while let Some(index) = self.documents.len().checked_sub(1) {
                self.remove_document(index, true);
            }
        }
    }

    fn begin_exit(&mut self, context: &egui::Context) {
        if self.close_approved {
            return;
        }
        if let Some(document_id) = first_dirty_document(&self.documents) {
            self.pending_close = Some(PendingClose {
                document_id,
                after: CloseAfter::Exit,
            });
            context.send_viewport_cmd(egui::ViewportCommand::CancelClose);
        } else {
            self.save_project_session();
            self.close_approved = true;
        }
    }

    fn resolve_pending_close(&mut self, context: &egui::Context, choice: CloseChoice) {
        let Some(pending) = self.pending_close else {
            return;
        };
        if matches!(choice, CloseChoice::Cancel) {
            self.pending_close = None;
            return;
        }
        let Some(index) = self
            .documents
            .iter()
            .position(|document| document.id == pending.document_id)
        else {
            self.pending_close = None;
            return;
        };
        if matches!(choice, CloseChoice::Save) && !self.save_document(index) {
            return;
        }
        self.remove_document(index, !matches!(pending.after, CloseAfter::Exit));
        self.pending_close = None;

        match pending.after {
            CloseAfter::Exit => {
                if let Some(document_id) = first_dirty_document(&self.documents) {
                    self.pending_close = Some(PendingClose {
                        document_id,
                        after: CloseAfter::Exit,
                    });
                } else {
                    self.save_project_session();
                    self.close_approved = true;
                    context.send_viewport_cmd(egui::ViewportCommand::Close);
                }
            }
            CloseAfter::All => self.close_all_documents(),
            CloseAfter::Document => {}
        }
    }

    fn reopen_closed_document(&mut self) {
        while let Some(closed) = self.closed_documents.pop() {
            if !closed.path.is_file() {
                continue;
            }
            let key = fs::canonicalize(&closed.path).unwrap_or_else(|_| closed.path.clone());
            if self.documents.iter().any(|document| {
                document.path.as_deref().is_some_and(|path| {
                    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf()) == key
                })
            }) {
                continue;
            }
            match Document::open(self.next_document_id, &closed.path) {
                Ok(mut document) => {
                    document.set_selection_byte_offsets(closed.anchor, closed.cursor);
                    self.next_document_id += 1;
                    let index = closed.index.min(self.documents.len());
                    self.documents.insert(index, document);
                    self.active = Some(index);
                    self.message = format!("Reopened {}", closed.path.display());
                    return;
                }
                Err(error) => {
                    self.message = format!("Could not reopen {}: {error}", closed.path.display());
                }
            }
        }
        if self.message == "Ready" {
            self.message = "No recently closed file to reopen".into();
        }
    }

    fn show_close_confirmation(&mut self, context: &egui::Context) {
        let Some(pending) = self.pending_close else {
            return;
        };
        let title = self
            .documents
            .iter()
            .find(|document| document.id == pending.document_id)
            .map(Document::title)
            .unwrap_or_else(|| "Untitled".into());
        let mut choice = None;
        egui::Modal::new(egui::Id::new("unsaved_changes")).show(context, |ui| {
            ui.label(format!("Save changes to {title} before closing?"));
            ui.horizontal(|ui| {
                if ui.button("Save").clicked() {
                    choice = Some(CloseChoice::Save);
                }
                if ui.button("Discard").clicked() {
                    choice = Some(CloseChoice::Discard);
                }
                if ui.button("Cancel").clicked() {
                    choice = Some(CloseChoice::Cancel);
                }
            });
            if matches!(pending.after, CloseAfter::Exit | CloseAfter::All) {
                ui.label("The application will ask about each modified file.");
            }
        });
        if let Some(choice) = choice {
            self.resolve_pending_close(context, choice);
        }
    }

    fn open_path_input(&mut self) {
        if self.save_as_pending {
            self.save_active();
            return;
        }
        if self.open_folder_pending {
            self.open_folder_path_input();
            return;
        }
        let value = self.path_input.trim();
        if value.is_empty() {
            self.message = "Type a file or folder path first".into();
            return;
        }
        let path = PathBuf::from(value);
        if path.is_dir() {
            self.set_project(&path);
        } else if path.is_file() {
            self.open_file(&path);
        } else {
            self.message = format!("Could not open {}: path does not exist", path.display());
        }
    }

    fn open_folder_path_input(&mut self) {
        let value = self.path_input.trim();
        if value.is_empty() {
            self.message = "Type a folder path first".into();
            return;
        }
        let path = PathBuf::from(value);
        if path.is_dir() {
            self.set_project(&path);
            self.open_folder_pending = false;
        } else {
            self.message = format!("Could not open folder {}: not a directory", path.display());
        }
    }

    fn restore_project_session(&mut self) {
        let Some(project) = self.project_root.as_deref() else {
            return;
        };
        match session::load_project(project) {
            Ok(saved_documents) => {
                let mut active_path = None;
                for saved in saved_documents {
                    if !saved.path.is_file() {
                        continue;
                    }
                    if saved.active {
                        active_path = Some(saved.path.clone());
                    }
                    self.open_file(&saved.path);
                    if let Some(document) = self.documents.iter_mut().find(|document| {
                        document.path.as_deref().is_some_and(|path| {
                            fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
                                == fs::canonicalize(&saved.path)
                                    .unwrap_or_else(|_| saved.path.clone())
                        })
                    }) {
                        document.set_cursor_byte_offset(saved.cursor);
                    }
                }
                if let Some(path) = active_path {
                    let canonical = fs::canonicalize(&path).unwrap_or(path);
                    if let Some(index) = self.documents.iter().position(|document| {
                        document.path.as_deref().is_some_and(|open_path| {
                            fs::canonicalize(open_path).unwrap_or_else(|_| open_path.into())
                                == canonical
                        })
                    }) {
                        self.active = Some(index);
                    }
                }
            }
            Err(error) => {
                self.message = format!("Could not restore project session: {error}");
            }
        }
    }

    fn save_project_session(&mut self) {
        if !self.session_enabled {
            return;
        }
        let Some(project) = self.project_root.as_deref() else {
            return;
        };
        let documents = self
            .documents
            .iter()
            .enumerate()
            .filter_map(|(index, document)| {
                document.path.as_ref().map(|path| SessionDocument {
                    path: path.clone(),
                    cursor: document.cursor_byte_offset(),
                    active: self.active == Some(index),
                })
            })
            .collect::<Vec<_>>();
        if let Err(error) = session::save_project(project, &documents) {
            self.message = format!("Could not save project session: {error}");
            eprintln!("rhun: could not save project session: {error}");
        }
    }

    fn replace_all(&mut self) {
        let Some(index) = self.active else {
            self.message = "Open a document before searching".into();
            return;
        };
        if self.find_input.is_empty() {
            self.message = "Enter text to find".into();
            return;
        }
        let document = &mut self.documents[index];
        let matches = find_matches(&document.text, &self.find_input).len();
        let cursor = document.cursor;
        let cursor_anchor = document.cursor_anchor;
        let original_text = document.text.clone();
        document.text =
            replace_all_matches(&document.text, &self.find_input, &self.replace_input).0;
        if document.text != original_text {
            document.record_text_edit(cursor, cursor_anchor, false);
        }
        self.message = format!("Replaced {matches} occurrence(s)");
    }

    fn find(&mut self, backwards: bool) {
        let Some(index) = self.active else {
            self.message = "Open a document before searching".into();
            return;
        };
        if self.find_input.is_empty() {
            self.message = "Enter text to find".into();
            return;
        }
        let document = &mut self.documents[index];
        let range = if backwards {
            let position = document
                .cursor_anchor_byte_offset()
                .min(document.cursor_byte_offset());
            find_previous(&document.text, &self.find_input, position)
        } else {
            let position = document
                .cursor_anchor_byte_offset()
                .max(document.cursor_byte_offset());
            find_next(&document.text, &self.find_input, position)
        };
        if let Some((start, end)) = range {
            if backwards {
                document.set_selection_byte_offsets(end, start);
            } else {
                document.set_selection_byte_offsets(start, end);
            }
            self.message = format!("Found {}", self.find_input);
        } else {
            self.message = format!("No matches for {}", self.find_input);
        }
    }

    fn replace_one(&mut self) {
        let Some(index) = self.active else {
            self.message = "Open a document before replacing text".into();
            return;
        };
        if self.find_input.is_empty() {
            self.message = "Enter text to find".into();
            return;
        }
        let document = &mut self.documents[index];
        let start = document
            .cursor_anchor_byte_offset()
            .min(document.cursor_byte_offset());
        let end = document
            .cursor_anchor_byte_offset()
            .max(document.cursor_byte_offset());
        let previous_cursor = document.cursor;
        let previous_anchor = document.cursor_anchor;
        if let Some(cursor) = replace_selected_match(
            &mut document.text,
            &self.find_input,
            &self.replace_input,
            start,
            end,
        ) {
            document.record_text_edit(previous_cursor, previous_anchor, false);
            document.set_cursor_byte_offset(cursor);
            self.message = "Replaced 1 occurrence".into();
            self.find(false);
        } else {
            self.find(false);
        }
    }

    fn go_to_line(&mut self) {
        let Some(index) = self.active else {
            self.message = "Open a document before going to a line".into();
            return;
        };
        let line = match self.go_to_line_input.trim().parse::<usize>() {
            Ok(line) if line > 0 => line,
            _ => {
                self.message = "Enter a line number greater than zero".into();
                return;
            }
        };
        let document = &mut self.documents[index];
        let offset = line_start_offset(&document.text, line);
        document.set_cursor_byte_offset(offset);
        self.message = format!("Line {line}");
        self.go_to_line_open = false;
    }

    fn start_project_search(&mut self) {
        let query = self.project_search_input.trim().to_owned();
        if query.is_empty() {
            self.project_search_status = "Enter text to search for".into();
            return;
        }
        let root = self
            .project_root
            .clone()
            .or_else(|| std::env::current_dir().ok());
        let Some(root) = root else {
            self.project_search_status = "Could not determine the project folder".into();
            return;
        };
        self.project_search_root = Some(root.clone());
        let (sender, receiver) = mpsc::channel();
        self.project_search_receiver = Some(receiver);
        self.project_search_results.clear();
        self.project_search_status = "Searching project…".into();
        thread::spawn(move || {
            let _ = sender.send(search_project(&root, &query));
        });
    }

    fn poll_project_search(&mut self) {
        let Some(receiver) = &self.project_search_receiver else {
            return;
        };
        match receiver.try_recv() {
            Ok(Ok(results)) => {
                self.project_search_status = format!(
                    "{} match(es) in {} file(s); skipped {} binary, invalid, or large file(s){}",
                    results.matches.len(),
                    results.scanned_files,
                    results.skipped_files,
                    if results.truncated {
                        " (showing first 1000)"
                    } else {
                        ""
                    }
                );
                self.project_search_results = results.matches;
                self.project_search_receiver = None;
            }
            Ok(Err(error)) => {
                self.project_search_status = format!("Project search failed: {error}");
                self.project_search_receiver = None;
            }
            Err(TryRecvError::Disconnected) => {
                self.project_search_status = "Project search worker stopped unexpectedly".into();
                self.project_search_receiver = None;
            }
            Err(TryRecvError::Empty) => {}
        }
    }

    fn start_quick_open_search(&mut self) {
        let query = self.quick_open_input.trim().to_owned();
        if query.is_empty() {
            self.quick_open_results.clear();
            self.quick_open_status = "Type part of a file name".into();
            return;
        }
        let root = self
            .project_root
            .clone()
            .or_else(|| std::env::current_dir().ok());
        let Some(root) = root else {
            self.quick_open_status = "Could not determine the project folder".into();
            return;
        };
        self.quick_open_root = Some(root.clone());
        let (sender, receiver) = mpsc::channel();
        self.quick_open_receiver = Some(receiver);
        self.quick_open_results.clear();
        self.quick_open_status = "Searching files…".into();
        thread::spawn(move || {
            let _ = sender.send(search_files(&root, &query));
        });
    }

    fn poll_quick_open_search(&mut self) {
        let Some(receiver) = &self.quick_open_receiver else {
            return;
        };
        match receiver.try_recv() {
            Ok(Ok(results)) => {
                self.quick_open_status = format!(
                    "{} file(s) in {} scanned{}",
                    results.matches.len(),
                    results.scanned_files,
                    if results.truncated {
                        " (limited results)"
                    } else {
                        ""
                    }
                );
                self.quick_open_results = results.matches;
                self.quick_open_receiver = None;
            }
            Ok(Err(error)) => {
                self.quick_open_status = format!("File search failed: {error}");
                self.quick_open_receiver = None;
            }
            Err(TryRecvError::Disconnected) => {
                self.quick_open_status = "File search worker stopped unexpectedly".into();
                self.quick_open_receiver = None;
            }
            Err(TryRecvError::Empty) => {}
        }
    }

    fn check_external_changes(&mut self) {
        if self.last_file_check.elapsed() < Duration::from_secs(1) {
            return;
        }
        self.last_file_check = Instant::now();
        match EditorSettings::reload_if_present() {
            Ok(Some(settings)) if settings != self.editor_settings => {
                self.editor_settings = settings;
                self.message = "Reloaded editor and file settings".into();
            }
            Ok(Some(_)) | Ok(None) => {}
            Err(error) => {
                self.message = format!("Could not reload settings: {error}");
            }
        }
        for document in &mut self.documents {
            if document.is_dirty() {
                continue;
            }
            match document.reload_if_changed() {
                Ok(true) => self.message = format!("Reloaded {}", document.title()),
                Ok(false) => {}
                Err(error) => {
                    self.message = format!("Could not check {}: {error}", document.title())
                }
            }
        }
    }

    fn handle_shortcuts(&mut self, context: &egui::Context) {
        if self.pending_close.is_some() {
            return;
        }
        let editor_focused = self.active.is_some_and(|index| {
            let editor_id = egui::Id::new(("editor", self.documents[index].id));
            context.memory(|memory| memory.has_focus(editor_id))
        });
        let (
            new,
            save,
            save_as,
            close,
            close_all,
            quit,
            reopen_closed,
            open,
            open_folder,
            quick_open,
            find,
            replace,
            go_to_line,
            find_next,
            find_prev,
            next_tab,
            previous_tab,
            search_files,
            undo,
            redo,
            indented_newline,
            tab_indent,
            outdent,
            indent,
            duplicate_lines,
            delete_lines,
            move_lines_up,
            move_lines_down,
            toggle_comment,
            newline_below,
            newline_above,
            select_line,
        ) = context.input(|input| {
            let command = input.modifiers.command;
            (
                command && input.key_pressed(Key::N),
                command && !input.modifiers.shift && input.key_pressed(Key::S),
                command && input.modifiers.shift && input.key_pressed(Key::S),
                command
                    && !input.modifiers.shift
                    && (input.key_pressed(Key::W) || input.key_pressed(Key::F4)),
                command && input.modifiers.shift && input.key_pressed(Key::W),
                command && input.key_pressed(Key::Q),
                command && input.modifiers.shift && input.key_pressed(Key::T),
                command && !input.modifiers.shift && input.key_pressed(Key::O),
                command && input.modifiers.shift && input.key_pressed(Key::O),
                command
                    && !input.modifiers.shift
                    && (input.key_pressed(Key::P) || input.key_pressed(Key::E)),
                command && !input.modifiers.shift && input.key_pressed(Key::F),
                command && input.key_pressed(Key::H),
                command && input.key_pressed(Key::G),
                input.key_pressed(Key::F3) && !input.modifiers.shift,
                input.key_pressed(Key::F3) && input.modifiers.shift,
                command
                    && !input.modifiers.shift
                    && (input.key_pressed(Key::Tab) || input.key_pressed(Key::PageDown)),
                command
                    && (input.key_pressed(Key::PageUp)
                        || (input.modifiers.shift && input.key_pressed(Key::Tab))),
                command && input.modifiers.shift && input.key_pressed(Key::F),
                editor_focused && command && !input.modifiers.shift && input.key_pressed(Key::Z),
                editor_focused
                    && command
                    && ((input.modifiers.shift && input.key_pressed(Key::Z))
                        || input.key_pressed(Key::Y)),
                editor_focused
                    && !input.modifiers.command
                    && !input.modifiers.shift
                    && input.key_pressed(Key::Enter),
                editor_focused && !command && !input.modifiers.shift && input.key_pressed(Key::Tab),
                editor_focused && command && input.key_pressed(Key::OpenBracket),
                editor_focused && command && input.key_pressed(Key::CloseBracket),
                editor_focused && command && input.modifiers.shift && input.key_pressed(Key::D),
                editor_focused && command && input.modifiers.shift && input.key_pressed(Key::K),
                editor_focused && input.modifiers.alt && input.key_pressed(Key::ArrowUp),
                editor_focused && input.modifiers.alt && input.key_pressed(Key::ArrowDown),
                editor_focused && command && input.key_pressed(Key::Slash),
                editor_focused
                    && command
                    && !input.modifiers.shift
                    && input.key_pressed(Key::Enter),
                editor_focused && command && input.modifiers.shift && input.key_pressed(Key::Enter),
                editor_focused && command && input.key_pressed(Key::L),
            )
        });
        let indent_unit = self.editor_settings.indent_unit();
        if select_line {
            context.input_mut(|input| {
                input.consume_key(egui::Modifiers::COMMAND, Key::L);
            });
            if let Some(index) = self.active {
                self.documents[index].select_line();
                self.documents[index].restore_cursor = true;
            }
        }
        if newline_below || newline_above {
            context.input_mut(|input| {
                input.consume_key(egui::Modifiers::COMMAND, Key::Enter);
                input.consume_key(
                    egui::Modifiers::COMMAND | egui::Modifiers::SHIFT,
                    Key::Enter,
                );
            });
            if let Some(index) = self.active {
                if newline_below {
                    self.documents[index].insert_newline_below(&indent_unit);
                } else {
                    self.documents[index].insert_newline_above(&indent_unit);
                }
            }
        }
        if toggle_comment {
            context.input_mut(|input| {
                input.consume_key(egui::Modifiers::COMMAND, Key::Slash);
            });
            if let Some(index) = self.active {
                let token = self.documents[index]
                    .path
                    .as_deref()
                    .and_then(crate::comments::token_for_path);
                if let Some(token) = token {
                    self.documents[index].toggle_line_comments(token);
                } else {
                    self.message = "No line-comment syntax for this file".into();
                }
            }
        }
        if undo || redo {
            context.input_mut(|input| {
                input.consume_key(egui::Modifiers::COMMAND, Key::Z);
                input.consume_key(egui::Modifiers::COMMAND | egui::Modifiers::SHIFT, Key::Z);
                input.consume_key(egui::Modifiers::COMMAND, Key::Y);
            });
        }
        if indented_newline {
            context.input_mut(|input| {
                input.consume_key(egui::Modifiers::NONE, Key::Enter);
            });
            if let Some(index) = self.active {
                self.documents[index].insert_indented_newline(&indent_unit);
            }
        }
        if tab_indent {
            context.input_mut(|input| {
                input.consume_key(egui::Modifiers::NONE, Key::Tab);
            });
            if let Some(index) = self.active {
                self.documents[index].insert_tab_indent(
                    &indent_unit,
                    self.editor_settings.tab_width,
                    self.editor_settings.insert_spaces,
                );
            }
        }
        if outdent {
            context.input_mut(|input| {
                input.consume_key(egui::Modifiers::COMMAND, Key::OpenBracket);
            });
            if let Some(index) = self.active {
                self.documents[index].outdent_selection(self.editor_settings.tab_width);
            }
        }
        if indent {
            context.input_mut(|input| {
                input.consume_key(egui::Modifiers::COMMAND, Key::CloseBracket);
            });
            if let Some(index) = self.active {
                self.documents[index].indent_selection(&indent_unit);
            }
        }
        if duplicate_lines || delete_lines || move_lines_up || move_lines_down {
            context.input_mut(|input| {
                input.consume_key(egui::Modifiers::COMMAND | egui::Modifiers::SHIFT, Key::D);
                input.consume_key(egui::Modifiers::COMMAND | egui::Modifiers::SHIFT, Key::K);
                input.consume_key(egui::Modifiers::ALT, Key::ArrowUp);
                input.consume_key(egui::Modifiers::ALT, Key::ArrowDown);
            });
            if let Some(index) = self.active {
                if duplicate_lines {
                    self.documents[index].duplicate_selected_lines();
                } else if delete_lines {
                    self.documents[index].delete_selected_lines();
                } else {
                    let moved = self.documents[index].move_selected_lines(move_lines_down);
                    self.message = if moved {
                        "Moved selected line(s)".into()
                    } else {
                        "Cannot move selected lines further".into()
                    };
                }
            }
        }
        if new {
            self.new_document();
        }
        if save {
            self.save_active();
        }
        if save_as {
            self.save_active_as();
        }
        if close && let Some(index) = self.active {
            self.request_close_document(index);
        }
        if close_all {
            self.close_all_documents();
        }
        if quit {
            context.send_viewport_cmd(egui::ViewportCommand::Close);
        }
        if reopen_closed {
            self.reopen_closed_document();
        }
        if open {
            self.open_folder_pending = false;
            self.focus_path_input = true;
        }
        if open_folder {
            self.open_folder_pending = true;
            self.focus_path_input = true;
        }
        if quick_open {
            self.quick_open_open = !self.quick_open_open;
            if self.quick_open_open {
                self.focus_quick_open_input = true;
            }
        }
        if find {
            self.find_open = !self.find_open;
            self.replace_open = false;
            self.focus_find_input = self.find_open;
        }
        if replace {
            self.find_open = true;
            self.replace_open = true;
            self.focus_find_input = true;
        }
        if go_to_line {
            self.go_to_line_open = true;
            self.focus_go_to_line_input = true;
        }
        if search_files {
            self.project_search_open = !self.project_search_open;
            if self.project_search_open {
                self.focus_project_search_input = true;
                self.start_project_search();
            }
        }
        if (undo || redo)
            && let Some(index) = self.active
        {
            let changed = if undo {
                self.documents[index].undo()
            } else {
                self.documents[index].redo()
            };
            self.message = if changed {
                if undo {
                    "Undid edit".into()
                } else {
                    "Redid edit".into()
                }
            } else if undo {
                "Nothing to undo".into()
            } else {
                "Nothing to redo".into()
            };
        }
        if find_next {
            self.find(false);
        }
        if find_prev {
            self.find(true);
        }
        if next_tab && !self.documents.is_empty() {
            self.active = Some((self.active.unwrap_or(0) + 1) % self.documents.len());
        }
        if previous_tab && !self.documents.is_empty() {
            self.active = Some(
                self.active
                    .unwrap_or(0)
                    .checked_sub(1)
                    .unwrap_or(self.documents.len() - 1),
            );
        }
    }

    fn show_tabs(&mut self, ui: &mut egui::Ui) {
        let mut close_requested = None;
        egui::ScrollArea::horizontal()
            .id_salt("document_tabs")
            .show(ui, |ui| {
                ui.horizontal(|ui| {
                    for (index, document) in self.documents.iter().enumerate() {
                        let label = if document.is_dirty() {
                            format!("● {}", document.title())
                        } else {
                            document.title()
                        };
                        let response = ui.selectable_label(
                            self.active == Some(index),
                            RichText::new(label).monospace(),
                        );
                        if response.clicked() {
                            self.active = Some(index);
                        }
                        if ui.small_button("×").on_hover_text("Close tab").clicked() {
                            close_requested = Some(index);
                        }
                        ui.separator();
                    }
                    if ui.button("+").on_hover_text("New file (Ctrl+N)").clicked() {
                        self.new_document();
                    }
                });
            });
        if let Some(index) = close_requested {
            self.request_close_document(index);
        }
    }

    fn process_paired_text(context: &egui::Context, document: &mut Document, auto_pairs: bool) {
        if !auto_pairs {
            return;
        }
        let candidates = context.input(|input| {
            input
                .events
                .iter()
                .enumerate()
                .filter_map(|(index, event)| match event {
                    egui::Event::Text(text) => {
                        let mut characters = text.chars();
                        let character = characters.next()?;
                        (characters.next().is_none()
                            && matches!(
                                character,
                                '(' | '[' | '{' | '"' | '\'' | '`' | ')' | ']' | '}'
                            ))
                        .then_some((index, character))
                    }
                    _ => None,
                })
                .collect::<Vec<_>>()
        });
        let handled = candidates
            .into_iter()
            .filter_map(|(index, character)| {
                document.type_paired_character(character).then_some(index)
            })
            .collect::<HashSet<_>>();
        if !handled.is_empty() {
            context.input_mut(|input| {
                input.events = std::mem::take(&mut input.events)
                    .into_iter()
                    .enumerate()
                    .filter_map(|(index, event)| (!handled.contains(&index)).then_some(event))
                    .collect();
            });
        }
    }

    fn show_editor(&mut self, ui: &mut egui::Ui) {
        let Some(index) = self.active else {
            ui.centered_and_justified(|ui| {
                ui.label("No document open. Use New or enter a file path above.");
            });
            return;
        };
        let document = &mut self.documents[index];
        Self::process_paired_text(ui.ctx(), document, self.editor_settings.auto_pairs);
        let restore_cursor = document.restore_cursor;
        let cursor_before_edit = document.cursor;
        let anchor_before_edit = document.cursor_anchor;
        let cursor = document.cursor.min(document.text.chars().count());
        let anchor = document.cursor_anchor.min(document.text.chars().count());
        let editor_id = egui::Id::new(("editor", document.id));
        let editor = TextEdit::multiline(&mut document.text)
            .id(editor_id)
            .font(egui::TextStyle::Monospace)
            .code_editor()
            .desired_width(f32::INFINITY)
            .desired_rows(1)
            .frame(false)
            .lock_focus(true);
        let (updated_cursor, text_changed) = egui::ScrollArea::both()
            .id_salt(("editor_scroll", document.id))
            .auto_shrink([false, false])
            .show(ui, |ui| {
                let mut output = editor.show(ui);
                let text_changed = output.response.changed();
                if restore_cursor {
                    let range = CCursorRange::two(CCursor::new(anchor), CCursor::new(cursor));
                    output.state.cursor.set_char_range(Some(range));
                    output.state.store(ui.ctx(), editor_id);
                    output.response.request_focus();
                    (Some((anchor, cursor)), text_changed)
                } else {
                    let cursor = output
                        .state
                        .cursor
                        .char_range()
                        .map(|range| (range.secondary.index, range.primary.index));
                    (cursor, text_changed)
                }
            })
            .inner;
        if let Some((anchor, cursor)) = updated_cursor {
            document.cursor_anchor = anchor;
            document.cursor = cursor;
        }
        if text_changed {
            document.record_text_edit(cursor_before_edit, anchor_before_edit, true);
        }
        if restore_cursor {
            document.restore_cursor = false;
        }
    }

    fn show_status(&self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            let file = self
                .active
                .and_then(|index| self.documents.get(index))
                .map(Document::title)
                .unwrap_or_else(|| "No file".into());
            ui.label(RichText::new(file).monospace());
            ui.separator();
            if let Some(project) = &self.project_root {
                ui.label(format!("Project: {}", project.display()));
                ui.separator();
            }
            ui.label(&self.message);
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                ui.label("Ctrl+N New  Ctrl+O Open  Ctrl+S Save  Ctrl+Z Undo  Ctrl+Y Redo  Ctrl+Shift+S Save As  Ctrl+Shift+T Reopen");
            });
        });
    }

    fn show_workspace(&mut self, context: &egui::Context) {
        let mut requested_path = None;
        let mut toggle_directory = None;
        let workspace_view = self.workspace.as_ref().map(|workspace| {
            (
                workspace.root.clone(),
                workspace.visible_entries(&self.expanded_directories),
            )
        });
        egui::SidePanel::left("workspace_explorer")
            .default_width(240.0)
            .resizable(true)
            .show(context, |ui| {
                ui.horizontal(|ui| {
                    ui.heading("Files");
                    if ui.button("↻").on_hover_text("Refresh file list").clicked()
                        && let Some(workspace) = &mut self.workspace
                    {
                        match workspace.refresh_expanded(&self.expanded_directories) {
                            Ok(()) => {
                                self.message = "File list refreshed".into();
                            }
                            Err(error) => {
                                self.message = format!("Could not refresh files: {error}")
                            }
                        }
                    }
                });
                if let Some((root, entries)) = &workspace_view {
                    ui.horizontal(|ui| {
                        ui.label(root.display().to_string());
                        if let Some(parent) = root.parent()
                            && ui.button("..").on_hover_text("Parent folder").clicked()
                        {
                            requested_path = Some(parent.to_path_buf());
                        }
                    });
                    egui::ScrollArea::vertical().show(ui, |ui| {
                        for (entry, depth) in entries {
                            ui.horizontal(|ui| {
                                ui.add_space(*depth as f32 * 14.0);
                                if entry.is_directory {
                                    let expanded = self.expanded_directories.contains(&entry.path);
                                    if ui
                                        .small_button(if expanded { "▾" } else { "▸" })
                                        .on_hover_text(if expanded {
                                            "Collapse folder"
                                        } else {
                                            "Expand folder"
                                        })
                                        .clicked()
                                    {
                                        toggle_directory = Some((entry.path.clone(), expanded));
                                    }
                                } else {
                                    ui.add_space(20.0);
                                }
                                if ui
                                    .selectable_label(false, RichText::new(&entry.name).monospace())
                                    .clicked()
                                {
                                    if entry.is_directory {
                                        requested_path = Some(entry.path.clone());
                                    } else {
                                        self.open_file(&entry.path);
                                    }
                                }
                            });
                        }
                    });
                } else {
                    ui.label("Open a folder path to browse its files.");
                }
            });
        if let Some(path) = requested_path {
            self.set_workspace(&path);
        }
        if let Some((path, was_expanded)) = toggle_directory {
            if was_expanded {
                self.expanded_directories.remove(&path);
            } else if let Some(workspace) = &mut self.workspace {
                match workspace.load_directory(&path) {
                    Ok(()) => {
                        self.expanded_directories.insert(path);
                    }
                    Err(error) => {
                        self.message = format!("Could not expand folder: {error}");
                    }
                }
            }
        }
    }

    fn show_project_search(&mut self, context: &egui::Context) {
        if !self.project_search_open {
            return;
        }
        let mut search_requested = false;
        let mut selected_path = None;
        egui::TopBottomPanel::top("project_search").show(context, |ui| {
            ui.horizontal(|ui| {
                ui.label("Find in files");
                let response = ui.add(
                    TextEdit::singleline(&mut self.project_search_input)
                        .desired_width(300.0)
                        .hint_text("Search project text"),
                );
                if self.focus_project_search_input {
                    response.request_focus();
                    self.focus_project_search_input = false;
                }
                if response.lost_focus() && ui.input(|input| input.key_pressed(Key::Enter)) {
                    search_requested = true;
                }
                if ui.button("Search").clicked() {
                    search_requested = true;
                }
                if ui.button("×").clicked() {
                    self.project_search_open = false;
                }
                ui.label(&self.project_search_status);
            });
            egui::ScrollArea::vertical()
                .max_height(180.0)
                .show(ui, |ui| {
                    for result in &self.project_search_results {
                        let label = format!(
                            "{}:{}  {}",
                            result.path.display(),
                            result.line_number,
                            result.line.trim()
                        );
                        if ui.selectable_label(false, label).clicked() {
                            selected_path = Some(result.path.clone());
                        }
                    }
                });
        });
        if search_requested {
            self.start_project_search();
        }
        if let Some(path) = selected_path
            && let Some(root) = self.project_search_root.clone()
        {
            self.open_file(&root.join(path));
        }
    }

    fn show_quick_open(&mut self, context: &egui::Context) {
        if !self.quick_open_open {
            return;
        }
        let mut search_requested = false;
        let mut selected_path = None;
        egui::TopBottomPanel::top("quick_open").show(context, |ui| {
            ui.horizontal(|ui| {
                ui.label("Go to file");
                let response = ui.add(
                    TextEdit::singleline(&mut self.quick_open_input)
                        .desired_width(360.0)
                        .hint_text("Type part of a file name"),
                );
                if self.focus_quick_open_input {
                    response.request_focus();
                    self.focus_quick_open_input = false;
                }
                if response.lost_focus() && ui.input(|input| input.key_pressed(Key::Enter)) {
                    search_requested = true;
                }
                if ui.button("Search").clicked() {
                    search_requested = true;
                }
                if ui.button("×").clicked() {
                    self.quick_open_open = false;
                }
                ui.label(&self.quick_open_status);
            });
            egui::ScrollArea::vertical()
                .max_height(220.0)
                .show(ui, |ui| {
                    for result in &self.quick_open_results {
                        if ui
                            .selectable_label(false, result.path.display().to_string())
                            .clicked()
                        {
                            selected_path = Some(result.path.clone());
                        }
                    }
                });
        });
        if search_requested {
            self.start_quick_open_search();
        }
        if let Some(path) = selected_path
            && let Some(root) = self.quick_open_root.clone()
        {
            self.open_file(&root.join(path));
            self.quick_open_open = false;
        }
    }
}

impl App for RhunApp {
    fn update(&mut self, context: &egui::Context, _frame: &mut Frame) {
        if context.input(|input| input.viewport().close_requested()) && !self.close_approved {
            self.begin_exit(context);
        }
        self.check_external_changes();
        self.poll_project_search();
        self.poll_quick_open_search();
        self.handle_shortcuts(context);
        context.request_repaint_after(Duration::from_secs(1));

        egui::TopBottomPanel::top("rhun_toolbar").show(context, |ui| {
            ui.horizontal(|ui| {
                if ui.button("New").clicked() {
                    self.new_document();
                }
                if ui.button("Save").clicked() {
                    self.save_active();
                }
                ui.separator();
                ui.label(if self.open_folder_pending {
                    "Folder"
                } else {
                    "Path"
                });
                let response = ui.add(
                    TextEdit::singleline(&mut self.path_input)
                        .hint_text(if self.open_folder_pending {
                            "Enter a folder path"
                        } else {
                            "Open file or folder; Save As for untitled files"
                        })
                        .desired_width(420.0),
                );
                if self.focus_path_input {
                    response.request_focus();
                    self.focus_path_input = false;
                }
                if response.lost_focus() && ui.input(|input| input.key_pressed(Key::Enter)) {
                    self.open_path_input();
                }
                if ui
                    .button(if self.open_folder_pending {
                        "Open Folder"
                    } else {
                        "Open"
                    })
                    .clicked()
                {
                    self.open_path_input();
                }
                if self.find_open {
                    ui.separator();
                    ui.label("Find");
                    let response = ui.add(
                        TextEdit::singleline(&mut self.find_input)
                            .desired_width(160.0)
                            .hint_text("Text"),
                    );
                    if self.focus_find_input {
                        response.request_focus();
                        self.focus_find_input = false;
                    }
                    if response.lost_focus() && ui.input(|input| input.key_pressed(Key::Enter)) {
                        self.find(false);
                    }
                    if ui.button("Previous").clicked() {
                        self.find(true);
                    }
                    if ui.button("Next").clicked() {
                        self.find(false);
                    }
                    if self.replace_open {
                        ui.label("Replace");
                        ui.add(
                            TextEdit::singleline(&mut self.replace_input)
                                .desired_width(160.0)
                                .hint_text("Replacement"),
                        );
                        if ui.button("Replace").clicked() {
                            self.replace_one();
                        }
                        if ui.button("Replace all").clicked() {
                            self.replace_all();
                        }
                    }
                    if ui.button("×").on_hover_text("Close find").clicked() {
                        self.find_open = false;
                        self.replace_open = false;
                    }
                }
                if self.go_to_line_open {
                    ui.separator();
                    ui.label("Go to line");
                    let response = ui.add(
                        TextEdit::singleline(&mut self.go_to_line_input)
                            .desired_width(80.0)
                            .hint_text("Line"),
                    );
                    if self.focus_go_to_line_input {
                        response.request_focus();
                        self.focus_go_to_line_input = false;
                    }
                    if response.lost_focus() && ui.input(|input| input.key_pressed(Key::Enter)) {
                        self.go_to_line();
                    }
                    if ui.button("Go").clicked() {
                        self.go_to_line();
                    }
                    if ui.button("×").clicked() {
                        self.go_to_line_open = false;
                    }
                }
            });
        });

        self.show_workspace(context);
        egui::TopBottomPanel::top("rhun_tabs").show(context, |ui| self.show_tabs(ui));
        self.show_quick_open(context);
        self.show_project_search(context);
        egui::TopBottomPanel::bottom("rhun_status").show(context, |ui| self.show_status(ui));
        egui::CentralPanel::default().show(context, |ui| self.show_editor(ui));
        self.show_close_confirmation(context);
    }
}

fn first_dirty_document(documents: &[Document]) -> Option<u64> {
    documents
        .iter()
        .find(|document| document.is_dirty())
        .map(|document| document.id)
}

fn find_matches(text: &str, query: &str) -> Vec<(usize, usize)> {
    if query.is_empty() {
        return Vec::new();
    }
    let needle = fold_text(query);
    let mut folded = Vec::new();
    for (start, character) in text.char_indices() {
        let end = start + character.len_utf8();
        folded.extend(
            character
                .to_lowercase()
                .map(|folded_character| (folded_character, start, end)),
        );
    }
    let mut matches = Vec::new();
    let mut last_end = 0;
    for window in folded.windows(needle.len()) {
        if window
            .iter()
            .map(|(character, _, _)| *character)
            .eq(needle.iter().copied())
        {
            let start = window[0].1;
            let end = window[window.len() - 1].2;
            if start >= last_end {
                matches.push((start, end));
                last_end = end;
            }
        }
    }
    matches
}

fn find_next(text: &str, query: &str, from: usize) -> Option<(usize, usize)> {
    let matches = find_matches(text, query);
    matches
        .iter()
        .copied()
        .find(|(start, _)| *start >= from)
        .or_else(|| matches.first().copied())
}

fn find_previous(text: &str, query: &str, before: usize) -> Option<(usize, usize)> {
    let matches = find_matches(text, query);
    matches
        .iter()
        .copied()
        .take_while(|(start, _)| *start < before)
        .last()
        .or_else(|| matches.last().copied())
}

fn replace_selected_match(
    text: &mut String,
    query: &str,
    replacement: &str,
    start: usize,
    end: usize,
) -> Option<usize> {
    if query.is_empty() || end <= start || fold_text(text.get(start..end)?) != fold_text(query) {
        return None;
    }
    text.replace_range(start..end, replacement);
    Some(start + replacement.len())
}

fn fold_text(text: &str) -> Vec<char> {
    text.chars().flat_map(char::to_lowercase).collect()
}

fn replace_all_matches(text: &str, query: &str, replacement: &str) -> (String, usize) {
    let matches = find_matches(text, query);
    if matches.is_empty() {
        return (text.to_owned(), 0);
    }
    let mut result = String::with_capacity(text.len());
    let mut cursor = 0;
    for (start, end) in &matches {
        result.push_str(&text[cursor..*start]);
        result.push_str(replacement);
        cursor = *end;
    }
    result.push_str(&text[cursor..]);
    (result, matches.len())
}

fn line_start_offset(text: &str, requested_line: usize) -> usize {
    if requested_line <= 1 {
        return 0;
    }
    text.match_indices('\n')
        .nth(requested_line - 2)
        .map_or(text.len(), |(offset, _)| offset + 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exit_confirmation_selects_each_dirty_document_in_order() {
        let clean = Document::untitled(1);
        let mut dirty = Document::untitled(2);
        dirty.text.push_str("edited");
        let mut next_dirty = Document::untitled(3);
        next_dirty.text.push_str("also edited");

        assert_eq!(first_dirty_document(&[clean, dirty, next_dirty]), Some(2));
    }

    #[test]
    fn exit_confirmation_is_skipped_when_all_documents_are_clean() {
        let documents = [Document::untitled(1), Document::untitled(2)];

        assert_eq!(first_dirty_document(&documents), None);
    }

    #[test]
    fn close_all_closes_clean_documents_after_each_dirty_document_is_resolved() {
        let mut app = RhunApp::new(LaunchOptions {
            empty: true,
            ..LaunchOptions::default()
        });
        let mut first_dirty = Document::untitled(2);
        first_dirty.text.push_str("edited");
        let mut second_dirty = Document::untitled(3);
        second_dirty.text.push_str("also edited");
        app.documents = vec![
            Document::untitled(1),
            first_dirty,
            second_dirty,
            Document::untitled(4),
        ];

        app.close_all_documents();
        assert_eq!(
            app.pending_close.map(|pending| pending.document_id),
            Some(2)
        );
        let context = egui::Context::default();
        app.resolve_pending_close(&context, CloseChoice::Discard);

        assert_eq!(
            app.pending_close.map(|pending| pending.document_id),
            Some(3)
        );
        assert_eq!(
            app.documents
                .iter()
                .map(|document| document.id)
                .collect::<Vec<_>>(),
            [1, 3, 4]
        );
        app.resolve_pending_close(&context, CloseChoice::Discard);
        assert!(app.documents.is_empty());
        assert_eq!(app.active, None);
    }

    #[test]
    fn canceling_close_all_preserves_unresolved_and_clean_documents() {
        let mut app = RhunApp::new(LaunchOptions {
            empty: true,
            ..LaunchOptions::default()
        });
        let mut dirty = Document::untitled(2);
        dirty.text.push_str("edited");
        app.documents = vec![Document::untitled(1), dirty, Document::untitled(3)];
        app.close_all_documents();

        app.resolve_pending_close(&egui::Context::default(), CloseChoice::Cancel);

        assert!(app.pending_close.is_none());
        assert_eq!(
            app.documents
                .iter()
                .map(|document| document.id)
                .collect::<Vec<_>>(),
            [1, 2, 3]
        );
    }

    #[test]
    fn close_all_without_modified_documents_closes_immediately() {
        let mut app = RhunApp::new(LaunchOptions {
            empty: true,
            ..LaunchOptions::default()
        });
        app.documents = vec![Document::untitled(1), Document::untitled(2)];
        app.active = Some(1);

        app.close_all_documents();

        assert!(app.documents.is_empty());
        assert_eq!(app.active, None);
        assert!(app.pending_close.is_none());
    }

    #[test]
    fn close_all_records_file_tabs_in_order_for_reopening() {
        let unique = format!(
            "rhun-close-all-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let paths = (0..3)
            .map(|index| std::env::temp_dir().join(format!("{unique}-{index}.txt")))
            .collect::<Vec<_>>();
        for (index, path) in paths.iter().enumerate() {
            fs::write(path, format!("file {index}")).unwrap();
        }
        let mut app = RhunApp::new(LaunchOptions {
            empty: true,
            ..LaunchOptions::default()
        });
        app.documents = paths
            .iter()
            .enumerate()
            .map(|(index, path)| Document::open(index as u64 + 1, path).unwrap())
            .collect();
        app.active = Some(1);

        app.close_all_documents();
        for (index, path) in paths.iter().enumerate() {
            app.reopen_closed_document();
            assert_eq!(app.documents[index].path.as_deref(), Some(path.as_path()));
        }
        assert_eq!(app.documents.len(), paths.len());

        for path in paths {
            fs::remove_file(path).unwrap();
        }
    }

    #[test]
    fn reopening_a_closed_file_restores_its_tab_position_and_utf8_selection() {
        let path = std::env::temp_dir().join(format!(
            "rhun-reopen-{}-{}.rs",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&path, "one café two").unwrap();
        let mut closed = Document::open(2, &path).unwrap();
        closed.set_selection_byte_offsets(9, 4);
        let mut app = RhunApp::new(LaunchOptions {
            empty: true,
            ..LaunchOptions::default()
        });
        app.documents = vec![Document::untitled(1), closed, Document::untitled(3)];
        app.active = Some(1);

        app.request_close_document(1);
        assert_eq!(app.documents.len(), 2);
        app.reopen_closed_document();

        assert_eq!(app.documents[1].path.as_deref(), Some(path.as_path()));
        assert_eq!(app.active, Some(1));
        assert_eq!(app.documents[1].cursor_anchor_byte_offset(), 9);
        assert_eq!(app.documents[1].cursor_byte_offset(), 4);
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn reopening_skips_missing_or_already_open_files() {
        let path = std::env::temp_dir().join(format!(
            "rhun-reopen-skip-{}-{}.rs",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&path, "text").unwrap();
        let mut app = RhunApp::new(LaunchOptions {
            empty: true,
            ..LaunchOptions::default()
        });
        app.documents.push(Document::open(1, &path).unwrap());
        app.active = Some(0);
        app.closed_documents.push(ClosedDocument {
            path: path.clone(),
            index: 1,
            anchor: 0,
            cursor: 0,
        });
        app.reopen_closed_document();
        assert!(app.closed_documents.is_empty());
        assert_eq!(app.documents.len(), 1);

        app.closed_documents.push(ClosedDocument {
            path: path.clone(),
            index: 0,
            anchor: 0,
            cursor: 0,
        });
        app.request_close_document(0);
        fs::remove_file(&path).unwrap();
        app.reopen_closed_document();
        assert!(app.documents.is_empty());
        assert!(app.closed_documents.is_empty());
    }

    #[test]
    fn empty_launch_does_not_persist_until_a_document_is_created() {
        let options = LaunchOptions {
            empty: true,
            ..LaunchOptions::default()
        };
        let mut app = RhunApp::new(options);
        assert!(!app.session_enabled);
        assert!(app.workspace.is_none());
        assert!(app.project_root.is_none());

        app.new_document();
        assert!(app.session_enabled);
    }

    #[test]
    fn saving_the_first_empty_window_document_adopts_its_parent_folder() {
        let temp_file = std::env::temp_dir().join(format!(
            "rhun-empty-save-{}-{}.rs",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let options = LaunchOptions {
            empty: true,
            ..LaunchOptions::default()
        };
        let mut app = RhunApp::new(options);
        app.new_document();
        app.path_input = temp_file.to_string_lossy().into_owned();
        app.documents[0].text = "fn main() {}".into();

        assert!(app.save_document(0));
        let temp_root = fs::canonicalize(temp_file.parent().unwrap()).unwrap();
        assert_eq!(
            app.project_root.as_deref(),
            Some(temp_root.as_path()),
            "{}",
            app.message
        );
        assert!(app.session_enabled);
        fs::remove_file(temp_file).unwrap();
    }

    #[test]
    fn open_folder_path_sets_project_and_rejects_files() {
        let folder = std::env::temp_dir().join(format!(
            "rhun-open-folder-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&folder).unwrap();
        let file = folder.join("file.txt");
        fs::write(&file, "").unwrap();
        let mut app = RhunApp::new(LaunchOptions {
            empty: true,
            ..LaunchOptions::default()
        });

        app.path_input = folder.to_string_lossy().into_owned();
        app.open_folder_pending = true;
        app.open_path_input();
        assert_eq!(
            app.project_root.as_deref(),
            Some(fs::canonicalize(&folder).unwrap().as_path())
        );
        assert!(!app.open_folder_pending);

        app.path_input = file.to_string_lossy().into_owned();
        app.open_folder_pending = true;
        app.open_path_input();
        assert!(app.open_folder_pending);
        assert!(app.documents.is_empty());
        assert!(app.message.contains("not a directory"));

        fs::remove_dir_all(folder).unwrap();
    }

    #[test]
    fn save_as_writes_to_the_requested_path_and_keeps_the_original_file() {
        let unique = format!(
            "rhun-save-as-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let directory = std::env::temp_dir();
        let original_path = directory.join(format!("{unique}-original.rs"));
        let save_as_path = directory.join(format!("{unique}-copy.rs"));
        fs::write(&original_path, "original").unwrap();
        let mut document = Document::open(1, &original_path).unwrap();
        document.text = "updated".into();
        let mut app = RhunApp::new(LaunchOptions {
            empty: true,
            ..LaunchOptions::default()
        });
        app.documents.push(document);
        app.active = Some(0);

        app.save_active_as();
        app.path_input = save_as_path.to_string_lossy().into_owned();
        app.save_active();

        assert_eq!(fs::read_to_string(&original_path).unwrap(), "original");
        assert_eq!(fs::read_to_string(&save_as_path).unwrap(), "updated\n");
        assert_eq!(
            app.documents[0].path.as_deref(),
            Some(save_as_path.as_path())
        );
        assert!(!app.documents[0].is_dirty());
        assert!(!app.save_as_pending);
        fs::remove_file(original_path).unwrap();
        fs::remove_file(save_as_path).unwrap();
    }

    #[test]
    fn find_next_and_previous_wrap_across_utf8_matches() {
        let text = "one café two café";
        let matches = find_matches(text, "café");
        assert_eq!(matches.len(), 2);
        assert_eq!(find_next(text, "café", 0), Some(matches[0]));
        assert_eq!(find_next(text, "café", matches[0].1), Some(matches[1]));
        assert_eq!(find_next(text, "café", text.len()), Some(matches[0]));
        assert_eq!(find_previous(text, "café", matches[1].0), Some(matches[0]));
        assert_eq!(find_previous(text, "café", 0), Some(matches[1]));
    }

    #[test]
    fn find_uses_non_overlapping_matches_and_empty_queries_do_not_match() {
        assert_eq!(find_matches("aaaa", "aa"), [(0, 2), (2, 4)]);
        assert!(find_matches("anything", "").is_empty());
        assert_eq!(find_matches("CAFÉ café", "café"), [(0, 5), (6, 11)]);
        assert_eq!(find_matches("İ", "i\u{307}"), [(0, 2)]);
    }

    #[test]
    fn replace_all_uses_case_insensitive_utf8_match_ranges() {
        assert_eq!(
            replace_all_matches("Café café CAFÉ", "café", "tea"),
            ("tea tea tea".into(), 3)
        );
    }

    #[test]
    fn replace_all_is_one_undoable_document_edit() {
        let path = std::env::temp_dir().join(format!(
            "rhun-replace-undo-{}-{}.txt",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&path, "café café").unwrap();
        let mut app = RhunApp::new(LaunchOptions {
            empty: true,
            ..LaunchOptions::default()
        });
        app.documents.push(Document::open(1, &path).unwrap());
        app.active = Some(0);
        app.find_input = "café".into();
        app.replace_input = "tea".into();

        app.replace_all();
        assert_eq!(app.documents[0].text, "tea tea");
        assert!(app.documents[0].undo());
        assert_eq!(app.documents[0].text, "café café");

        fs::remove_file(path).unwrap();
    }

    #[test]
    fn editor_enter_tab_and_undo_shortcuts_use_document_history() {
        fn send_key(
            app: &mut RhunApp,
            context: &egui::Context,
            key: Key,
            modifiers: egui::Modifiers,
        ) {
            let editor_id = egui::Id::new(("editor", app.documents[0].id));
            context.memory_mut(|memory| memory.request_focus(editor_id));
            let _ = context.run(
                egui::RawInput {
                    modifiers,
                    events: vec![egui::Event::Key {
                        key,
                        physical_key: Some(key),
                        pressed: true,
                        repeat: false,
                        modifiers,
                    }],
                    ..Default::default()
                },
                |context| app.handle_shortcuts(context),
            );
        }

        let path = std::env::temp_dir().join(format!(
            "rhun-editor-undo-{}-{}.txt",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&path, "    {}").unwrap();
        let mut app = RhunApp::with_editor_settings(
            LaunchOptions {
                empty: true,
                ..LaunchOptions::default()
            },
            EditorSettings {
                tab_width: 8,
                insert_spaces: false,
                auto_pairs: true,
                ..EditorSettings::default()
            },
        );
        let mut document = Document::open(1, &path).unwrap();
        document.set_cursor_byte_offset(5);
        app.documents = vec![document];
        app.active = Some(0);

        let context = egui::Context::default();
        send_key(&mut app, &context, Key::Enter, egui::Modifiers::NONE);
        assert_eq!(app.documents[0].text, "    {\n    \t\n    }");

        send_key(
            &mut app,
            &context,
            Key::Z,
            egui::Modifiers {
                ctrl: true,
                command: true,
                ..Default::default()
            },
        );
        assert_eq!(app.documents[0].text, "    {}");

        send_key(
            &mut app,
            &context,
            Key::Enter,
            egui::Modifiers {
                ctrl: true,
                command: true,
                ..Default::default()
            },
        );
        assert_eq!(app.documents[0].text, "    {}\n    ");
        send_key(
            &mut app,
            &context,
            Key::Z,
            egui::Modifiers {
                ctrl: true,
                command: true,
                ..Default::default()
            },
        );
        assert_eq!(app.documents[0].text, "    {}");

        send_key(
            &mut app,
            &context,
            Key::Enter,
            egui::Modifiers {
                ctrl: true,
                command: true,
                shift: true,
                ..Default::default()
            },
        );
        assert_eq!(app.documents[0].text, "    \n    {}");
        send_key(
            &mut app,
            &context,
            Key::Z,
            egui::Modifiers {
                ctrl: true,
                command: true,
                ..Default::default()
            },
        );
        assert_eq!(app.documents[0].text, "    {}");

        send_key(&mut app, &context, Key::Tab, egui::Modifiers::NONE);
        assert_eq!(app.documents[0].text, "    {\t}");
        send_key(
            &mut app,
            &context,
            Key::OpenBracket,
            egui::Modifiers::COMMAND,
        );
        assert_eq!(app.documents[0].text, "{\t}");
        send_key(
            &mut app,
            &context,
            Key::CloseBracket,
            egui::Modifiers::COMMAND,
        );
        assert_eq!(app.documents[0].text, "\t{\t}");
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn paired_character_input_is_applied_and_removed_before_text_edit() {
        let context = egui::Context::default();
        let mut document = Document::untitled(19);
        let _ = context.run(
            egui::RawInput {
                events: vec![egui::Event::Text("(".into())],
                ..Default::default()
            },
            |context| RhunApp::process_paired_text(context, &mut document, true),
        );

        assert_eq!(document.text, "()");
        assert_eq!(document.cursor, 1);
        assert!(document.undo());
        assert!(document.text.is_empty());
    }

    #[test]
    fn disabled_auto_pairs_leave_typed_text_for_the_editor() {
        let context = egui::Context::default();
        let mut document = Document::untitled(20);
        let _ = context.run(
            egui::RawInput {
                events: vec![egui::Event::Text("(".into())],
                ..Default::default()
            },
            |context| RhunApp::process_paired_text(context, &mut document, false),
        );

        assert!(document.text.is_empty());
        assert_eq!(
            context.input(|input| input.events.clone()),
            [egui::Event::Text("(".into())]
        );
    }

    #[test]
    fn toggle_comment_shortcut_uses_the_open_files_language_token() {
        let path = std::env::temp_dir().join(format!(
            "rhun-comment-{}-{}.rs",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&path, "fn main() {}").unwrap();
        let mut app = RhunApp::with_editor_settings(
            LaunchOptions {
                empty: true,
                ..LaunchOptions::default()
            },
            EditorSettings::default(),
        );
        app.documents.push(Document::open(1, &path).unwrap());
        app.active = Some(0);
        let context = egui::Context::default();
        let editor_id = egui::Id::new(("editor", app.documents[0].id));
        context.memory_mut(|memory| memory.request_focus(editor_id));
        let modifiers = egui::Modifiers {
            ctrl: true,
            command: true,
            ..Default::default()
        };
        let _ = context.run(
            egui::RawInput {
                modifiers,
                events: vec![egui::Event::Key {
                    key: Key::Slash,
                    physical_key: Some(Key::Slash),
                    pressed: true,
                    repeat: false,
                    modifiers,
                }],
                ..Default::default()
            },
            |context| app.handle_shortcuts(context),
        );

        assert_eq!(app.documents[0].text, "// fn main() {}");
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn select_line_shortcut_selects_the_current_line() {
        let path = std::env::temp_dir().join(format!(
            "rhun-select-line-{}-{}.txt",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&path, "one\ntwo\nthree").unwrap();
        let mut app = RhunApp::with_editor_settings(
            LaunchOptions {
                empty: true,
                ..LaunchOptions::default()
            },
            EditorSettings::default(),
        );
        let mut document = Document::open(1, &path).unwrap();
        document.cursor = 1;
        document.cursor_anchor = 1;
        app.documents.push(document);
        app.active = Some(0);
        let context = egui::Context::default();
        let editor_id = egui::Id::new(("editor", app.documents[0].id));
        context.memory_mut(|memory| memory.request_focus(editor_id));
        let modifiers = egui::Modifiers {
            ctrl: true,
            command: true,
            ..Default::default()
        };
        let _ = context.run(
            egui::RawInput {
                modifiers,
                events: vec![egui::Event::Key {
                    key: Key::L,
                    physical_key: Some(Key::L),
                    pressed: true,
                    repeat: false,
                    modifiers,
                }],
                ..Default::default()
            },
            |context| app.handle_shortcuts(context),
        );
        let document = &app.documents[0];
        assert_eq!(
            &document.text[document.cursor_anchor_byte_offset()..document.cursor_byte_offset()],
            "one\n"
        );
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn line_operation_shortcuts_move_delete_and_duplicate() {
        fn send_key(
            app: &mut RhunApp,
            context: &egui::Context,
            key: Key,
            modifiers: egui::Modifiers,
        ) {
            let editor_id = egui::Id::new(("editor", app.documents[0].id));
            context.memory_mut(|memory| memory.request_focus(editor_id));
            let _ = context.run(
                egui::RawInput {
                    modifiers,
                    events: vec![egui::Event::Key {
                        key,
                        physical_key: Some(key),
                        pressed: true,
                        repeat: false,
                        modifiers,
                    }],
                    ..Default::default()
                },
                |context| app.handle_shortcuts(context),
            );
        }

        let mut app = RhunApp::new(LaunchOptions {
            empty: true,
            ..LaunchOptions::default()
        });
        let path = std::env::temp_dir().join(format!(
            "rhun-line-shortcuts-{}-{}.txt",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&path, "two\none\nthree").unwrap();
        let mut document = Document::open(23, &path).unwrap();
        document.cursor = 1;
        document.cursor_anchor = 1;
        app.documents.push(document);
        app.active = Some(0);
        let context = egui::Context::default();

        send_key(&mut app, &context, Key::ArrowDown, egui::Modifiers::ALT);
        assert_eq!(app.documents[0].text, "one\ntwo\nthree");
        send_key(
            &mut app,
            &context,
            Key::K,
            egui::Modifiers::COMMAND | egui::Modifiers::SHIFT,
        );
        assert_eq!(app.documents[0].text, "one\nthree");
        send_key(
            &mut app,
            &context,
            Key::D,
            egui::Modifiers::COMMAND | egui::Modifiers::SHIFT,
        );
        assert_eq!(app.documents[0].text, "one\nthree\nthree");
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn replace_one_requires_a_valid_matching_selection() {
        let mut text = "a café and café".to_owned();
        assert_eq!(
            replace_selected_match(&mut text, "café", "tea", 2, 7),
            Some(5)
        );
        assert_eq!(text, "a tea and café");
        assert_eq!(replace_selected_match(&mut text, "café", "tea", 2, 5), None);
        assert_eq!(
            replace_selected_match(&mut text, "CAFÉ", "chai", 10, 15),
            Some(14)
        );
        assert_eq!(text, "a tea and chai");
    }

    #[test]
    fn go_to_line_uses_one_based_lines_and_clamps_past_end() {
        let text = "first\ncafé\nthird\n";
        assert_eq!(line_start_offset(text, 0), 0);
        assert_eq!(line_start_offset(text, 1), 0);
        assert_eq!(line_start_offset(text, 2), 6);
        assert_eq!(line_start_offset(text, 3), 12);
        assert_eq!(line_start_offset(text, 4), text.len());
        assert_eq!(line_start_offset(text, usize::MAX), text.len());
    }
}
