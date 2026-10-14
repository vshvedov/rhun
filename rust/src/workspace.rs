use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::{collections::HashMap, collections::HashSet};

#[derive(Debug)]
pub struct Workspace {
    pub root: PathBuf,
    pub entries: Vec<Entry>,
    directories: HashMap<PathBuf, Vec<Entry>>,
}

#[derive(Debug, Clone)]
pub struct Entry {
    pub path: PathBuf,
    pub name: String,
    pub is_directory: bool,
}

impl Workspace {
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let root = fs::canonicalize(path)?;
        if !root.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::NotADirectory,
                "workspace path is not a directory",
            ));
        }
        let mut workspace = Self {
            root,
            entries: Vec::new(),
            directories: HashMap::new(),
        };
        workspace.refresh()?;
        Ok(workspace)
    }

    pub fn refresh(&mut self) -> io::Result<()> {
        self.refresh_expanded(&HashSet::new())
    }

    pub fn refresh_expanded(&mut self, expanded: &HashSet<PathBuf>) -> io::Result<()> {
        let entries = read_entries(&self.root)?;
        let mut directories = HashMap::new();
        directories.insert(self.root.clone(), entries.clone());

        let mut paths = expanded.iter().collect::<Vec<_>>();
        paths.sort();
        for path in paths {
            if !path.starts_with(&self.root) || !path.is_dir() {
                continue;
            }
            directories.insert(path.clone(), read_entries(path)?);
        }

        self.entries = entries;
        self.directories = directories;
        Ok(())
    }

    pub fn load_directory(&mut self, path: &Path) -> io::Result<()> {
        let entries = read_entries(path)?;
        self.directories.insert(path.to_path_buf(), entries);
        Ok(())
    }

    pub fn visible_entries(&self, expanded: &HashSet<PathBuf>) -> Vec<(Entry, usize)> {
        fn append(
            workspace: &Workspace,
            entries: &[Entry],
            expanded: &HashSet<PathBuf>,
            depth: usize,
            ancestors: &mut HashSet<PathBuf>,
            visible: &mut Vec<(Entry, usize)>,
        ) {
            for entry in entries {
                visible.push((entry.clone(), depth));
                if !entry.is_directory || !expanded.contains(&entry.path) || depth >= 64 {
                    continue;
                }
                let identity = fs::canonicalize(&entry.path).unwrap_or_else(|_| entry.path.clone());
                if !ancestors.insert(identity.clone()) {
                    continue;
                }
                if let Some(children) = workspace.directories.get(&entry.path) {
                    append(workspace, children, expanded, depth + 1, ancestors, visible);
                }
                ancestors.remove(&identity);
            }
        }

        let mut visible = Vec::new();
        let mut ancestors = HashSet::new();
        ancestors.insert(self.root.clone());
        append(
            self,
            &self.entries,
            expanded,
            0,
            &mut ancestors,
            &mut visible,
        );
        visible
    }
}

