mod config;
mod core;

use anyhow::{Context, Result, anyhow};
use clap::Parser;
use config::{BuildArgs, Cli, Commands, Config, InstallArgs};
use core::{compile_template, copy_files, generate_thumbnail, validate_package_name};
use serde::Deserialize;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

struct GitSourceDescriptor {
    repo_url_for_clone: String,
    git_ref: Option<String>,
    path_in_repo: PathBuf,
    provider_host: String,
    user_or_org: String,
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Build(args) => handle_build_command(args),
        Commands::Install(args) => handle_install_command(args),
    }
}

fn handle_build_command(args: BuildArgs) -> Result<()> {
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
            args.toml_file.to_string_lossy()
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
        &format!("preview/{}", config.package.name),
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

fn parse_git_source(git_source_url: &str) -> Result<GitSourceDescriptor> {
    let parsed_url = url::Url::parse(git_source_url)
        .with_context(|| format!("Invalid Git source URL: {}", git_source_url))?;

    let host = parsed_url
        .host_str()
        .ok_or_else(|| anyhow!("URL has no host"))?
        .to_lowercase();
    let path_segments: Vec<&str> = parsed_url
        .path_segments()
        .ok_or_else(|| anyhow!("URL has no path segments"))?
        .collect();

    let normalized_host = if host.starts_with("www.") {
        host.trim_start_matches("www.").to_string()
    } else {
        host
    };

    if normalized_host == "github.com" {
        if path_segments.len() >= 2 {
            let user_or_org = path_segments[0].to_string();
            let mut repo_name_str = path_segments[1].to_string();
            if repo_name_str.ends_with(".git") {
                repo_name_str = repo_name_str.trim_end_matches(".git").to_string();
            }

            let repo_url_for_clone = format!(
                "https://{}/{}/{}.git",
                normalized_host, user_or_org, repo_name_str
            );
            let mut git_ref: Option<String> = None;
            let mut path_in_repo_parts: Vec<&str> = Vec::new();

            if path_segments.len() > 3 && (path_segments[2] == "tree" || path_segments[2] == "blob")
            {
                git_ref = Some(path_segments[3].to_string());
                path_in_repo_parts = path_segments.iter().skip(4).cloned().collect();
            } else if path_segments.len() > 2 {
                path_in_repo_parts = path_segments.iter().skip(2).cloned().collect();
            }

            let path_in_repo = PathBuf::from(path_in_repo_parts.join("/"));

            return Ok(GitSourceDescriptor {
                repo_url_for_clone,
                git_ref,
                path_in_repo,
                provider_host: normalized_host,
                user_or_org,
            });
        }
    } else if normalized_host == "gitlab.com" {
        if path_segments.len() >= 2 {
            let user_or_org = path_segments[0].to_string();
            let mut repo_name_str = path_segments[1].to_string();
            if repo_name_str.ends_with(".git") {
                repo_name_str = repo_name_str.trim_end_matches(".git").to_string();
            }

            let repo_url_for_clone = format!(
                "https://{}/{}/{}.git",
                normalized_host, user_or_org, repo_name_str
            );

            let mut git_ref: Option<String> = None;
            let mut path_in_repo_parts: Vec<&str> = Vec::new();

            let skip_count = 2;
            if path_segments.len() > 4
                && path_segments[2] == "-"
                && (path_segments[3] == "tree" || path_segments[3] == "blob")
            {
                git_ref = Some(path_segments[4].to_string());
                path_in_repo_parts = path_segments.iter().skip(5).cloned().collect();
            } else if path_segments.len() > 2 {
                path_in_repo_parts = path_segments.iter().skip(skip_count).cloned().collect();
            }

            let path_in_repo = PathBuf::from(path_in_repo_parts.join("/"));

            return Ok(GitSourceDescriptor {
                repo_url_for_clone,
                git_ref,
                path_in_repo,
                provider_host: normalized_host,
                user_or_org,
            });
        }
    }
    Err(anyhow!(
        "Unsupported Git URL format or provider: {}",
        git_source_url
    ))
}

fn get_typst_data_dir() -> Result<PathBuf> {
    dirs_next::data_dir()
        .ok_or_else(|| anyhow!("Could not determine system data directory"))
        .map(|p| p.join("typst"))
}

fn get_current_typst_version() -> Result<semver::Version> {
    let output = Command::new("typst")
        .arg("--version")
        .output()
        .context("Failed to execute 'typst --version'")?;
    if !output.status.success() {
        return Err(anyhow!(
            "'typst --version' failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    let version_str = String::from_utf8_lossy(&output.stdout);
    let version_part = version_str.split_whitespace().nth(1).ok_or_else(|| {
        anyhow!(
            "Unexpected 'typst --version' output format: {}",
            version_str
        )
    })?;
    semver::Version::parse(version_part)
        .with_context(|| format!("Failed to parse typst version: {}", version_part))
}

fn handle_install_command(args: InstallArgs) -> Result<()> {
    println!("Attempting to install from: {}", args.git_source);

    let source_desc = parse_git_source(&args.git_source)?;

    let temp_dir = tempfile::Builder::new()
        .prefix("typst-build-git-")
        .tempdir()?;
    let clone_target_dir = temp_dir.path();

    println!(
        "Cloning {} into {}...",
        source_desc.repo_url_for_clone,
        clone_target_dir.display()
    );
    let mut git_clone_cmd = Command::new("git");
    git_clone_cmd.arg("clone").arg("--depth").arg("1");
    if let Some(ref git_ref) = source_desc.git_ref {
        git_clone_cmd.arg("--branch").arg(git_ref);
    }
    git_clone_cmd
        .arg(&source_desc.repo_url_for_clone)
        .arg(clone_target_dir);

    let clone_status = git_clone_cmd.status().with_context(|| {
        format!(
            "Failed to execute git clone for {}",
            source_desc.repo_url_for_clone
        )
    })?;
    if !clone_status.success() {
        return Err(anyhow!(
            "git clone failed for {}",
            source_desc.repo_url_for_clone
        ));
    }
    println!("Clone successful.");

    let package_source_path = clone_target_dir.join(&source_desc.path_in_repo);
    let toml_in_cloned_path = package_source_path.join("typst.toml");

    if !toml_in_cloned_path.exists() {
        return Err(anyhow!(
            "typst.toml not found at {}",
            toml_in_cloned_path.display()
        ));
    }

    let config_content = fs::read_to_string(&toml_in_cloned_path).with_context(|| {
        format!(
            "Failed to read typst.toml from {}",
            toml_in_cloned_path.display()
        )
    })?;
    #[derive(Deserialize)]
    struct PackageOnlyConfig {
        package: config::PackageConfig,
    }
    let fetched_pkg_config_outer: PackageOnlyConfig = toml::from_str(&config_content)
        .with_context(|| {
            format!(
                "Failed to parse typst.toml from {}",
                toml_in_cloned_path.display()
            )
        })?;
    let fetched_pkg_config = fetched_pkg_config_outer.package;

    println!(
        "Found package: {} v{}",
        fetched_pkg_config.name, fetched_pkg_config.version
    );

    if let Some(required_compiler_str) = &fetched_pkg_config.compiler {
        let required_version_req =
            semver::VersionReq::parse(required_compiler_str).with_context(|| {
                format!(
                    "Invalid compiler version requirement in package's typst.toml: {}",
                    required_compiler_str
                )
            })?;
        let current_typst_version = get_current_typst_version()?;
        if !required_version_req.matches(&current_typst_version) {
            return Err(anyhow!(
                "Package requires Typst version {} but you have {}. Please update Typst.",
                required_compiler_str,
                current_typst_version
            ));
        }
        println!(
            "Typst version check passed (required: {}, current: {}).",
            required_compiler_str, current_typst_version
        );
    }

    let data_dir = get_typst_data_dir()?;

    let provider_abbr = match source_desc.provider_host.as_str() {
        "github.com" => "gh",
        "gitlab.com" => "gl",
        "bitbucket.org" => "bb",
        _ => source_desc.provider_host.split('.').next().unwrap_or("unk"),
    };

    let typst_namespace_str = format!("{}-{}", provider_abbr, source_desc.user_or_org);
    let typst_package_name_str = fetched_pkg_config.name.clone();

    let final_install_dir = data_dir
        .join("packages")
        .join(&typst_namespace_str)
        .join(&typst_package_name_str)
        .join(&fetched_pkg_config.version);

    if final_install_dir.exists() {
        println!(
            "Package {} v{} already installed at {}. Overwriting.",
            fetched_pkg_config.name,
            fetched_pkg_config.version,
            final_install_dir.display()
        );
    }
    fs::create_dir_all(&final_install_dir).with_context(|| {
        format!(
            "Failed to create installation directory: {}",
            final_install_dir.display()
        )
    })?;

    println!("Installing to: {}", final_install_dir.display());

    let copy_files_import_base = format!("{}/{}", typst_namespace_str, typst_package_name_str);

    copy_files(
        &package_source_path,
        &final_install_dir,
        &fetched_pkg_config.exclude.clone().unwrap_or_default(),
        &copy_files_import_base,
        &fetched_pkg_config.version,
        fetched_pkg_config
            .entrypoint
            .as_deref()
            .unwrap_or("main.typ"),
    )?;

    let import_statement = format!(
        "#import \"@{}/{}:{}\": ...",
        typst_namespace_str, typst_package_name_str, fetched_pkg_config.version
    );
    println!(
        "\nPackage '{}' v{} installed successfully.",
        fetched_pkg_config.name, fetched_pkg_config.version
    );
    println!("You can now import it using: {}", import_statement);

    Ok(())
}
