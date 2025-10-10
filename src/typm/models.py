from dataclasses import dataclass
from pathlib import Path


@dataclass
class GitSourceDescriptor:
    repo_url_for_clone: str
    git_ref: str | None
    path_in_repo: Path
    provider_host: str
    user_or_org: str
