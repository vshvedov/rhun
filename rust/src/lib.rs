use std::ffi::{OsStr, OsString};

pub const USAGE: &str = "usage: rhun [folder] [files...]\n\
  --wait           stay in the terminal until rhun is closed (for EDITOR)\n\
  --empty          start without restoring a project or tabs\n\
  --headless WxH   no display; use with --script or --control\n\
  --script FILE    run control commands from FILE and exit\n\
  --control PATH   accept control commands on a unix socket\n\
  --scale F        display scale where the platform has none\n\
  --version        print the version\n";

pub const VERSION: &str = concat!("rhun ", include_str!("../../VERSION"));

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Size {
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LaunchOptions {
    pub paths: Vec<OsString>,
    pub headless: bool,
    pub size: Size,
    pub wait: bool,
    pub empty: bool,
    pub script: Option<OsString>,
    pub control: Option<OsString>,
    pub scale: Option<f32>,
}

impl Default for LaunchOptions {
    fn default() -> Self {
        Self {
            paths: Vec::new(),
            headless: false,
            size: Size {
                width: 1280,
                height: 800,
            },
            wait: false,
            empty: false,
            script: None,
            control: None,
            scale: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum LaunchAction {
    Run(LaunchOptions),
    Help,
    Version,
    AgentIndexWorker,
}

/// Parse arguments after the executable name, matching the existing startup
/// option spellings and defaults. Unknown arguments remain file/folder paths.
pub fn parse_args(args: &[OsString]) -> LaunchAction {
    if args.len() == 4 && args[0] == OsStr::new("--agent-index") {
        return LaunchAction::AgentIndexWorker;
    }

    let mut options = LaunchOptions::default();
    let mut index = 0;
    while index < args.len() {
        let arg = args[index].to_str();
        match arg {
            Some("-h" | "--help") => return LaunchAction::Help,
            Some("--version") => return LaunchAction::Version,
            Some("--headless") => {
                options.headless = true;
                if let Some(value) = args.get(index + 1).and_then(|value| value.to_str()) {
                    options.size = parse_size_prefix(value);
                    index += 1;
                }
            }
            Some("--script") => {
                if let Some(value) = args.get(index + 1) {
                    options.script = Some(value.clone());
                    index += 1;
                }
            }
            Some("--control") => {
                if let Some(value) = args.get(index + 1) {
                    options.control = Some(value.clone());
                    index += 1;
                }
            }
            Some("--wait") => options.wait = true,
            Some("--scale") => {
                if let Some(value) = args.get(index + 1).and_then(|value| value.to_str()) {
                    options.scale = parse_scale(value);
                    index += 1;
                }
            }
            Some("--empty") => options.empty = true,
            _ => options.paths.push(args[index].clone()),
        }
        index += 1;
    }
    LaunchAction::Run(options)
}

fn decimal_prefix(bytes: &[u8]) -> (u32, usize) {
    let mut value = 0u32;
    let mut consumed = 0;
    for byte in bytes {
        if !byte.is_ascii_digit() {
            break;
        }
        value = value.wrapping_mul(10).wrapping_add(u32::from(byte - b'0'));
        consumed += 1;
    }
    (value, consumed)
}

fn parse_size_prefix(value: &str) -> Size {
    let bytes = value.as_bytes();
    let (width, consumed) = decimal_prefix(bytes);
    let height_start = consumed.saturating_add(1).min(bytes.len());
    let (height, _) = decimal_prefix(&bytes[height_start..]);
    Size { width, height }
}

fn parse_scale(value: &str) -> Option<f32> {
    let bytes = value.as_bytes();
    let (whole, consumed) = decimal_prefix(bytes);
    if consumed == 0 {
        return None;
    }
    let mut hundredths = whole;
    if bytes.get(consumed) == Some(&b'.') {
        let (fraction, fraction_len) = decimal_prefix(&bytes[consumed + 1..]);
        match fraction_len {
            1 => {
                hundredths = hundredths
                    .wrapping_mul(100)
                    .wrapping_add(fraction.wrapping_mul(10))
            }
            2 => hundredths = hundredths.wrapping_mul(100).wrapping_add(fraction),
            _ => hundredths = hundredths.wrapping_mul(100),
        }
    }
    if hundredths <= 10 {
        hundredths = hundredths.wrapping_mul(100);
    }
    (50..=400)
        .contains(&hundredths)
        .then_some(hundredths as f32 / 100.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(values: &[&str]) -> LaunchAction {
        let args = values.iter().map(OsString::from).collect::<Vec<_>>();
        parse_args(&args)
    }

    #[test]
    fn defaults_match_the_existing_startup() {
        assert_eq!(parse(&[]), LaunchAction::Run(LaunchOptions::default()));
    }

    #[test]
    fn options_are_consumed_and_paths_are_preserved() {
        let LaunchAction::Run(options) =
            parse(&["project", "--wait", "--empty", "file with spaces.rs"])
        else {
            panic!("expected a normal launch");
        };
        assert_eq!(
            options.paths,
            [
                OsString::from("project"),
                OsString::from("file with spaces.rs")
            ]
        );
        assert!(options.wait);
        assert!(options.empty);
        assert!(!options.headless);
    }

    #[test]
    fn headless_size_uses_the_existing_default_and_dimension_order() {
        let LaunchAction::Run(options) = parse(&["--headless", "960x540"]) else {
            panic!("expected a normal launch");
        };
        assert!(options.headless);
        assert_eq!(
            options.size,
            Size {
                width: 960,
                height: 540
            }
        );

        let LaunchAction::Run(options) = parse(&["--headless"]) else {
            panic!("expected a normal launch");
        };
        assert_eq!(
            options.size,
            Size {
                width: 1280,
                height: 800
            }
        );
    }

    #[test]
    fn script_and_control_values_are_not_paths() {
        let LaunchAction::Run(options) = parse(&[
            "--script",
            "tests/smoke.rsc",
            "--control",
            "rhun.sock",
            "file.rs",
        ]) else {
            panic!("expected a normal launch");
        };
        assert_eq!(options.script, Some(OsString::from("tests/smoke.rsc")));
        assert_eq!(options.control, Some(OsString::from("rhun.sock")));
        assert_eq!(options.paths, [OsString::from("file.rs")]);
    }

    #[test]
    fn scale_accepts_factors_and_percentages_and_ignores_out_of_range_values() {
        for (input, expected) in [
            ("0.5", Some(0.5)),
            ("1", Some(1.0)),
            ("1.5", Some(1.5)),
            ("4", Some(4.0)),
            ("50", Some(0.5)),
            ("150", Some(1.5)),
            ("401", None),
            ("0.49", None),
            ("bad", None),
        ] {
            assert_eq!(parse_scale(input), expected, "{input}");
        }
    }

    #[test]
    fn help_and_version_exit_during_argument_scanning() {
        assert_eq!(parse(&["project", "--help"]), LaunchAction::Help);
        assert_eq!(parse(&["--version"]), LaunchAction::Version);
        assert!(USAGE.starts_with("usage: rhun [folder] [files...]"));
        assert!(VERSION.starts_with("rhun "));
    }

    #[test]
    fn agent_worker_dispatch_preserves_its_argv_shape_guard() {
        assert_eq!(
            parse(&["--agent-index", "a", "b", "c"]),
            LaunchAction::AgentIndexWorker
        );
        let LaunchAction::Run(options) = parse(&["--agent-index"]) else {
            panic!("worker dispatch requires exactly four following arguments");
        };
        assert_eq!(options.paths, [OsString::from("--agent-index")]);
    }

    #[test]
    fn non_utf8_paths_are_kept_as_paths() {
        #[cfg(unix)]
        {
            use std::os::unix::ffi::OsStringExt;
            let path = OsString::from_vec(vec![b'f', 0xff]);
            let action = parse_args(&[path.clone()]);
            let LaunchAction::Run(options) = action else {
                panic!("expected a normal launch");
            };
            assert_eq!(options.paths, [path]);
        }
    }
}
