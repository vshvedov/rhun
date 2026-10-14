{
  "document": {
    "title": "Rhun: project idea, history, current state, and direction",
    "purpose": "Give contributors a detailed, structured explanation of what Rhun is, what the existing project has been, what has been built so far in the Rust migration, and what must happen next.",
    "format": "This file is intentionally a JSON document despite its .md extension."
  },
  "project": {
    "name": "Rhun",
    "repository": "https://github.com/vshvedov/rhun",
    "category": [
      "lightweight code editor",
      "developer workspace",
      "user-directed AI coding harness"
    ],
    "one_sentence_summary": "Rhun is a compact desktop workspace for reading and editing code, running shells and external coding tools, navigating projects, and inspecting Git changes without requiring a large general-purpose IDE.",
    "problem_it_addresses": "As coding agents and command-line tools do more of the implementation work, developers still need a fast, convenient place to inspect and edit code, browse files, run commands, and review changes. Rhun brings those activities together while keeping the user in control.",
    "product_positioning": "A focused coding workspace and harness, not an autonomous coding agent and not a simplified clone of a full IDE.",
    "design_goals": [
      "Start quickly and use little memory and disk space.",
      "Keep common code-reading, editing, search, terminal, and Git workflows close together.",
      "Preserve familiar editor interactions, shortcuts, and user configuration.",
      "Observe sessions started by external coding-agent tools rather than silently starting or directing agents.",
      "Keep AI-assisted output explicit, bounded, reviewable, and under user control.",
      "Avoid telemetry; the repository describes Rhun as having no telemetry."
    ]
  },
  "what_the_original_project_has_been": {
    "implementation": {
      "primary_language": "Assembly",
      "source_location": "src/",
      "production_status": "The Assembly application and its existing build and release path remain the production/reference implementation.",
      "shared_implementation_character": "A custom application, software-rendering, UI, text, image, and platform stack, with platform-specific native integrations."
    },
    "user_facing_capabilities": {
      "editing": [
        "Tabbed code editing",
        "Syntax highlighting",
        "Find and replace",
        "Optional Vim mode",
        "Configurable editor behavior and themes"
      ],
      "project_navigation": [
        "Project explorer",
        "Fuzzy file navigation",
        "Search across project files",
        "Command palette and documented keyboard shortcuts"
      ],
      "terminal": [
        "Built-in terminal alongside source code",
        "Shell and command execution",
        "Platform-native PTY or ConPTY support"
      ],
      "git": [
        "Changed-file and diff inspection",
        "Stage, unstage, commit, pull, push, fetch, and related repository workflows",
        "Commit-message drafting can use configured Claude, Codex, or local Ollama providers"
      ],
      "external_agent_observation": [
        "Agents panel observes sessions from supported external tools, including Claude Code, Codex, and Grok Build.",
        "The panel is an observer of externally launched work; Rhun is not intended to autonomously implement changes."
      ],
      "appearance_and_assets": [
        "Light and dark appearances",
        "A collection of 40 built-in themes",
        "System appearance integration and Omarchy-specific theme-following behavior",
        "Bundled font, icons, syntax grammars, and runtime assets"
      ],
      "additional_workflows": [
        "Image viewing",
        "Per-project session and open-file restoration",
        "Headless and scripted UI workflows",
        "Platform-specific installation, updates, and application integration"
      ]
    },
    "supported_platforms": [
      {
        "platform": "Linux",
        "architecture": "x86-64",
        "integrations": [
          "Wayland",
          "X11",
          "XKB"
        ]
      },
      {
        "platform": "macOS",
        "architecture": "Apple silicon / AArch64",
        "integrations": [
          "Native AppKit glue",
          "macOS packaging and signing workflows"
        ]
      },
      {
        "platform": "Windows",
        "architecture": "x64",
        "integrations": [
          "Win32",
          "Windows 10 version 1809 or later and Windows 11",
          "Unicode paths and clipboard",
          "ConPTY terminal",
          "Windows installer and updater"
        ]
      }
    ],
    "important_compatibility_principle": "A language migration is not permission to remove functionality, change the product into an autonomous agent, or redesign interactions for convenience. Existing behavior, tests, assets, supported platforms, and release workflows are the evidence and compatibility target."
  },
  "migration_history_and_current_state": {
    "migration_goal": "Replace the Assembly implementation with a native Rust implementation while preserving Rhun's features, user experience, keyboard shortcuts, workflows, and supported platforms as closely as possible.",
    "audit_and_baseline": {
      "status": "Documented in docs/native-rust-migration.md before the Rust source work.",
      "scope_audited": [
        "Application source and platform-specific runtime",
        "Build scripts, generated assets, and tool dependencies",
        "Tests and CI workflows",
        "Installers, packaging, update flows, and documentation",
        "Feature inventory, supported operating systems, and compatibility gates"
      ],
      "baseline_record": "The migration document records Windows Assembly build and test results, original test failures, installer/update results, and platforms unavailable for baseline execution on the Windows host."
    },
    "rust_implementation": {
      "location": "rust/",
      "shape": "A separate Cargo package that coexists with the original source so the Rust prototype can be tested without replacing or deleting the Assembly implementation.",
      "gui_prototype": "A native desktop editor prototype using eframe/egui, with the rendering and widget differences from Rhun's original custom software-rendered UI still requiring compatibility evaluation.",
      "tested_host": "Windows x64 using the MSVC Rust toolchain.",
      "production_cutover": false,
      "assembly_removed": false
    },
    "implemented_and_tested_rust_slices": {
      "startup_and_cli": [
        "Argument parsing and selected existing option spellings/defaults",
        "Path preservation and parsing for selected headless size and scale options",
        "Help and version dispatch",
        "Some special modes are parsed but explicitly not implemented by the new application."
      ],
      "editor_and_documents": [
        "Open and edit text files in a native window",
        "Save and path-based Save As",
        "Multiple in-memory tabs and dirty-document close/exit prompts",
        "Find, replace, go-to-line, and selected tab/file operations",
        "Bounded undo/redo with typing coalescing and UTF-8-safe cursor/selection restoration",
        "Initial indentation, outdent, line indent, line duplication/deletion/movement, comment toggling, and line selection",
        "Basic configurable tab width, spaces-versus-tabs, automatic character pairing, whitespace trimming, and final-newline handling",
        "Basic settings-file path resolution and periodic settings reload"
      ],
      "project_and_sessions": [
        "Lazy project-tree browsing and refresh",
        "Asynchronous fuzzy file search and project text search with result bounds and ignore rules",
        "Basic restoration and saving of per-project open-file paths, active tab, and cursor offsets using the existing session format",
        "Reopening recently closed file tabs"
      ],
      "platform_configuration": [
        "XDG configuration location precedence",
        "Windows APPDATA configuration fallback",
        "Windows x64 test execution"
      ],
      "latest_test_evidence": {
        "windows_rust_unit_tests": "93 tests passed: 8 library tests and 85 binary tests.",
        "formatting": "cargo fmt --manifest-path rust\\Cargo.toml -- --check passed after formatting.",
        "repository_diff_check": "git diff --check passed.",
        "latest_lint_and_release_status": "The most recent attempts did not complete reliably because multiple Rust installations were selected inconsistently: the default Cargo is a GNU build, while the verified target is MSVC. The 93-test Windows MSVC run passed; do not infer that a fresh Clippy or release build for the latest changes passed from that test result.",
        "interactive_smoke": "The migration notes record earlier Windows GUI smoke checks for opening/editing/saving a file and browsing a project. These are not full automated GUI parity tests."
      }
    },
    "not_completed": [
      "The Rust program is not a feature-complete replacement and is not the production application.",
      "The original Assembly implementation has not been retired.",
      "Terminal and PTY/ConPTY behavior has not been migrated.",
      "Git workflows, diffs, history, and commit-message provider integration have not been migrated.",
      "The external agent-session observer and provider settings have not been wired into the Rust UI.",
      "Rhun-compatible Vim behavior, full syntax grammars, theme selection, and renderer parity have not been completed.",
      "Image formats and image-viewing interactions have not been migrated.",
      "Native dialogs, complete settings UI, appearance integration, and platform adapters are incomplete.",
      "The control/headless scripting protocol and its fixture behavior are incomplete.",
      "Installer, updater, packaging, release CI, and production cutover remain Assembly-based.",
      "Linux and macOS Rust builds and behavior have not been verified."
    ],
    "migration_phase_status": [
      {
        "phase": 1,
        "name": "Audit and baseline",
        "status": "Documented; original implementation remains the reference."
      },
      {
        "phase": 2,
        "name": "Standalone Rust application",
        "status": "Partial startup/editor prototype; not a cutover."
      },
      {
        "phase": 3,
        "name": "Shared primitives and document behavior",
        "status": "Partial document, search, session, and editing slices."
      },
      {
        "phase": 4,
        "name": "Graphics and headless compatibility harness",
        "status": "Not complete."
      },
      {
        "phase": 5,
        "name": "Native platform adapters",
        "status": "Not complete; only Windows has Rust test evidence."
      },
      {
        "phase": 6,
        "name": "Application features",
        "status": "Partial; major subsystems remain."
      },
      {
        "phase": 7,
        "name": "Distribution cutover and Assembly retirement",
        "status": "Not started."
      }
    ]
  },
  "product_and_migration_constraints": {
    "ai_harness_behavior": [
      "Do not make Rhun autonomously edit files, execute agent instructions, or start background coding agents.",
      "Keep agent integrations observational for sessions started by the user in external tools.",
      "Keep AI-assisted commit-message generation opt-in, bounded, and reviewable; generating a draft must not stage or commit changes.",
      "Do not silently substitute a different provider or perform an unrequested fallback."
    ],
    "migration_safety": [
      "Keep Assembly sources, tests, assets, and build scripts until Rust passes evidence-based compatibility and release gates.",
      "Implement in small subsystems and test each changed behavior against existing fixtures where possible.",
      "Do not treat compilation as proof of behavior or platform parity.",
      "Document failures that existed in the Assembly baseline separately from Rust regressions.",
      "Avoid unrelated changes and preserve user or contributor work."
    ],
    "dependency_policy": "Add dependencies only for a demonstrated subsystem need; document license, platform support, binary/distribution impact, and compatibility evidence."
  },
  "detailed_direction": {
    "end_state": "A native Rust Rhun that can replace the Assembly application on every supported target, keeps the same core product identity and workflows, passes the compatibility suite, and builds, installs, updates, and releases from a clean checkout without the Assembly translator or toolchain.",
    "remaining_work_areas": [
      {
        "area": "Editor parity",
        "required_work": [
          "Match document buffer, line indexing, selection, scrolling, wrapping, and horizontal-scroll behavior.",
          "Port savepoints, undo grouping, reload prompts, read-only handling, external edits, and file movement/symlink behavior.",
          "Match key bindings, language-sensitive indentation and pairing, comment behavior, and line-operation edge cases.",
          "Port Vim modes, motions, operators, text objects, repeat/search/Ex workflows, and documented omissions."
        ]
      },
      {
        "area": "Rendering, syntax, themes, and images",
        "required_work": [
          "Decide and validate whether egui can meet the original rendering, interaction, accessibility, and footprint requirements or whether the custom renderer must be ported.",
          "Port font and icon rendering, UI widgets, dialogs, tooltips, scrolling, hit-testing, and software/headless rendering behavior.",
          "Load built-in and user syntax grammars and preserve language detection and theme behavior.",
          "Support the documented image formats, orientation, transparency, zoom, pan, fit, status, and reload workflows."
        ]
      },
      {
        "area": "Workspace and settings",
        "required_work": [
          "Complete explorer actions, menus, keyboard navigation, project switching, recent folders, and native path dialogs.",
          "Port settings UI, configuration compatibility, live reload, appearance following, and per-project preferences.",
          "Match session restore rules, multi-window workflows, file watching, process lifecycle, and platform path handling."
        ]
      },
      {
        "area": "Terminal",
        "required_work": [
          "Implement platform PTY/ConPTY process creation and lifecycle.",
          "Port terminal rendering, tabs, scrollback, colors, keyboard/mouse protocols, full-screen applications, copy/paste, links, font/zoom, and panel workflows.",
          "Compare terminal behavior and exact fixtures with the Assembly application on every supported platform."
        ]
      },
      {
        "area": "Git and user-directed AI harness",
        "required_work": [
          "Port repository discovery, file statuses, gutter, diffs, history, staging, discard/reset, commits, and network operations with existing error handling.",
          "Port the safe commit-message draft workflow and provider configuration without automatic staging or committing.",
          "Observe supported external agent sessions, including provider discovery, refresh, pagination, worktrees, nested paths, hidden-panel behavior, and shutdown."
        ]
      },
      {
        "area": "Platform, compatibility, and release",
        "required_work": [
          "Implement Linux Wayland/X11, macOS Apple-silicon AppKit, and Windows Win32 integrations.",
          "Port CLI, control protocol, headless and scripted behavior, launch/foreground behavior, appearance, scaling, clipboard, and file associations.",
          "Port installers, packaging, signing/notarization where applicable, updates, and release CI.",
          "Run clean-checkout builds and relevant original/Rust tests on all supported operating systems.",
          "Remove Assembly and its build dependencies only after all parity and distribution gates pass."
        ]
      }
    ],
    "acceptance_criteria": [
      "Every existing feature and workflow in the compatibility checklist is implemented or explicitly classified as an intentional, approved change.",
      "Existing regression fixtures have Rust equivalents or documented reasons why a behavior cannot be compared.",
      "Relevant tests pass on Linux, macOS Apple silicon, and Windows x64.",
      "Native GUI, terminal, Git, AI-harness observer, install, update, and launch workflows have functional evidence, not just compile evidence.",
      "A clean checkout builds and packages the Rust application without Assembly sources, the Assembly translator, assembler, or linker.",
      "Documentation accurately describes supported platforms, shortcuts, configuration, limitations, and release instructions.",
      "The product remains a lightweight, user-directed coding workspace and harness rather than becoming an autonomous agent."
    ]
  },
  "working_tree_note": "The existing migration artifacts and Rust prototype are retained. This file explains the project and current migration; it does not declare the full migration complete."
}
