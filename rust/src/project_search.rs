use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use ignore::WalkBuilder;

const MAX_FILE_SIZE: u64 = 4 * 1024 * 1024;
const MAX_MATCHES: usize = 1000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchMatch {
    pub path: PathBuf,
    pub line_number: usize,
    pub line: String,
}

#[derive(Debug, Default)]
pub struct SearchResults {
    pub matches: Vec<SearchMatch>,
    pub scanned_files: usize,
    pub skipped_files: usize,
    pub truncated: bool,
}

pub fn search_project(root: &Path, query: &str) -> io::Result<SearchResults> {
    let needle = query.trim().to_lowercase();
    if needle.is_empty() {
        return Ok(SearchResults::default());
    }
    let mut results = SearchResults::default();
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
        if results.matches.len() > MAX_MATCHES {
            break;
        }
        let entry = entry.map_err(io::Error::other)?;
        if entry.file_type().is_some_and(|kind| kind.is_file()) {
            search_file(root, entry.path(), &needle, &mut results)?;
        }
    }
    results.truncated = results.matches.len() > MAX_MATCHES;
    results.matches.truncate(MAX_MATCHES);
    Ok(results)
}

fn is_ignored_directory(name: &std::ffi::OsStr) -> bool {
    matches!(
        name.to_str(),
        Some(".git" | ".hg" | ".svn" | "target" | "build" | "node_modules")
    )
}

fn search_file(
    root: &Path,
    path: &Path,
    needle: &str,
    results: &mut SearchResults,
) -> io::Result<()> {
    if fs::metadata(path)?.len() > MAX_FILE_SIZE {
        results.skipped_files += 1;
        return Ok(());
    }
    let bytes = fs::read(path)?;
    if bytes.contains(&0) {
        results.skipped_files += 1;
        return Ok(());
    }
    let text = match std::str::from_utf8(&bytes) {
        Ok(text) => text,
        Err(_) => {
            results.skipped_files += 1;
            return Ok(());
        }
    };
    results.scanned_files += 1;
    for (index, line) in text.lines().enumerate() {
        if line.to_lowercase().contains(needle) {
            results.matches.push(SearchMatch {
                path: path.strip_prefix(root).unwrap_or(path).to_path_buf(),
                line_number: index + 1,
                line: line.to_owned(),
            });
            if results.matches.len() > MAX_MATCHES {
                return Ok(());
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let id = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir()
                .join(format!("rhun-project-search-{}-{id}", std::process::id()));
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
    fn searches_utf8_lines_case_insensitively_and_skips_generated_directories() {
        let directory = TestDirectory::new();
        fs::create_dir(directory.0.join("src")).unwrap();
        fs::create_dir(directory.0.join("target")).unwrap();
        fs::write(
            directory.0.join("src").join("main.rs"),
            "fn main() {\n    println!(\"ÉTÉ\");\n}\n",
        )
        .unwrap();
        fs::write(
            directory.0.join("target").join("generated.rs"),
            "été should be ignored",
        )
        .unwrap();

        let results = search_project(&directory.0, "été").unwrap();
        assert_eq!(results.matches.len(), 1);
        assert_eq!(results.matches[0].path, PathBuf::from("src/main.rs"));
        assert_eq!(results.matches[0].line_number, 2);
        assert_eq!(results.matches[0].line, "    println!(\"ÉTÉ\");");
        assert_eq!(results.scanned_files, 1);
    }

    #[test]
    fn honors_root_and_nested_gitignore_rules() {
        let directory = TestDirectory::new();
        fs::create_dir(directory.0.join("src")).unwrap();
        fs::create_dir(directory.0.join("ignored_dir")).unwrap();
        fs::write(
            directory.0.join(".gitignore"),
            "ignored.txt\nignored_dir/\n*.tmp\n",
        )
        .unwrap();
        fs::write(
            directory.0.join("src").join(".gitignore"),
            "nested_secret.rs\n!keep.rs\n",
        )
        .unwrap();
        fs::write(directory.0.join("visible.txt"), "needle visible").unwrap();
        fs::write(directory.0.join("ignored.txt"), "needle ignored").unwrap();
        fs::write(directory.0.join("ignored.tmp"), "needle ignored").unwrap();
        fs::write(
            directory.0.join("ignored_dir").join("inside.txt"),
            "needle ignored",
        )
        .unwrap();
        fs::write(
            directory.0.join("src").join("nested_secret.rs"),
            "needle ignored",
        )
        .unwrap();
        fs::write(directory.0.join("src").join("keep.rs"), "needle included").unwrap();

        let results = search_project(&directory.0, "needle").unwrap();
        let paths = results
            .matches
            .iter()
            .map(|result| result.path.clone())
            .collect::<Vec<_>>();
        assert_eq!(
            paths,
            [PathBuf::from("src/keep.rs"), PathBuf::from("visible.txt")]
        );
    }

    #[test]
    fn skips_binary_and_oversized_files() {
        let directory = TestDirectory::new();
        fs::write(directory.0.join("binary.dat"), [b'a', 0, b'b']).unwrap();
        let large = vec![b'a'; MAX_FILE_SIZE as usize + 1];
        fs::write(directory.0.join("large.txt"), large).unwrap();
        fs::write(directory.0.join("text.txt"), "needle").unwrap();

        let results = search_project(&directory.0, "needle").unwrap();
        assert_eq!(results.matches.len(), 1);
        assert_eq!(results.scanned_files, 1);
        assert_eq!(results.skipped_files, 2);
    }

    #[test]
    fn empty_query_does_not_search() {
        let directory = TestDirectory::new();
        fs::write(directory.0.join("text.txt"), "needle").unwrap();

        let results = search_project(&directory.0, "  ").unwrap();
        assert!(results.matches.is_empty());
        assert_eq!(results.scanned_files, 0);
    }

    #[test]
    fn caps_results_and_reports_truncation() {
        let directory = TestDirectory::new();
        fs::write(
            directory.0.join("many.txt"),
            "needle\n".repeat(MAX_MATCHES + 1),
        )
        .unwrap();

        let results = search_project(&directory.0, "needle").unwrap();
        assert_eq!(results.matches.len(), MAX_MATCHES);
        assert!(results.truncated);
    }

    #[test]
    fn exact_result_limit_is_not_reported_as_truncated() {
        let directory = TestDirectory::new();
        fs::write(
            directory.0.join("exactly-many.txt"),
            "needle\n".repeat(MAX_MATCHES),
        )
        .unwrap();

        let results = search_project(&directory.0, "needle").unwrap();
        assert_eq!(results.matches.len(), MAX_MATCHES);
        assert!(!results.truncated);
    }
}
