mod config;
mod core;

use anyhow::{Context, Result, anyhow};
use clap::Parser; // Required for Cli::parse()
use config::{Cli, Config};
use core::{compile_template, copy_files, generate_thumbnail, validate_package_name}; // Specific imports
use std::{fs, path::Path};

fn main() -> Result<()> {
    let args = Cli::parse();

    let toml_file_path_str = args.toml_file.to_string_lossy();
    let toml_path = if args.toml_file.is_file() {
        args.toml_file.clone()
    } else if args.toml_file.is_dir() {
        let path = args.toml_file.join("typst.toml");
        if !path.exists() {
            return Err(anyhow!(
                "No typst.toml found in directory: {}",
                args.toml_file.display()
            ));
        }
        path
    } else {
        return Err(anyhow!(
            "Path is neither a file nor a directory: {}",
            toml_file_path_str
        ));
    };

    let toml_dir = toml_path.parent().ok_or_else(|| {
        anyhow!(
            "Could not determine parent directory of TOML file: {}",
            toml_path.display()
        )
    })?;

    let config_content = fs::read_to_string(&toml_path)
        .with_context(|| format!("Failed to read TOML file: {}", toml_path.display()))?;
    let config: Config = toml::from_str(&config_content)
        .with_context(|| format!("Failed to parse TOML from: {}", toml_path.display()))?;

    validate_package_name(&config.package.name, toml_dir)?;

    if let Some(template_config) = &config.template {
        if let (Some(template_path), Some(template_entrypoint)) =
            (&template_config.path, &template_config.entrypoint)
        {
            // Ensure paths are not empty before proceeding
            if !template_path.is_empty() && !template_entrypoint.is_empty() {
                println!(
                    "Compiling template: {}/{}",
                    template_path, template_entrypoint
                );
                compile_template(
                    toml_dir,
                    &config.package.name,
                    template_path,
                    template_entrypoint,
                )?;

                if let Some(thumbnail_path) = &template_config.thumbnail {
                    if !thumbnail_path.is_empty() {
                        println!("Generating thumbnail: {}", thumbnail_path);
                        generate_thumbnail(
                            toml_dir,
                            &config.package.name,
                            template_path,
                            template_entrypoint,
                            thumbnail_path,
                        )?;
                    }
                }
            } else {
                // Optionally, log or warn if path/entrypoint are present but empty
                if template_path.is_empty() && template_config.path.is_some() {
                    println!("Warning: Template path is present but empty.");
                }
                if template_entrypoint.is_empty() && template_config.entrypoint.is_some() {
                    println!("Warning: Template entrypoint is present but empty.");
                }
            }
        }
    }

    let output_base_dir = Path::new(&args.output_dir);
    let final_output_dir = output_base_dir
        .join(&config.package.name)
        .join(&config.package.version);

    println!("Copying files to: {}", final_output_dir.display());
    copy_files(
        toml_dir,
        &final_output_dir,
        &config.package.exclude.clone().unwrap_or_default(),
        &config.package.name,
        &config.package.version,
        config.package.entrypoint.as_deref().unwrap_or("main.typ"),
    )?;

    println!(
        "Package '{}' v{} built successfully to {}",
        config.package.name,
        config.package.version,
        final_output_dir.display()
    );

    Ok(())
}
