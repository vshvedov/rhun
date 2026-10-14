use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionDocument {
    pub path: PathBuf,
    pub cursor: usize,
    pub active: bool,
}

pub fn load_project(project: &Path) -> io::Result<Vec<SessionDocument>> {
    let Some(file) = session_file(project)? else {
        return Ok(Vec::new());
    };
    read_session(&file)
}

fn read_session(file: &Path) -> io::Result<Vec<SessionDocument>> {
    let contents = match fs::read_to_string(file) {
        Ok(contents) => contents,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    Ok(parse_session(&contents))
}

pub fn save_project(project: &Path, documents: &[SessionDocument]) -> io::Result<()> {
    let Some(file) = session_file(project)? else {
        return Ok(());
    };
    write_session(&file, documents)
}

fn write_session(file: &Path, documents: &[SessionDocument]) -> io::Result<()> {
    let Some(parent) = file.parent() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "session file has no parent directory",
        ));
    };
    fs::create_dir_all(parent)?;
    let mut contents = String::new();
    for document in documents {
        let Some(path) = document.path.to_str() else {
            continue;
        };
        if path.contains(['\t', '\r', '\n']) {
            continue;
        }
        if document.active {
            contents.push('*');
        }
        contents.push_str(path);
        contents.push('\t');
        contents.push_str(&document.cursor.to_string());
        contents.push('\n');
    }
    fs::write(file, contents)
}

fn parse_session(contents: &str) -> Vec<SessionDocument> {
    contents
        .lines()
        .filter_map(|line| {
            let (path, cursor) = line.split_once('\t')?;
            let cursor = cursor.parse().unwrap_or(0);
            let (active, path) = match path.strip_prefix('*') {
                Some(path) => (true, path),
                None => (false, path),
            };
            (!path.is_empty()).then(|| SessionDocument {
                path: PathBuf::from(path),
                cursor,
                active,
            })
        })
        .collect()
}

fn session_file(project: &Path) -> io::Result<Option<PathBuf>> {
    let Some(state_root) = state_root() else {
        return Ok(None);
    };
    let Some(name) = session_file_name(project, cfg!(windows)) else {
        return Ok(None);
    };
    Ok(Some(state_root.join("rhun").join(name)))
}

fn state_root() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        env::var_os("LOCALAPPDATA").map(PathBuf::from).or_else(|| {
            env::var_os("USERPROFILE").map(|home| PathBuf::from(home).join("AppData/Local"))
        })
    }
    #[cfg(not(windows))]
    {
        env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")))
    }
}

fn session_file_name(project: &Path, windows: bool) -> Option<String> {
    let path = project.to_str()?;
    let mut encoded = String::new();
    for character in path.chars() {
        match character {
            '%' => encoded.push_str("%%25"),
            '/' => encoded.push('%'),
            '\\' if windows => encoded.push_str("%5C"),
            ':' | '<' | '>' | '"' | '|' | '?' | '*' if windows => {
                encoded.push('%');
                encoded.push_str(&format!("{:02X}", character as u32));
            }
            character if windows && character.is_control() => {
                for byte in character.to_string().bytes() {
                    encoded.push('%');
                    encoded.push_str(&format!("{byte:02X}"));
                }
            }
            character => encoded.push(character),
        }
    }
    if windows && encoded.len() > 240 {
        return None;
    }
    encoded.push_str(".session");
    Some(encoded)
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
            let path =
                env::temp_dir().join(format!("rhun-session-test-{}-{id}", std::process::id()));
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
    fn parses_the_existing_tab_delimited_session_format() {
        assert_eq!(
            parse_session("first.rs\t13\n*second.rs\t42\nignored\n"),
            [
                SessionDocument {
                    path: PathBuf::from("first.rs"),
                    cursor: 13,
                    active: false
                },
                SessionDocument {
                    path: PathBuf::from("second.rs"),
                    cursor: 42,
                    active: true
                }
            ]
        );
    }

    #[test]
    fn encodes_project_paths_compatibly_on_unix_and_windows() {
        assert_eq!(
            session_file_name(Path::new("/home/user/50%off"), false).as_deref(),
            Some("%home%user%50%%25off.session")
        );
        assert_eq!(
            session_file_name(Path::new(r"C:\Users\A B\50%off"), true).as_deref(),
            Some("C%3A%5CUsers%5CA B%5C50%%25off.session")
        );
    }

    #[test]
    fn skips_windows_session_names_that_exceed_the_legacy_limit() {
        let long_path = PathBuf::from(format!("C:\\{}", "a".repeat(241)));
        assert_eq!(session_file_name(&long_path, true), None);
    }

    #[test]
    fn missing_sessions_load_empty_and_saves_round_trip() {
        let directory = TestDirectory::new();
        let file = directory.0.join("state").join("project.session");
        assert!(read_session(&file).unwrap().is_empty());
        let documents = [
            SessionDocument {
                path: PathBuf::from("first.rs"),
                cursor: 0,
                active: true,
            },
            SessionDocument {
                path: PathBuf::from("second.rs"),
                cursor: 12,
                active: false,
            },
        ];
        write_session(&file, &documents).unwrap();
        assert_eq!(read_session(&file).unwrap(), documents,);
    }
}