fn read_entries(path: &Path) -> io::Result<Vec<Entry>> {
    let mut entries = Vec::new();
    for item in fs::read_dir(path)? {
        let item = item?;
        let path = item.path();
        let name = item.file_name().to_string_lossy().into_owned();
        let is_directory = fs::metadata(&path)?.is_dir();
        entries.push(Entry {
            path,
            name,
            is_directory,
        });
    }
    entries.sort_by(|left, right| {
        right
            .is_directory
            .cmp(&left.is_directory)
            .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
            .then_with(|| left.name.cmp(&right.name))
    });
    Ok(entries)
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
                .join(format!("rhun-workspace-test-{}-{id}", std::process::id()));
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
    fn lists_directories_before_case_insensitive_sorted_files() {
        let directory = TestDirectory::new();
        fs::create_dir(directory.0.join("zebra")).unwrap();
        fs::create_dir(directory.0.join("Alpha")).unwrap();
        fs::write(directory.0.join("z.txt"), "").unwrap();
        fs::write(directory.0.join("B.txt"), "").unwrap();

        let workspace = Workspace::open(&directory.0).unwrap();
        assert_eq!(workspace.root, fs::canonicalize(&directory.0).unwrap());
        let names = workspace
            .entries
            .iter()
            .map(|entry| entry.name.as_str())
            .collect::<Vec<_>>();
        assert_eq!(names, ["Alpha", "zebra", "B.txt", "z.txt"]);
        assert!(workspace.entries[0].is_directory);
        assert!(!workspace.entries[2].is_directory);
    }

    #[test]
    fn opening_a_non_directory_returns_an_io_error() {
        let directory = TestDirectory::new();
        let file = directory.0.join("file.txt");
        fs::write(&file, "").unwrap();

        assert!(Workspace::open(file).is_err());
    }

    #[test]
    fn expanded_entries_are_loaded_on_demand_and_rendered_as_a_tree() {
        let directory = TestDirectory::new();
        let nested = directory.0.join("src");
        let deeper = nested.join("nested");
        fs::create_dir(&nested).unwrap();
        fs::create_dir(&deeper).unwrap();
        fs::write(deeper.join("main.rs"), "").unwrap();
        let nested = fs::canonicalize(nested).unwrap();
        let deeper = fs::canonicalize(deeper).unwrap();

        let mut workspace = Workspace::open(&directory.0).unwrap();
        let expanded = HashSet::from([nested.clone()]);
        assert_eq!(
            workspace
                .visible_entries(&expanded)
                .iter()
                .map(|(entry, depth)| (entry.name.as_str(), *depth))
                .collect::<Vec<_>>(),
            [("src", 0)]
        );

        workspace.load_directory(&nested).unwrap();
        let expanded = HashSet::from([nested.clone(), deeper.clone()]);
        assert_eq!(
            workspace
                .visible_entries(&expanded)
                .iter()
                .map(|(entry, depth)| (entry.name.as_str(), *depth))
                .collect::<Vec<_>>(),
            [("src", 0), ("nested", 1)]
        );

        workspace.load_directory(&deeper).unwrap();
        assert_eq!(
            workspace
                .visible_entries(&expanded)
                .iter()
                .map(|(entry, depth)| (entry.name.as_str(), *depth))
                .collect::<Vec<_>>(),
            [("src", 0), ("nested", 1), ("main.rs", 2)]
        );
    }

    #[test]
    fn refresh_reloads_expanded_directories_and_drops_removed_branches() {
        let directory = TestDirectory::new();
        let nested = directory.0.join("src");
        fs::create_dir(&nested).unwrap();
        fs::write(nested.join("old.rs"), "").unwrap();
        let mut workspace = Workspace::open(&directory.0).unwrap();
        let nested = fs::canonicalize(nested).unwrap();
        let expanded = HashSet::from([nested.clone()]);
        workspace.load_directory(&nested).unwrap();

        fs::remove_file(nested.join("old.rs")).unwrap();
        fs::write(nested.join("new.rs"), "").unwrap();
        workspace.refresh_expanded(&expanded).unwrap();
        assert_eq!(
            workspace
                .visible_entries(&expanded)
                .iter()
                .map(|(entry, _)| entry.name.as_str())
                .collect::<Vec<_>>(),
            ["src", "new.rs"]
        );

        fs::remove_dir_all(&nested).unwrap();
        workspace.refresh_expanded(&expanded).unwrap();
        assert!(workspace.visible_entries(&expanded).is_empty());
    }

    #[test]
    fn failed_refresh_keeps_the_cached_tree() {
        let directory = TestDirectory::new();
        let nested = directory.0.join("src");
        fs::create_dir(&nested).unwrap();
        fs::write(nested.join("main.rs"), "").unwrap();
        let mut workspace = Workspace::open(&directory.0).unwrap();
        let nested = fs::canonicalize(nested).unwrap();
        let expanded = HashSet::from([nested.clone()]);
        workspace.load_directory(&nested).unwrap();

        let moved = directory
            .0
            .with_file_name(format!("rhun-workspace-refresh-{}", std::process::id()));
        fs::rename(&directory.0, &moved).unwrap();
        fs::write(&directory.0, "not a directory").unwrap();
        let result = workspace.refresh_expanded(&expanded);
        fs::remove_file(&directory.0).unwrap();
        fs::rename(&moved, &directory.0).unwrap();

        assert!(result.is_err());
        assert_eq!(
            workspace
                .visible_entries(&expanded)
                .iter()
                .map(|(entry, _)| entry.name.as_str())
                .collect::<Vec<_>>(),
            ["src", "main.rs"]
        );
    }
}
