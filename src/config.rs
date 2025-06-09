use clap::Parser;
use serde::Deserialize;
use std::path::PathBuf;

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
pub struct Cli {
    #[arg(value_name = "TOML_FILE")]
    pub toml_file: PathBuf,
    #[arg(long, value_name = "OUTPUT_DIR", default_value = "output", value_parser = ["output", "universe"])]
    pub output_dir: String,
}

#[derive(Debug, Deserialize)]
pub struct PackageConfig {
    pub name: String,
    pub version: String,
    pub exclude: Option<Vec<String>>,
    pub entrypoint: Option<String>,
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
