use clap::Parser;
use serde::Deserialize;
use std::path::PathBuf;

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Parser)]
pub enum Commands {
    /// Build a Typst package or template
    Build(BuildArgs),
    /// Install a Typst package from a Git repository
    Install(InstallArgs),
}

#[derive(Parser, Debug)]
pub struct BuildArgs {
    #[arg(value_name = "TOML_FILE")]
    pub toml_file: PathBuf,
    #[arg(long, value_name = "OUTPUT_DIR", default_value = "output", value_parser = ["output", "universe"])]
    pub output_dir: String,
}

#[derive(Parser, Debug)]
pub struct InstallArgs {
    /// URL of the Git repository or path to a local Git repository.
    /// Examples:
    /// - https://github.com/user/repo
    /// - https://github.com/user/repo.git
    /// - https://github.com/user/repo/tree/main/path/to/package_dir
    /// The tool will attempt to clone and find a typst.toml in the specified
    /// repository path (or root if no path is specified in the URL).
    #[arg(value_name = "GIT_SOURCE")]
    pub git_source: String,
    // Optional: Specify a branch, tag, or commit hash.
    // If not provided and the URL doesn't specify one (e.g., in a /tree/REF/path pattern),
    // the repository's default branch will be used.
    // #[arg(long)]
    // pub git_ref: Option<String>, // Future enhancement
}

#[derive(Debug, Deserialize)]
pub struct PackageConfig {
    pub name: String,
    pub version: String,
    pub exclude: Option<Vec<String>>,
    pub entrypoint: Option<String>,
    pub compiler: Option<String>, // Added for compiler version check
}

#[derive(Debug, Deserialize)]
pub struct TemplateConfig {
    pub path: Option<String>,
    pub entrypoint: Option<String>,
    pub thumbnail: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct Config {
    pub package: PackageConfig,
    pub template: Option<TemplateConfig>,
}
