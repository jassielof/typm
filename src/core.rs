use anyhow::{anyhow, Context, Result};
use globset::{Glob, GlobSetBuilder};
use regex::Regex;
use std::{
    fs,
    path::Path,
    process::Command,
};
use walkdir::WalkDir;

pub fn validate_package_name(package_name: &str, toml_dir: &Path) -> Result<()> {
    let parent_dir_name = toml_dir
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| anyhow!("Could not determine parent directory name for: {}", toml_dir.display()))?;

    if package_name != parent_dir_name {
        return Err(anyhow!(
            "Package name '{}' does not match parent directory name '{}'",
            package_name,
            parent_dir_name
        ));
    }
    Ok(())
}

pub fn compile_template(
    toml_dir: &Path,
    package_name: &str,
    template_path_str: &str,
    template_entrypoint_str: &str,
) -> Result<()> {
    let template_full_path = Path::new(package_name)
        .join(template_path_str)
        .join(template_entrypoint_str);
    let project_root = toml_dir.parent().ok_or_else(|| {
        anyhow!("Failed to get parent directory of TOML file: {}", toml_dir.display())
    })?;

    let output = Command::new("typst")
        .args(["compile", "--root", "."])
        .arg(&template_full_path)
        .current_dir(project_root)
        .output()
        .with_context(|| {
            format!(
                "Failed to compile template: {} (current_dir: {})",
                template_full_path.display(),
                project_root.display()
            )
        })?;

    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow!(
            "Template compilation failed for {}\nStdout: {}\nStderr: {}",
            template_full_path.display(),
            stdout,
            stderr
        ));
    }
    Ok(())
}

pub fn generate_thumbnail(
    toml_dir: &Path,
    package_name: &str,
    template_path_str: &str,
    template_entrypoint_str: &str,
    thumbnail_path_str: &str,
) -> Result<()> {
    let template_full_path = Path::new(package_name)
        .join(template_path_str)
        .join(template_entrypoint_str);
    let thumbnail_full_path = Path::new(package_name).join(thumbnail_path_str);
    let project_root = toml_dir.parent().ok_or_else(|| {
        anyhow!("Failed to get parent directory of TOML file: {}", toml_dir.display())
    })?;

    let template_arg = template_full_path.to_str().ok_or_else(|| {
        anyhow!("Template path is not valid UTF-8: {}", template_full_path.display())
    })?;
    let thumbnail_arg = thumbnail_full_path.to_str().ok_or_else(|| {
        anyhow!("Thumbnail path is not valid UTF-8: {}", thumbnail_full_path.display())
    })?;

    let output = Command::new("typst")
        .args([
            "compile",
            "--root",
            ".",
            "--pages",
            "1",
            template_arg,
            thumbnail_arg,
        ])
        .current_dir(project_root)
        .output()
        .with_context(|| {
            format!(
                "Failed to generate thumbnail: {} -> {} (current_dir: {})",
                template_full_path.display(),
                thumbnail_full_path.display(),
                project_root.display()
            )
        })?;

    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow!(
            "Thumbnail generation failed for {}\nStdout: {}\nStderr: {}",
            template_full_path.display(),
            stdout,
            stderr
        ));
    }
    Ok(())
}

