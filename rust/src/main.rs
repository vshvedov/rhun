mod app;
mod comments;
mod config;
mod document;
mod project_search;
mod quick_open;
mod session;
mod workspace;

use std::ffi::OsString;
use std::process::ExitCode;

use app::RhunApp;
use eframe::egui;
use rhun_native_core::{LaunchAction, LaunchOptions, USAGE, VERSION, parse_args};

fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let options = match parse_args(&args) {
        LaunchAction::Help => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        LaunchAction::Version => {
            println!("{}", VERSION.trim());
            return ExitCode::SUCCESS;
        }
        LaunchAction::Run(options) => options,
        LaunchAction::AgentIndexWorker => {
            eprintln!("rhun: the Rust agent-index worker is not migrated yet");
            return ExitCode::FAILURE;
        }
    };

    if options.headless || options.script.is_some() || options.control.is_some() {
        eprintln!(
            "rhun: --headless, --script, and --control are not available in the Rust build yet"
        );
        return ExitCode::FAILURE;
    }

    launch(options)
}

fn launch(options: LaunchOptions) -> ExitCode {
    let viewport = egui::ViewportBuilder::default()
        .with_title("rhun")
        .with_inner_size([options.size.width as f32, options.size.height as f32]);

    let native_options = eframe::NativeOptions {
        viewport,
        ..Default::default()
    };
    match eframe::run_native(
        "rhun",
        native_options,
        Box::new(move |creation_context| {
            if let Some(scale) = options.scale {
                creation_context.egui_ctx.set_zoom_factor(scale);
            }
            Ok(Box::new(RhunApp::new(options)))
        }),
    ) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("rhun: could not start the native window: {error}");
            ExitCode::FAILURE
        }
    }
}
