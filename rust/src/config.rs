use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EditorSettings {
    pub tab_width: usize,
    pub insert_spaces: bool,
    pub auto_pairs: bool,
    pub trim_trailing_whitespace: bool,
    pub final_newline: bool,
}

impl Default for EditorSettings {
    fn default() -> Self {
        Self {
            tab_width: 4,
            insert_spaces: true,
            auto_pairs: true,
            trim_trailing_whitespace: false,
            final_newline: true,
        }
    }
}

impl EditorSettings {
    pub fn load() -> io::Result<Self> {
        Self::load_from_path(&config_path())
    }

    fn load_from_path(path: &Path) -> io::Result<Self> {
        match fs::read_to_string(path) {
            Ok(contents) => Ok(Self::parse(&contents)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Self::default()),
            Err(error) => Err(error),
        }
    }

    pub fn reload_if_present() -> io::Result<Option<Self>> {
        Self::reload_if_present_from_path(&config_path())
    }

    fn reload_if_present_from_path(path: &Path) -> io::Result<Option<Self>> {
        match fs::read_to_string(path) {
            Ok(contents) => Ok(Some(Self::parse(&contents))),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error),
        }
    }

    fn parse(contents: &str) -> Self {
        let mut settings = Self::default();
        let mut in_editor_section = false;
        let mut in_files_section = false;
        for line in contents.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
                continue;
            }
            if line.starts_with('[') && line.ends_with(']') {
                in_editor_section = &line[1..line.len() - 1] == "editor";
                in_files_section = &line[1..line.len() - 1] == "files";
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let key = key.trim();
            let value = value.trim();
            if in_editor_section {
                match key {
                    "tab_width" => {
                        if let Ok(width) = value.parse::<usize>() {
                            settings.tab_width = width.clamp(1, 16);
                        }
                    }
                    "insert_spaces" => settings.insert_spaces = parse_bool(value),
                    "auto_pairs" => settings.auto_pairs = parse_bool(value),
                    _ => {}
                }
            } else if in_files_section {
                match key {
                    "trim_trailing_whitespace" => {
                        settings.trim_trailing_whitespace = parse_bool(value)
                    }
                    "final_newline" => settings.final_newline = parse_bool(value),
                    _ => {}
                }
            }
        }
        settings
    }

    pub fn indent_unit(self) -> String {
        if self.insert_spaces {
            " ".repeat(self.tab_width)
        } else {
            "\t".to_owned()
        }
    }
}

fn parse_bool(value: &str) -> bool {
    value.eq_ignore_ascii_case("on")
        || value
            .chars()
            .next()
            .is_some_and(|first| matches!(first.to_ascii_lowercase(), 'y' | 't' | '1'))
}

fn config_path() -> PathBuf {
    config_path_for(
        std::env::var_os("XDG_CONFIG_HOME"),
        std::env::var_os("APPDATA"),
        std::env::var_os("HOME"),
        cfg!(windows),
    )
}

fn config_path_for(
    xdg_config: Option<std::ffi::OsString>,
    appdata: Option<std::ffi::OsString>,
    home: Option<std::ffi::OsString>,
    windows: bool,
) -> PathBuf {
    if let Some(root) = xdg_config.filter(|value| !value.is_empty()) {
        return PathBuf::from(root).join("rhun").join("config");
    }
    if windows && let Some(root) = appdata.filter(|value| !value.is_empty()) {
        return PathBuf::from(root).join("rhun").join("config");
    }
    home.map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".config")
        .join("rhun")
        .join("config")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_the_assembly_editor_configuration() {
        assert_eq!(
            EditorSettings::parse(""),
            EditorSettings {
                tab_width: 4,
                insert_spaces: true,
                auto_pairs: true,
                trim_trailing_whitespace: false,
                final_newline: true,
            }
        );
    }

    #[test]
    fn parses_editor_settings_and_ignores_other_sections() {
        let settings = EditorSettings::parse(
            "[ui]\ntab_width = 12\n[editor]\ntab_width = 8\ninsert_spaces = no\nauto_pairs = ON\n",
        );
        assert_eq!(
            settings,
            EditorSettings {
                tab_width: 8,
                insert_spaces: false,
                auto_pairs: true,
                trim_trailing_whitespace: false,
                final_newline: true,
            }
        );
        assert_eq!(settings.indent_unit(), "\t");
    }

    #[test]
    fn tab_width_is_clamped_and_invalid_values_keep_the_default() {
        assert_eq!(
            EditorSettings::parse("[editor]\ntab_width = 99\n").tab_width,
            16
        );
        assert_eq!(
            EditorSettings::parse("[editor]\ntab_width = invalid\n").tab_width,
            4
        );
        assert_eq!(
            EditorSettings::parse("[editor]\ntab_width = 0\n").tab_width,
            1
        );
    }

    #[test]
    fn missing_config_uses_defaults() {
        let path = std::env::temp_dir().join(format!(
            "rhun-missing-config-{}-{}.ini",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        assert_eq!(
            EditorSettings::load_from_path(&path).unwrap(),
            EditorSettings::default()
        );
    }

    #[test]
    fn reads_editor_settings_from_the_existing_config_file_format() {
        let path = std::env::temp_dir().join(format!(
            "rhun-editor-config-{}-{}.ini",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(
            &path,
            "[editor]\ntab_width = 2\ninsert_spaces = false\nauto_pairs = no\n",
        )
        .unwrap();

        let settings = EditorSettings::load_from_path(&path).unwrap();
        fs::remove_file(path).unwrap();
        assert_eq!(
            settings,
            EditorSettings {
                tab_width: 2,
                insert_spaces: false,
                auto_pairs: false,
                trim_trailing_whitespace: false,
                final_newline: true,
            }
        );
    }

    #[test]
    fn parses_existing_file_save_settings() {
        let settings = EditorSettings::parse(
            "[files]\ntrim_trailing_whitespace = yes\nfinal_newline = false\n",
        );
        assert!(settings.trim_trailing_whitespace);
        assert!(!settings.final_newline);
    }

    #[test]
    fn config_path_prefers_xdg_then_windows_appdata_then_home() {
        let path = config_path_for(
            Some("custom-config".into()),
            Some("appdata".into()),
            Some("home".into()),
            true,
        );
        assert_eq!(path, PathBuf::from("custom-config/rhun/config"));

        let path = config_path_for(None, Some("appdata".into()), Some("home".into()), true);
        assert_eq!(path, PathBuf::from("appdata/rhun/config"));

        let path = config_path_for(None, Some("appdata".into()), Some("home".into()), false);
        assert_eq!(path, PathBuf::from("home/.config/rhun/config"));
    }

    #[test]
    fn reload_reads_existing_settings_and_ignores_a_removed_config() {
        let path = std::env::temp_dir().join(format!(
            "rhun-reload-config-{}-{}.ini",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(
            &path,
            "[editor]\ntab_width = 2\n[files]\nfinal_newline = false\n",
        )
        .unwrap();

        let settings = EditorSettings::reload_if_present_from_path(&path)
            .unwrap()
            .unwrap();
        assert_eq!(settings.tab_width, 2);
        assert!(!settings.final_newline);
        fs::remove_file(&path).unwrap();
        assert_eq!(
            EditorSettings::reload_if_present_from_path(&path).unwrap(),
            None
        );
    }
}