pub fn copy_files(
    source_dir: &Path,
    dest_dir: &Path,
    exclude_patterns: &[String],
    package_name: &str,
    package_version: &str,
    package_entrypoint: &str,
) -> Result<()> {
    fs::create_dir_all(dest_dir)
        .with_context(|| format!("Failed to create destination directory: {}", dest_dir.display()))?;

    let mut glob_builder = GlobSetBuilder::new();
    for pattern in exclude_patterns {
        let glob = Glob::new(pattern)
            .with_context(|| format!("Invalid glob pattern: '{}'", pattern))?;
        glob_builder.add(glob);
    }
    let glob_set = glob_builder.build()
        .with_context(|| "Failed to build glob set from exclude patterns")?;

    let directory_patterns: Vec<String> = exclude_patterns
        .iter()
        .filter(|p| !has_glob_metacharacters(p))
        .filter_map(|p| {
            let pattern_native = p.replace('/', &std::path::MAIN_SEPARATOR.to_string());
            let pattern_path = source_dir.join(&pattern_native);
            let is_dir_pattern = p.ends_with('/') || pattern_path.is_dir();
            is_dir_pattern.then(|| {
                pattern_native
                    .trim_end_matches(std::path::MAIN_SEPARATOR)
                    .to_string()
            })
        })
        .collect();

    let entrypoint_name = Path::new(package_entrypoint)
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| anyhow!("Invalid entrypoint name: {}", package_entrypoint))?;

    let import_re = Regex::new(&format!(
        r#"#import\s+"((?:\.\./)+{})((?::\s*[^"]*)?)""#,
        regex::escape(entrypoint_name)
    ))?;
    let package_import_str = format!("@preview/{}:{}", package_name, package_version);

    for entry in WalkDir::new(source_dir) {
        let entry = entry.with_context(|| format!("Error walking directory: {}", source_dir.display()))?;
        let src_path = entry.path();
        let rel_path = src_path.strip_prefix(source_dir).with_context(|| {
            format!("Failed to strip prefix '{}' from '{}'", source_dir.display(), src_path.display())
        })?;

        let rel_str_unix = rel_path.to_str()
            .ok_or_else(|| anyhow!("Path contains non-UTF8 characters: {:?}", rel_path))?
            .replace(std::path::MAIN_SEPARATOR, "/");

        if glob_set.is_match(&rel_str_unix) {
            continue;
        }

        let rel_str_native = rel_path.to_str().unwrap(); // Already checked for UTF8

        let excluded_by_dir = directory_patterns.iter().any(|pattern| {
            rel_str_native == pattern
                || rel_str_native.starts_with(&format!("{}{}", pattern, std::path::MAIN_SEPARATOR))
        });

        if excluded_by_dir {
            continue;
        }

        let dst_path = dest_dir.join(rel_path);

        if entry.file_type().is_dir() {
            fs::create_dir_all(&dst_path)
                .with_context(|| format!("Failed to create directory: {}", dst_path.display()))?;
        } else {
            // Ensure parent directory exists for the file
            if let Some(parent) = dst_path.parent() {
                fs::create_dir_all(parent).with_context(|| format!("Failed to create parent directory for: {}", dst_path.display()))?;
            }

            if src_path.file_name().and_then(|n| n.to_str()) == Some("typst.toml") {
                let content = fs::read_to_string(src_path)
                    .with_context(|| format!("Failed to read file: {}", src_path.display()))?;
                let filtered = content
                    .lines()
                    .filter(|line| !line.trim_start().starts_with("#:schema"))
                    .collect::<Vec<_>>()
                    .join("\n");
                fs::write(&dst_path, filtered)
                    .with_context(|| format!("Failed to write filtered typst.toml to: {}", dst_path.display()))?;
            } else if src_path.extension().and_then(|e| e.to_str()) == Some("typ") {
                let content = fs::read_to_string(src_path)
                    .with_context(|| format!("Failed to read .typ file: {}", src_path.display()))?;

                let new_content = import_re.replace_all(&content, |caps: &regex::Captures| {
                    let specifier = caps.get(2).map_or("", |m| m.as_str());
                    format!("#import \"{}{}\"", package_import_str, specifier)
                });
                fs::write(&dst_path, new_content.as_bytes())
                    .with_context(|| format!("Failed to write modified .typ file to: {}", dst_path.display()))?;
            } else {
                fs::copy(src_path, &dst_path).with_context(|| {
                    format!("Failed to copy file from '{}' to '{}'", src_path.display(), dst_path.display())
                })?;
            }
        }
    }
    Ok(())
}

pub fn has_glob_metacharacters(s: &str) -> bool {
    s.contains(['*', '?', '[']) // ']' is only a metacharacter if '[' is present
}
