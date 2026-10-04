use serde_json::Value;
use std::error::Error;
use std::ffi::OsString;
use std::fs;
use std::path::PathBuf;
use std::process::{Command, ExitCode};

type Result<T = ()> = std::result::Result<T, Box<dyn Error>>;

fn run(command: &mut Command) -> Result {
    let status = command.status()?;
    if !status.success() {
        return Err(format!("Command failed ({status}): {command:?}").into());
    }
    Ok(())
}

fn cargo(args: &[&str]) -> Command {
    let mut command = Command::new(std::env::var_os("CARGO").unwrap_or_else(|| "cargo".into()));
    command.args(args);
    command
}

fn executable(name: &str) -> String {
    format!("{name}{}", std::env::consts::EXE_SUFFIX)
}

fn bundle_version(value: &str) -> Result<&str> {
    let base = value
        .trim_start_matches('v')
        .split(['-', '+'])
        .next()
        .unwrap_or_default();
    let parts: Vec<_> = base.split('.').collect();
    if parts.len() != 3
        || parts
            .iter()
            .any(|p| p.is_empty() || !p.bytes().all(|c| c.is_ascii_digit()))
    {
        return Err("Bundle version must be MAJOR.MINOR.PATCH".into());
    }
    Ok(base)
}

fn bundle(target: PathBuf, profile: &str, version: &str) -> Result {
    let directory = target.join(profile);
    let helper = target.join("release").join(executable("writer-helper"));
    if !cfg!(target_os = "macos") {
        if profile == "debug" {
            fs::copy(helper, directory.join(executable("writer-helper")))?;
        }
        println!("Built {}", directory.join(executable("blank_")).display());
        return Ok(());
    }
    let app = directory.join("bundle/blank_.app");
    let binaries = app.join("Contents/MacOS");
    fs::create_dir_all(&binaries)?;
    fs::copy(directory.join("blank_"), binaries.join("blank_"))?;
    fs::copy(helper, binaries.join("writer-helper"))?;
    fs::write(
        app.join("Contents/Info.plist"),
        format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>blank_</string>
<key>CFBundleDisplayName</key><string>blank_</string>
<key>CFBundleIdentifier</key><string>local.still.writer.rust-prototype</string>
<key>CFBundleExecutable</key><string>blank_</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>{version}</string>
<key>CFBundleVersion</key><string>{version}</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
"#
        ),
    )?;
    for path in [binaries.join("writer-helper"), app.clone()] {
        run(Command::new("codesign")
            .args(["--force", "--sign", "-"])
            .arg(path))?;
    }
    run(Command::new("codesign")
        .args(["--verify", "--deep", "--strict"])
        .arg(&app))?;
    println!("Built {}", app.display());
    Ok(())
}

fn execute() -> Result {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let task = args.first().and_then(|arg| arg.to_str()).unwrap_or("help");
    if matches!(task, "help" | "--help" | "-h") {
        println!(
            "cargo xtask dev [app arguments]\ncargo xtask check\ncargo xtask bundle [--debug]"
        );
        return Ok(());
    }
    if !matches!(task, "dev" | "check" | "bundle")
        || (task == "check" && args.len() != 1)
        || (task == "bundle" && !(args.len() == 1 || (args.len() == 2 && args[1] == "--debug")))
    {
        return Err("Unknown task or arguments. Run cargo xtask --help.".into());
    }
    std::env::set_current_dir(PathBuf::from(env!("CARGO_MANIFEST_DIR")).parent().unwrap())?;
    if task == "check" {
        for args in [
            &["fmt", "--all", "--", "--check"][..],
            &[
                "clippy",
                "--workspace",
                "--all-targets",
                "--locked",
                "--",
                "-D",
                "warnings",
            ],
            &["test", "--workspace", "--locked"],
        ] {
            run(&mut cargo(args))?;
        }
        return Ok(());
    }
    let metadata =
        cargo(&["metadata", "--no-deps", "--format-version", "1", "--locked"]).output()?;
    if !metadata.status.success() {
        return Err(String::from_utf8_lossy(&metadata.stderr)
            .into_owned()
            .into());
    }
    let metadata: Value = serde_json::from_slice(&metadata.stdout)?;
    let target = PathBuf::from(
        metadata["target_directory"]
            .as_str()
            .ok_or("missing Cargo target directory")?,
    );
    run(&mut cargo(&[
        "build",
        "--release",
        "--locked",
        "-p",
        "writer-helper",
    ]))?;
    if task == "dev" {
        let arguments = args[1..]
            .strip_prefix(&[OsString::from("--")])
            .unwrap_or(&args[1..]);
        return run(cargo(&["run", "--locked", "-p", "blank_", "--"])
            .env(
                "BLANK_HELPER",
                target.join("release").join(executable("writer-helper")),
            )
            .args(arguments));
    }
    let debug = args.len() == 2;
    let mut build = cargo(&["build", "--locked", "-p", "blank_"]);
    if !debug {
        build.arg("--release");
    }
    run(&mut build)?;
    let default_version = metadata["packages"]
        .as_array()
        .ok_or("missing Cargo packages")?
        .iter()
        .find(|p| p["name"] == "blank_")
        .and_then(|p| p["version"].as_str())
        .ok_or("missing blank_ version")?;
    let version = std::env::var("WRITER_VERSION").unwrap_or_else(|_| default_version.into());
    bundle(
        target,
        if debug { "debug" } else { "release" },
        bundle_version(&version)?,
    )
}

fn main() -> ExitCode {
    match execute() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn release_versions_are_safe_for_bundle_metadata() {
        assert_eq!(bundle_version("v1.2.3-rc.1+build").unwrap(), "1.2.3");
        assert_eq!(bundle_version("0.1.0").unwrap(), "0.1.0");
        for invalid in ["1.2", "1..3", "1.2.3.4", "1.2.<string>", "v", ""] {
            assert!(bundle_version(invalid).is_err(), "{invalid}");
        }
    }
}
