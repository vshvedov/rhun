use std::io;
use std::path::{Path, PathBuf};

use ignore::WalkBuilder;

const MAX_FILES: usize = 100_000;
const MAX_RESULTS: usize = 200;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuickOpenMatch {
    pub path: PathBuf,
    score: i32,
}

#[derive(Debug, Default)]
pub struct QuickOpenResults {
    pub matches: Vec<QuickOpenMatch>,
    pub scanned_files: usize,
    pub truncated: bool,
}

pub fn search_files(root: &Path, query: &str) -> io::Result<QuickOpenResults> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(QuickOpenResults::default());
    }

    let mut results = QuickOpenResults::default();
    let mut walker = WalkBuilder::new(root);
    walker
        .hidden(false)
        .follow_links(false)
        .git_ignore(true)
        .git_global(false)
        .git_exclude(false)
        .require_git(false)
        .sort_by_file_path(|left, right| left.cmp(right))
        .filter_entry(|entry| {
            entry.depth() == 0
                || !entry.file_type().is_some_and(|kind| kind.is_dir())
                || !is_ignored_directory(entry.file_name())
        });

    for entry in walker.build() {
        let entry = entry.map_err(io::Error::other)?;
        if !entry.file_type().is_some_and(|kind| kind.is_file()) {
            continue;
        }
        if results.scanned_files == MAX_FILES {
            results.truncated = true;
            break;
        }
        results.scanned_files += 1;
        let Some(relative_path) = entry.path().strip_prefix(root).ok() else {
            continue;
        };
        let label = relative_path.to_string_lossy();
        if let Some(score) = fuzzy_score(&label, query) {
            results.matches.push(QuickOpenMatch {
                path: relative_path.to_path_buf(),
                score,
            });
        }
    }

    results.matches.sort_by(|left, right| {
        right
            .score
            .cmp(&left.score)
            .then_with(|| left.path.cmp(&right.path))
    });
    if results.matches.len() > MAX_RESULTS {
        results.truncated = true;
    }
    results.matches.truncate(MAX_RESULTS);
    Ok(results)
}

fn is_ignored_directory(name: &std::ffi::OsStr) -> bool {
    matches!(
        name.to_str(),
        Some(".git" | ".hg" | ".svn" | "target" | "build" | "node_modules")
    )
}

fn fuzzy_score(label: &str, query: &str) -> Option<i32> {
    let label = label.as_bytes();
    let query = query.as_bytes();
    if query.is_empty() {
        return Some(0);
    }

    let basename_start = label
        .iter()
        .rposition(|character| matches!(character, b'/' | b'\\'))
        .map_or(0, |index| index + 1);
    let mut label_index = 0;
    let mut last_match = None;
    let mut score = 0;

    for query_character in query {
        let wanted = query_character.to_ascii_lowercase();
        let relative_index = label[label_index..]
            .iter()
            .position(|character| character.to_ascii_lowercase() == wanted)?;
        label_index += relative_index;
        score += 10;
        if last_match.is_some_and(|previous| previous + 1 == label_index) {
            score += 15;
        }
        if label_index == 0
            || matches!(
                label[label_index - 1],
                b'/' | b'\\' | b'_' | b'-' | b'.' | b' '
            )
            || (label[label_index].is_ascii_uppercase()
                && label[label_index - 1].is_ascii_lowercase())
        {
            score += 12;
        }
        if label_index >= basename_start {
            score += 6;
        }
        last_match = Some(label_index);
        label_index += 1;
    }

    score += (200_i32 - label.len() as i32) / 8;
    let prefix_length = query.len().min(label.len());
    if label[..prefix_length].eq_ignore_ascii_case(&query[..prefix_length]) {
        score += 40;
        if label.len() == query.len() {
            score += 100;
        }
    }
    Some(score)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let id = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
            let path =
                std::env::temp_dir().join(format!("rhun-quick-open-{}-{id}", std::process::id()));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn fuzzy_matching_is_case_insensitive_and_prefers_exact_names_and_word_starts() {
        assert!(fuzzy_score("src/main.rs", "MR").is_some());
        assert!(fuzzy_score("src/main.rs", "xyz").is_none());
        assert!(fuzzy_score("src/main.rs", "mr").unwrap() < fuzzy_score("main.rs", "mr").unwrap());
        assert!(
            fuzzy_score("src/main.rs", "main.rs").unwrap()
                < fuzzy_score("main.rs", "main.rs").unwrap()
        );
    }

    #[test]
    fn search_walks_nested_files_honors_gitignore_and_sorts_best_matches_first() {
        let directory = TestDirectory::new();
        fs::create_dir(directory.0.join("src")).unwrap();
        fs::create_dir(directory.0.join("target")).unwrap();
        fs::write(directory.0.join(".gitignore"), "ignored.rs\n").unwrap();
        fs::write(directory.0.join("main.rs"), "").unwrap();
        fs::write(directory.0.join("ignored.rs"), "").unwrap();
        fs::write(directory.0.join("src").join("main.rs"), "").unwrap();
        fs::write(directory.0.join("target").join("main.rs"), "").unwrap();

        let results = search_files(&directory.0, "main.rs").unwrap();

        assert_eq!(
            results
                .matches
                .iter()
                .map(|result| result.path.to_string_lossy().into_owned())
                .collect::<Vec<_>>(),
            ["main.rs", "src\\main.rs"]
        );
        assert_eq!(results.scanned_files, 3);
        assert!(!results.truncated);
    }

    #[test]
    fn empty_queries_return_no_file_matches() {
        assert!(
            search_files(Path::new("."), "  ")
                .unwrap()
                .matches
                .is_empty()
        );
    }

    #[test]
    fn search_caps_ranked_results_and_reports_truncation() {
        let directory = TestDirectory::new();
        for index in 0..201 {
            fs::write(directory.0.join(format!("item-{index:03}.rs")), "").unwrap();
        }

        let results = search_files(&directory.0, "item").unwrap();

        assert_eq!(results.matches.len(), MAX_RESULTS);
        assert!(results.truncated);
    }
}
