import os
from pathlib import Path
import re
import shutil
import subprocess
import tomllib
from urllib.parse import urlparse

import typer
from .models import GitSourceDescriptor


def read_toml(path: Path) -> dict:
    with path.open("rb") as f:
        return tomllib.load(f)


def validate_package_name(package_name: str, toml_dir: Path) -> None:
    parent_dir_name = toml_dir.name
    if package_name != parent_dir_name:
        raise typer.BadParameter(
            f"Package name '{package_name}' does not match parent directory name '{parent_dir_name}'"
        )


def get_typst_version() -> tuple[int, int, int]:
    # Parse: "typst 0.12.0 (rev ...)" -> "0.12.0"
    try:
        out = subprocess.run(
            ["typst", "--version"], check=True, capture_output=True, text=True
        )
    except (OSError, subprocess.CalledProcessError) as e:
        raise typer.Exit(code=1) from e
    parts = out.stdout.strip().split()
    if len(parts) < 2:
        raise typer.Exit(code=1)
    return parse_semver(parts[1])


def parse_semver(v: str) -> tuple[int, int, int]:
    m = re.match(r"^\s*(\d+)\.(\d+)\.(\d+)", v)
    if not m:
        raise typer.BadParameter(f"Invalid semantic version: {v}")
    return int(m.group(1)), int(m.group(2)), int(m.group(3))


def cmp_semver(a: tuple[int, int, int], b: tuple[int, int, int]) -> int:
    return (a > b) - (a < b)


def matches_version_req(req: str, ver: tuple[int, int, int]) -> bool:
    # Minimal support for space-separated constraints like ">=0.12.0 <0.13.0"
    tokens = req.split()
    if not tokens:
        return True
    i = 0
    while i < len(tokens):
        t = tokens[i]
        op, v = None, None
        for prefix in (">=", "<=", "==", "!=", ">", "<", "="):
            if t.startswith(prefix):
                op, v = prefix, t[len(prefix) :]
                break
        if op is None:
            # Maybe separated operator and version: ["<", "1.2.3"]
            if i + 1 < len(tokens) and tokens[i] in (
                ">=",
                "<=",
                "==",
                "!=",
                ">",
                "<",
                "=",
            ):
                op, v = tokens[i], tokens[i + 1]
                i += 1
            else:
                # Unknown token, ignore for lenience
                i += 1
                continue
        try:
            sv = parse_semver(v)
        except Exception:
            return False
        c = cmp_semver(ver, sv)
        ok = {
            ">": c > 0,
            "<": c < 0,
            ">=": c >= 0,
            "<=": c <= 0,
            "==": c == 0,
            "=": c == 0,
            "!=": c != 0,
        }[op]
        if not ok:
            return False
        i += 1
    return True


def linux_data_dir() -> Path:
    base = os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local" / "share"))
    return Path(base) / "typst"


def linux_cache_dir() -> Path:
    base = os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))
    return Path(base) / "typst"


