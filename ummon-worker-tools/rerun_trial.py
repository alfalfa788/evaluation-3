#!/usr/bin/env python3
"""Archive one completed Harbor trial and backfill its job slot."""

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class RerunError(Exception):
    pass


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise RerunError(f"Cannot read valid JSON from {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise RerunError(f"Expected a JSON object in {path}")
    return value


def trial_directories(job_path: Path) -> set[str]:
    return {
        child.name
        for child in job_path.iterdir()
        if child.is_dir()
        and (child / "config.json").is_file()
        and (child / "result.json").is_file()
    }


def default_archive_root(job_path: Path) -> Path:
    return job_path.parent.parent / "rejected"


DEFAULT_ENV_FILENAME = "proxy.env"
PROXY_KEY_NAMES = ("GEMINI_API_KEY", "ANTHROPIC_API_KEY")


def resolve_env_file(
    explicit_path: Path | None, job_path: Path | None = None
) -> Path | None:
    """Locate the proxy environment file.

    An explicit --env-file must exist. Otherwise look for proxy.env in the
    current directory and then beside the jobs/ directory, so a plain
    `rerun_trial.py jobs/<job> <model> --reason ...` picks up the same
    credentials the original `harbor run` used.
    """
    if explicit_path is not None:
        path = explicit_path.expanduser().resolve()
        if not path.is_file():
            raise RerunError(f"Environment file does not exist: {path}")
        return path

    candidates = [Path.cwd() / DEFAULT_ENV_FILENAME]
    if job_path is not None:
        candidates.append(job_path.parent.parent / DEFAULT_ENV_FILENAME)
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    return None


def require_proxy_credentials(environment: dict[str, str], env_file: Path | None) -> None:
    """Fail before archiving if the resume would run without proxy credentials."""
    if any(environment.get(name) for name in PROXY_KEY_NAMES):
        return
    raise RerunError(
        f"No proxy credentials found: none of {', '.join(PROXY_KEY_NAMES)} are set and "
        f"no {DEFAULT_ENV_FILENAME} was found"
        + (f" (checked {env_file})" if env_file else "")
        + f". Harbor would resume without an API key and the trial would fail. Pass "
        f"--env-file <path> or run from the directory containing {DEFAULT_ENV_FILENAME}."
    )


def environment_from_file(path: Path | None) -> dict[str, str]:
    environment = os.environ.copy()
    if path is None:
        return environment

    for line_number, raw_line in enumerate(path.read_text().splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise RerunError(f"Invalid environment entry at {path}:{line_number}")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            raise RerunError(f"Empty environment key at {path}:{line_number}")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        environment[key] = os.path.expandvars(value)
    return environment


def validate_job(job_path: Path) -> None:
    if not job_path.is_dir():
        raise RerunError(f"Job directory does not exist: {job_path}")
    for filename in ("config.json", "result.json"):
        if not (job_path / filename).is_file():
            raise RerunError(f"Not a Harbor job directory: missing {job_path / filename}")


def model_names(trial_path: Path, result: dict[str, Any]) -> list[str]:
    names: list[str] = []
    config = load_json(trial_path / "config.json")
    agent = config.get("agent")
    if isinstance(agent, dict) and isinstance(agent.get("model_name"), str):
        names.append(agent["model_name"])

    agent_info = result.get("agent_info")
    if isinstance(agent_info, dict):
        model_info = agent_info.get("model_info")
        if isinstance(model_info, dict) and isinstance(model_info.get("name"), str):
            reported_name = model_info["name"]
            names.append(reported_name)
            provider = model_info.get("provider")
            if isinstance(provider, str):
                names.append(f"{provider}/{reported_name}")

    return list(dict.fromkeys(names))


def resolve_trial(job_path: Path, selector: str) -> tuple[Path, dict[str, Any]]:
    validate_job(job_path)
    trials: list[tuple[Path, dict[str, Any], list[str]]] = []
    for name in sorted(trial_directories(job_path)):
        path = job_path / name
        result = load_json(path / "result.json")
        trials.append((path, result, model_names(path, result)))

    direct = [trial for trial in trials if trial[0].name == selector]
    if direct:
        return direct[0][0], direct[0][1]

    selector_key = selector.casefold()
    selector_short = selector_key.rsplit("/", 1)[-1]
    exact = [
        trial
        for trial in trials
        if any(name.casefold() == selector_key for name in trial[2])
    ]
    matches = exact or [
        trial
        for trial in trials
        if any(
            name.rsplit("/", 1)[-1].casefold() == selector_short
            for name in trial[2]
        )
    ]
    if len(matches) == 1:
        return matches[0][0], matches[0][1]

    available = ", ".join(
        f"{names[0] if names else '<unknown model>'} ({path.name})"
        for path, _, names in trials
    ) or "none"
    if not matches:
        raise RerunError(
            f"No completed trial matches model or trial name {selector!r}. "
            f"Available: {available}"
        )
    names = ", ".join(path.name for path, _, _ in matches)
    raise RerunError(
        f"Model {selector!r} has multiple trials: {names}. Use a trial directory name."
    )


def archive_destination(
    archive_root: Path, job_name: str, trial_name: str, timestamp: datetime
) -> Path:
    stamp = timestamp.strftime("%Y%m%dT%H%M%S.%fZ")
    return archive_root / job_name / f"{stamp}__{trial_name}"


def write_rejection_record(
    archive_path: Path,
    source_job: Path,
    source_trial: Path,
    reason: str,
    result: dict[str, Any],
    timestamp: datetime,
    env_file: Path | None,
) -> None:
    record = {
        "archived_at": timestamp.isoformat(),
        "reason": reason,
        "source_job": str(source_job),
        "source_trial": str(source_trial),
        "env_file": str(env_file) if env_file else None,
        "trial_id": result.get("id"),
        "trial_name": result.get("trial_name", source_trial.name),
    }
    (archive_path / "rejection.json").write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Archive a completed Harbor trial, then resume its job so Harbor "
            "backfills the missing model/task slot."
        ),
        epilog="""examples:
  rerun_trial.py jobs/my-job gemini/endymion --reason "Incomplete output"
  rerun_trial.py jobs/my-job aenea --reason "Retry" --dry-run
  rerun_trial.py jobs/my-job gyges --reason "Retry" --env-file worker.env

The selector may be a provider-prefixed alias, a short alias, or an exact trial
directory name; use the aliases shown in your task data. proxy.env is loaded from the
current directory or from beside the jobs/ directory unless --env-file names another
file, and the resume is refused when no proxy credentials can be found. The rejected
trial is preserved under rejected/<job-name>/ before Harbor resumes the job.
""",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("job_path", type=Path, help="Harbor job directory")
    parser.add_argument(
        "model_or_trial",
        help="Model name to rerun, or an exact trial directory name",
    )
    parser.add_argument("--reason", required=True, help="Why this trial was rejected")
    parser.add_argument(
        "--archive-root",
        type=Path,
        help="Archive root (default: rejected/ beside the jobs/ directory)",
    )
    parser.add_argument(
        "--env-file",
        type=Path,
        help="Environment file to load (default: proxy.env beside the job or in the current directory)",
    )
    parser.add_argument(
        "--harbor-command", default="harbor", help="Harbor executable (default: harbor)"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Validate and print actions only"
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    job_path = args.job_path.expanduser().resolve()

    try:
        trial_path, result = resolve_trial(job_path, args.model_or_trial)
        env_file = resolve_env_file(args.env_file, job_path)
        resume_environment = environment_from_file(env_file)
        require_proxy_credentials(resume_environment, env_file)
    except (OSError, RerunError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    archive_root = (
        args.archive_root.expanduser().resolve()
        if args.archive_root
        else default_archive_root(job_path)
    )
    timestamp = datetime.now(timezone.utc)
    archive_path = archive_destination(
        archive_root, job_path.name, trial_path.name, timestamp
    )
    command = [
        args.harbor_command,
        "job",
        "resume",
        "--job-path",
        str(job_path),
        "--yes",
    ]

    print(f"Archive: {trial_path} -> {archive_path}")
    print(f"Environment: {env_file if env_file else 'inherited shell environment'}")
    print(f"Resume:  {' '.join(command)}")
    if args.dry_run:
        return 0

    if shutil.which(args.harbor_command) is None:
        print(f"error: {args.harbor_command!r} was not found", file=sys.stderr)
        return 2
    if archive_path.exists():
        print(f"error: archive destination already exists: {archive_path}", file=sys.stderr)
        return 2

    surviving_trials = trial_directories(job_path) - {trial_path.name}
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(trial_path), str(archive_path))
    try:
        write_rejection_record(
            archive_path,
            job_path,
            trial_path,
            args.reason,
            result,
            timestamp,
            env_file,
        )
    except OSError as exc:
        shutil.move(str(archive_path), str(trial_path))
        print(f"error: could not write rejection record: {exc}", file=sys.stderr)
        return 1

    try:
        subprocess.run(command, check=True, env=resume_environment)
    except FileNotFoundError:
        print(
            f"error: {args.harbor_command!r} disappeared after validation. The trial is "
            f"safely archived at {archive_path}; run:\n{' '.join(command)}",
            file=sys.stderr,
        )
        return 1
    except subprocess.CalledProcessError as exc:
        print(
            f"error: Harbor resume exited with status {exc.returncode}. The trial is "
            f"safely archived at {archive_path}; inspect the job before retrying.",
            file=sys.stderr,
        )
        return exc.returncode or 1

    replacements = sorted(trial_directories(job_path) - surviving_trials)
    if len(replacements) != 1:
        print(
            f"error: expected one replacement trial, found {len(replacements)}: "
            f"{', '.join(replacements) or 'none'}",
            file=sys.stderr,
        )
        return 1

    print(f"Archived rejected trial: {archive_path}")
    print(f"Replacement trial: {job_path / replacements[0]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
