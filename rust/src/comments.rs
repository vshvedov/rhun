use std::path::Path;

pub fn token_for_path(path: &Path) -> Option<&'static str> {
    let name = path.file_name()?.to_str()?.to_ascii_lowercase();
    if matches!(
        name.as_str(),
        "dockerfile"
            | "containerfile"
            | "makefile"
            | "gnumakefile"
            | "justfile"
            | ".justfile"
            | "gemfile"
            | "rakefile"
            | "sconstruct"
            | "sconscript"
            | ".bashrc"
            | ".bash_profile"
            | ".bash_aliases"
            | ".zshrc"
            | ".zprofile"
            | ".zshenv"
            | ".profile"
            | ".gitignore"
            | ".dockerignore"
            | ".npmignore"
            | ".prettierignore"
            | ".eslintignore"
            | ".hgignore"
            | ".gitattributes"
    ) {
        return Some("#");
    }
    let extension = path.extension()?.to_str()?.to_ascii_lowercase();
    match extension.as_str() {
        "rs" | "c" | "h" | "cc" | "cpp" | "cxx" | "hh" | "hpp" | "hxx" | "js" | "mjs" | "cjs"
        | "jsx" | "ts" | "mts" | "cts" | "tsx" | "java" | "kt" | "kts" | "go" | "swift" | "cs"
        | "csx" | "scala" | "sc" | "sbt" | "dart" | "d" | "di" | "glsl" | "vert" | "frag"
        | "geom" | "comp" | "hlsl" | "wgsl" | "metal" | "sql" => {
            if extension == "sql" {
                Some("--")
            } else {
                Some("//")
            }
        }
        "py" | "pyi" | "pyw" | "sh" | "bash" | "zsh" | "ksh" | "fish" | "yaml" | "yml" | "toml"
        | "rb" | "rake" | "gemspec" | "pl" | "pm" | "t" | "ps1" | "psm1" | "psd1" | "ex"
        | "exs" | "nix" | "tf" | "tfvars" | "hcl" | "ini" | "cfg" | "conf" | "properties"
        | "env" | "awk" | "cr" | "jl" | "r" | "vim" | "mk" | "mak" | "cmake" | "ninja"
        | "graphql" | "gql" | "http" | "rest" | "zig" | "zon" | "v" | "vsh" | "vala" | "vapi"
        | "rego" | "mojo" => Some("#"),
        "lua" | "rockspec" | "hs" | "lhs" | "ada" | "elm" | "lean" | "idr" | "lidr" | "purs"
        | "vhd" | "vhdl" | "dhall" => Some("--"),
        "m" | "mm" | "pas" | "dpr" | "lpr" | "dpk" | "proto" | "json" | "jsonc" | "json5"
        | "jsonl" | "ron" | "pkl" | "prisma" | "cue" | "php" | "phtml" => Some("//"),
        "tex" | "sty" | "cls" | "ltx" | "dtx" | "bib" => Some("%"),
        "bat" | "cmd" => Some("REM"),
        "haml" => Some("-#"),
        "pug" | "jade" => Some("//-"),
        "slim" => Some("/"),
        "vb" | "vbs" => Some("'"),
        "asm" | "s" | "inc" => Some("#"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chooses_existing_common_language_comment_tokens() {
        for (path, expected) in [
            ("src/main.rs", "//"),
            ("scripts/setup.py", "#"),
            ("query.sql", "--"),
            ("package.json", "//"),
            ("message.proto", "//"),
            ("Dockerfile", "#"),
            ("view.haml", "-#"),
            ("file.unknown", ""),
        ] {
            let actual = token_for_path(Path::new(path)).unwrap_or("");
            assert_eq!(actual, expected, "{path}");
        }
    }
}