def compile_template(
    toml_dir: Path, package_name: str, template_path: str, template_entrypoint: str
) -> None:
    project_root = toml_dir.parent
    template_full_path = str(Path(package_name) / template_path / template_entrypoint)
    try:
        res = subprocess.run(
            ["typst", "compile", "--root", ".", template_full_path],
            cwd=project_root,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as e:
        raise typer.Exit(code=1) from e
    if res.returncode != 0:
        typer.echo(f"Template compilation failed for {template_full_path}")
        typer.echo(f"Stdout:\n{res.stdout}")
        typer.echo(f"Stderr:\n{res.stderr}")
        raise typer.Exit(code=1)


def generate_thumbnail(
    toml_dir: Path,
    package_name: str,
    template_path: str,
    template_entrypoint: str,
    thumbnail_path: str,
) -> None:
    project_root = toml_dir.parent
    template_full_path = str(Path(package_name) / template_path / template_entrypoint)
    thumbnail_full_path = str(Path(package_name) / thumbnail_path)
    try:
        res = subprocess.run(
            [
                "typst",
                "compile",
                "--root",
                ".",
                "--pages",
                "1",
                template_full_path,
                thumbnail_full_path,
            ],
            cwd=project_root,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as e:
        raise typer.Exit(code=1) from e
    if res.returncode != 0:
        typer.echo(f"Thumbnail generation failed for {template_full_path}")
        typer.echo(f"Stdout:\n{res.stdout}")
        typer.echo(f"Stderr:\n{res.stderr}")
        raise typer.Exit(code=1)


def should_exclude(file_path: str, exclude_patterns: list[str], base_dir: Path) -> bool:
    import fnmatch

    rel_path = os.path.relpath(file_path, base_dir)
    for pattern in exclude_patterns:
        if fnmatch.fnmatch(rel_path, pattern):
            return True
        if pattern.endswith("/") or (
            not any(c in pattern for c in "*?[]")
            and os.path.isdir(os.path.join(base_dir, pattern))
        ):
            p = pattern.rstrip("/").rstrip(os.sep)
            if rel_path == p or rel_path.startswith(p + os.sep):
                return True
    return False


def copy_files(
    source_dir: Path,
    dest_dir: Path,
    exclude_patterns: list[str],
    package_import_base: str,  # e.g., "preview/<name>" or "<ns>/<name>"
    package_version: str,
    package_entrypoint: str,
) -> None:
    dest_dir.mkdir(parents=True, exist_ok=True)
    entrypoint_name = Path(package_entrypoint).name
    full_package_import = f"@{package_import_base}:{package_version}"

    import_re = re.compile(
        r'#import\s+"((?:\.\./)+)' + re.escape(entrypoint_name) + r'((?::\s*[^"]*)?)"'
    )

    for root, dirs, files in os.walk(source_dir):
        # Avoid copying into itself if dest is within source
        try:
            # dest_rel = dest_dir.relative_to(source_dir)
            if Path(root).resolve().is_relative_to(dest_dir.resolve()):
                # Skip the destination subtree
                continue
        except Exception:
            pass

        for name in files:
            src_path = Path(root) / name
            if should_exclude(str(src_path), exclude_patterns, source_dir):
                continue

            rel_path = src_path.relative_to(source_dir)
            dst_path = dest_dir / rel_path
            dst_path.parent.mkdir(parents=True, exist_ok=True)

            if name == "typst.toml":
                content = src_path.read_text(encoding="utf-8")
                filtered = "\n".join(
                    line
                    for line in content.splitlines()
                    if not line.lstrip().startswith("#:schema")
                )
                dst_path.write_text(filtered, encoding="utf-8")
            elif src_path.suffix == ".typ":
                content = src_path.read_text(encoding="utf-8")
                content = import_re.sub(
                    lambda m: f'#import "{full_package_import}{m.group(2)}"', content
                )
                dst_path.write_text(content, encoding="utf-8")
            else:
                shutil.copy2(src_path, dst_path)


def parse_git_source(git_source_url: str) -> GitSourceDescriptor:
    # Alias form: gh|gl|bb/user/repo[/path/in/repo]
    parts = git_source_url.split("/")
    if len(parts) >= 3:
        alias = parts[0].lower()
        user = parts[1]
        repo_and_path = "/".join(parts[2:])
        host = {
            "gh": "github.com",
            "github": "github.com",
            "gl": "gitlab.com",
            "gitlab": "gitlab.com",
            "bb": "bitbucket.org",
            "bitbucket": "bitbucket.org",
        }.get(alias, "")
        if host and user and repo_and_path:
            repo_name, repo_path = (repo_and_path.split("/", 1) + [""])[:2]
            if repo_name:
                return GitSourceDescriptor(
                    repo_url_for_clone=f"https://{host}/{user}/{repo_name}.git",
                    git_ref=None,
                    path_in_repo=Path(repo_path),
                    provider_host=host,
                    user_or_org=user,
                )
    # URL form
    u = urlparse(git_source_url)
    if not u.scheme or not u.netloc:
        raise typer.BadParameter(f"Invalid Git source URL or alias: {git_source_url}")
    host = u.netloc.lower()
    if host.startswith("www."):
        host = host[4:]
    segs = [s for s in u.path.split("/") if s]
    if host == "github.com" and len(segs) >= 2:
        user = segs[0]
        repo = segs[1].removesuffix(".git")
        git_ref = None
        path_parts: list[str] = []
        if len(segs) > 3 and segs[2] in ("tree", "blob"):
            git_ref = segs[3]
            path_parts = segs[4:]
        elif len(segs) > 2:
            path_parts = segs[2:]
        return GitSourceDescriptor(
            repo_url_for_clone=f"https://{host}/{user}/{repo}.git",
            git_ref=git_ref,
            path_in_repo=Path("/".join(path_parts)),
            provider_host=host,
            user_or_org=user,
        )
    if host == "gitlab.com" and len(segs) >= 2:
        user = segs[0]
        repo = segs[1].removesuffix(".git")
        git_ref = None
        path_parts: list[str] = []
        if len(segs) > 4 and segs[2] == "-" and segs[3] in ("tree", "blob"):
            git_ref = segs[4]
            path_parts = segs[5:]
        elif len(segs) > 2:
            path_parts = segs[2:]
        return GitSourceDescriptor(
            repo_url_for_clone=f"https://{host}/{user}/{repo}.git",
            git_ref=git_ref,
            path_in_repo=Path("/".join(path_parts)),
            provider_host=host,
            user_or_org=user,
        )
    if host == "bitbucket.org" and len(segs) >= 2:
        user = segs[0]
        repo = segs[1].removesuffix(".git")
        # Bitbucket doesn't use /-/tree like GitLab; treat similarly to GitHub default path
        path_parts = segs[2:] if len(segs) > 2 else []
        return GitSourceDescriptor(
            repo_url_for_clone=f"https://{host}/{user}/{repo}.git",
            git_ref=None,
            path_in_repo=Path("/".join(path_parts)),
            provider_host=host,
            user_or_org=user,
        )
    raise typer.BadParameter(
        f"Unsupported Git URL format or provider (or invalid alias): {git_source_url}"
    )
