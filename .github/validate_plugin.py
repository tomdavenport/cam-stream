#!/usr/bin/env python3
"""Validate the repository as an Omarchy Quattro marketplace plugin.

This check is intentionally static: it never imports QML or executes plugin code.
It mirrors the current Omarchy registry and community marketplace constraints that
can be checked from a local checkout.
"""

from __future__ import annotations

import json
import os
import re
import stat
import struct
import sys
from pathlib import Path
from typing import Iterable, Iterator


EXPECTED_PLUGIN_ID = "io.github.tomdavenport.cam-stream"
EXPECTED_HELPER = Path("bin/cam-stream")
MANIFEST_LIMIT = 1024 * 1024
SECURITY_FILE_LIMIT = 512 * 1024
SECURITY_SNAPSHOT_LIMIT = 8 * 1024 * 1024
SECURITY_FILE_COUNT_LIMIT = 1000
PREVIEW_BYTE_LIMIT = 50 * 1024 * 1024
PREVIEW_PIXEL_LIMIT = 40_000_000

FIELD_LIMITS = {
    "id": 128,
    "name": 120,
    "version": 64,
    "author": 120,
    "description": 500,
    "license": 120,
}
KIND_ENTRY_POINTS = {
    "bar": "bar",
    "bar-widget": "barWidget",
    "menu": "menu",
    "overlay": "overlay",
    "panel": "panel",
    "service": "service",
}
PREVIEW_PATTERN = re.compile(r"^preview\.(?:png|jpe?g|webp|avif)$", re.IGNORECASE)
LICENSE_PATTERN = re.compile(r"^(?:licen[cs]e|copying)(?:\.[^/]+)?$", re.IGNORECASE)
README_PATTERN = re.compile(r"^readme(?:\.[^/]+)?$", re.IGNORECASE)
CONTROL_PATTERN = re.compile(r"[\x00-\x1f\x7f-\x9f]")

EXCLUDED_SCAN_DIRECTORIES = {
    ".git",
    ".github",
    "coverage",
    "docs",
    "fixtures",
    "node_modules",
    "spec",
    "specs",
    "test",
    "tests",
}
SCANNED_EXTENSIONS = {
    ".bash",
    ".cjs",
    ".desktop",
    ".fish",
    ".js",
    ".lua",
    ".mjs",
    ".pl",
    ".py",
    ".qml",
    ".rb",
    ".service",
    ".sh",
    ".sudoers",
    ".toml",
    ".yaml",
    ".yml",
    ".zsh",
}


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, message: str) -> None:
        self.errors.append(message)

    def warning(self, message: str) -> None:
        self.warnings.append(message)

    def finish(self) -> int:
        for message in self.warnings:
            print(f"WARNING: {message}", file=sys.stderr)
        for message in self.errors:
            print(f"ERROR: {message}", file=sys.stderr)
        if self.errors:
            print(
                f"Validation failed with {len(self.errors)} error(s) "
                f"and {len(self.warnings)} warning(s).",
                file=sys.stderr,
            )
            return 1
        print(f"Validation passed with {len(self.warnings)} warning(s).")
        return 0


def relative(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def regular_root_files(root: Path) -> list[Path]:
    return [
        path
        for path in root.iterdir()
        if path.is_file() and not path.is_symlink()
    ]


def validate_repository_shape(root: Path, report: Report) -> None:
    root_files = regular_root_files(root)
    names = [path.name for path in root_files]
    if not any(README_PATTERN.fullmatch(name) for name in names):
        report.error("a regular README file is required at the repository root")
    if not any(LICENSE_PATTERN.fullmatch(name) for name in names):
        report.error("a regular LICENSE, LICENCE, or COPYING file is required at the repository root")

    manifest_paths: list[Path] = []
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        if directory_path == root:
            directory_names[:] = [name for name in directory_names if name != ".git"]
        for name in file_names:
            path = directory_path / name
            if name.lower() == "manifest.json" and ".git" not in path.relative_to(root).parts:
                manifest_paths.append(path)
        for name in list(directory_names):
            path = directory_path / name
            if path.is_symlink():
                report.error(f"symlinks are not allowed: {relative(root, path)}")
                directory_names.remove(name)
        for name in file_names:
            path = directory_path / name
            if path.is_symlink():
                report.error(f"symlinks are not allowed: {relative(root, path)}")

    expected_manifest = root / "manifest.json"
    if manifest_paths != [expected_manifest]:
        found = ", ".join(sorted(relative(root, path) for path in manifest_paths)) or "none"
        report.error(
            "exactly one manifest.json is required, at the repository root "
            f"(found: {found})"
        )

    helper = root / EXPECTED_HELPER
    if not helper.is_file() or helper.is_symlink():
        report.error(f"required helper {EXPECTED_HELPER.as_posix()} must be a regular file")
    elif not helper.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH):
        report.error(f"required helper {EXPECTED_HELPER.as_posix()} must be executable")


def nonempty_manifest_string(
    manifest: dict[str, object], field: str, report: Report
) -> str | None:
    value = manifest.get(field)
    if not isinstance(value, str) or not value.strip():
        report.error(f'manifest field "{field}" must be a non-empty string')
        return None
    normalized = value.strip()
    if CONTROL_PATTERN.search(normalized):
        report.error(f'manifest field "{field}" contains control characters')
    limit = FIELD_LIMITS[field]
    if len(normalized) > limit:
        report.error(f'manifest field "{field}" must not exceed {limit} characters')
    return normalized


def is_safe_entry_point(value: object) -> bool:
    return (
        isinstance(value, str)
        and bool(value.strip())
        and not value.startswith("/")
        and ".." not in value
        and not re.search(r"[\\:\r\n\x00]", value)
    )


def validate_manifest(root: Path, report: Report) -> dict[str, object] | None:
    path = root / "manifest.json"
    if not path.is_file() or path.is_symlink():
        return None
    if path.stat().st_size > MANIFEST_LIMIT:
        report.error(f"manifest.json exceeds the {MANIFEST_LIMIT}-byte limit")
        return None
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        report.error(f"manifest.json is not valid UTF-8 JSON: {error}")
        return None
    if not isinstance(manifest, dict):
        report.error("manifest.json must contain a JSON object")
        return None

    if type(manifest.get("schemaVersion")) is not int or manifest["schemaVersion"] != 1:
        report.error('manifest field "schemaVersion" must be the numeric integer 1')

    normalized: dict[str, str | None] = {}
    for field in ("id", "name", "version", "author", "description"):
        normalized[field] = nonempty_manifest_string(manifest, field, report)
    if "license" in manifest:
        normalized["license"] = nonempty_manifest_string(manifest, "license", report)

    plugin_id = normalized.get("id")
    if plugin_id is not None:
        if manifest.get("id") != plugin_id:
            report.error('manifest field "id" must not contain leading or trailing whitespace')
        if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", plugin_id) or ".." in plugin_id:
            report.error("manifest id contains unsupported characters")
        if plugin_id != plugin_id.lower():
            report.error("community manifest ids must use lowercase characters")
        if plugin_id.lower().startswith("omarchy."):
            report.error("the omarchy.* plugin id namespace is reserved")
        elif plugin_id != EXPECTED_PLUGIN_ID:
            report.error(f'manifest id must remain "{EXPECTED_PLUGIN_ID}"')

    raw_kinds = manifest.get("kinds")
    kinds: list[str] = []
    if not isinstance(raw_kinds, list) or not raw_kinds:
        report.error('manifest field "kinds" must be a non-empty array')
    else:
        for kind in raw_kinds:
            if not isinstance(kind, str) or kind not in KIND_ENTRY_POINTS:
                report.error(f"manifest kinds contains unsupported value: {kind!r}")
            else:
                kinds.append(kind)
        if len(kinds) != len(set(kinds)):
            report.error("manifest kinds must not contain duplicates")

    entry_points = manifest.get("entryPoints")
    if not isinstance(entry_points, dict):
        report.error('manifest field "entryPoints" must be an object')
        entry_points = {}
    if not entry_points:
        report.error("manifest entryPoints must not be empty")

    for kind in kinds:
        key = KIND_ENTRY_POINTS[kind]
        if key not in entry_points:
            report.error(f'manifest entryPoints.{key} is required for kind "{kind}"')

    for key, value in entry_points.items():
        if not is_safe_entry_point(value):
            report.error(f"manifest entryPoints.{key} must be a safe relative path")
            continue
        entry_point = root / str(value)
        if not entry_point.is_file() or entry_point.is_symlink():
            report.error(
                f"manifest entryPoints.{key} does not name a regular file: {value}"
            )

    bar_widget = manifest.get("barWidget")
    if isinstance(bar_widget, dict) and "defaultSection" in bar_widget:
        if bar_widget["defaultSection"] not in ("left", "center", "right"):
            report.error("manifest barWidget.defaultSection must be left, center, or right")

    return manifest


def png_dimensions(data: bytes) -> tuple[int, int] | None:
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", data[16:24])


def jpeg_dimensions(data: bytes) -> tuple[int, int] | None:
    if len(data) < 4 or data[:2] != b"\xff\xd8":
        return None
    offset = 2
    start_of_frame = {
        0xC0,
        0xC1,
        0xC2,
        0xC3,
        0xC5,
        0xC6,
        0xC7,
        0xC9,
        0xCA,
        0xCB,
        0xCD,
        0xCE,
        0xCF,
    }
    while offset + 3 < len(data):
        if data[offset] != 0xFF:
            offset += 1
            continue
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        if offset >= len(data):
            break
        marker = data[offset]
        offset += 1
        if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
            continue
        if offset + 2 > len(data):
            break
        segment_length = struct.unpack(">H", data[offset : offset + 2])[0]
        if segment_length < 2 or offset + segment_length > len(data):
            break
        if marker in start_of_frame and segment_length >= 7:
            height, width = struct.unpack(">HH", data[offset + 3 : offset + 7])
            return width, height
        offset += segment_length
    return None


def webp_dimensions(data: bytes) -> tuple[int, int] | None:
    if len(data) < 30 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        return None
    chunk = data[12:16]
    if chunk == b"VP8X":
        width = 1 + int.from_bytes(data[24:27], "little")
        height = 1 + int.from_bytes(data[27:30], "little")
        return width, height
    if chunk == b"VP8 " and len(data) >= 30 and data[23:26] == b"\x9d\x01\x2a":
        width = int.from_bytes(data[26:28], "little") & 0x3FFF
        height = int.from_bytes(data[28:30], "little") & 0x3FFF
        return width, height
    if chunk == b"VP8L" and len(data) >= 25 and data[20] == 0x2F:
        packed = int.from_bytes(data[21:25], "little")
        return (packed & 0x3FFF) + 1, ((packed >> 14) & 0x3FFF) + 1
    return None


def validate_preview(root: Path, report: Report) -> None:
    unsupported_previews = [
        path
        for path in root.iterdir()
        if path.is_file()
        and path.name.lower().startswith("preview.")
        and not PREVIEW_PATTERN.fullmatch(path.name)
    ]
    for path in unsupported_previews:
        report.warning(
            f"{path.name}: unsupported marketplace preview format; use PNG, JPEG, WebP, or AVIF"
        )
    previews = [
        path
        for path in root.iterdir()
        if PREVIEW_PATTERN.fullmatch(path.name)
    ]
    if len(previews) > 1:
        report.error("at most one supported preview image is allowed at the repository root")
    for path in previews:
        if not path.is_file() or path.is_symlink():
            report.error(f"preview must be a regular file: {path.name}")
            continue
        size = path.stat().st_size
        if size < 1 or size > PREVIEW_BYTE_LIMIT:
            report.error(
                f"{path.name} must be non-empty and no larger than {PREVIEW_BYTE_LIMIT} bytes"
            )
            continue
        try:
            data = path.read_bytes()
        except OSError as error:
            report.error(f"could not read {path.name}: {error}")
            continue
        extension = path.suffix.lower()
        dimensions = (
            png_dimensions(data)
            if extension == ".png"
            else jpeg_dimensions(data)
            if extension in (".jpg", ".jpeg")
            else webp_dimensions(data)
            if extension == ".webp"
            else None
        )
        if extension != ".avif" and dimensions is None:
            report.error(f"{path.name} is not a valid supported image")
        elif dimensions is not None:
            width, height = dimensions
            if width < 1 or height < 1 or width * height > PREVIEW_PIXEL_LIMIT:
                report.error(
                    f"{path.name} must not exceed {PREVIEW_PIXEL_LIMIT} decoded pixels"
                )
        else:
            report.warning(
                f"{path.name}: AVIF dimensions require marketplace-side decoding; byte limit passed"
            )


def is_security_scan_path(root: Path, path: Path) -> bool:
    parts = path.relative_to(root).parts
    if any(part.lower() in EXCLUDED_SCAN_DIRECTORIES for part in parts[:-1]):
        return False
    name = path.name.lower()
    if len(parts) == 1 and README_PATTERN.fullmatch(path.name):
        return True
    if path.suffix.lower() in SCANNED_EXTENSIONS:
        return True
    if parts[0].lower() in ("bin", "scripts") and "." not in name:
        return True
    try:
        return path.is_file() and bool(path.stat().st_mode & 0o111)
    except OSError:
        return False


def security_paths(root: Path, manifest: dict[str, object] | None) -> list[Path]:
    paths: set[Path] = set()
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        directory_names[:] = [
            name
            for name in directory_names
            if name.lower() not in EXCLUDED_SCAN_DIRECTORIES
            and not (directory_path / name).is_symlink()
        ]
        for name in file_names:
            path = directory_path / name
            if not path.is_symlink() and is_security_scan_path(root, path):
                paths.add(path)
    if manifest and isinstance(manifest.get("entryPoints"), dict):
        for value in manifest["entryPoints"].values():
            if is_safe_entry_point(value):
                path = root / str(value)
                if path.is_file() and not path.is_symlink():
                    paths.add(path)
    return sorted(paths)


def shell_fence_lines(text: str) -> Iterator[tuple[int, str]]:
    in_fence = False
    shell_fence = False
    for line_number, line in enumerate(text.splitlines(), start=1):
        match = re.match(r"^\s*```\s*([^\s`]*)", line)
        if match:
            if not in_fence:
                language = match.group(1).lower()
                in_fence = True
                shell_fence = language in ("", "bash", "console", "fish", "sh", "shell", "zsh")
            else:
                in_fence = False
                shell_fence = False
            continue
        if in_fence and shell_fence:
            yield line_number, line


def runtime_lines(root: Path, path: Path, text: str) -> list[tuple[int, str]]:
    if README_PATTERN.fullmatch(path.name) and path.parent == root:
        return list(shell_fence_lines(text))
    values: list[tuple[int, str]] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", "//", "/*", "*", "<!--")):
            continue
        values.append((line_number, stripped))
    return values


def first_match(pattern: re.Pattern[str], lines: Iterable[tuple[int, str]]) -> tuple[int, str] | None:
    for line_number, line in lines:
        if pattern.search(line):
            return line_number, line
    return None


def has_full_revision(line: str) -> bool:
    return bool(re.search(r"(?:--rev(?:=|\s+)|checkout\s+--detach\s+)[a-fA-F0-9]{40}\b", line))


def unpinned_git_execution(lines: list[tuple[int, str]]) -> tuple[int, str] | None:
    clone_pattern = re.compile(r"\bgit\s+clone\b.*(?:https?|git|ssh)://|\bgit\s+clone\b.*git@", re.I)
    execution_pattern = re.compile(
        r"(?:^|[;&|]\s*)(?:\./|bash\s+|sh\s+|python\d*\s+|node\s+|"
        r"make(?:\s|$)|cmake(?:\s|$)|ninja(?:\s|$)|cargo\s+(?:build|run)|"
        r"go\s+run|npm\s+(?:ci|install|run)|pnpm\s+(?:install|run)|yarn\s+(?:install|run))",
        re.I,
    )
    for index, (line_number, line) in enumerate(lines):
        if not clone_pattern.search(line):
            continue
        following = lines[index + 1 : index + 31]
        pinned = any(has_full_revision(candidate) for _, candidate in following)
        executes = any(execution_pattern.search(candidate) for _, candidate in following)
        if executes and not pinned:
            return line_number, line
    return None


def downloaded_file_execution(lines: list[tuple[int, str]]) -> tuple[int, str] | None:
    download_pattern = re.compile(
        r"\b(?:curl|wget)\b[^\n]*(?:"
        r"(?:^|\s)(?:-o|--output(?:-document)?)(?:\s+|=)([^\s;&|]+)"
        r"|(?:^|\s)-[A-Za-z]*o([^\s;&|]+)"
        r"|>\s*([^\s;&|]+))",
        re.I,
    )
    execution_pattern = re.compile(
        r"(?:^|[;&|]\s*)(?:bash|sh|zsh|dash|ash|ksh|fish|source|\.|"
        r"python\d*|node|ruby|perl)\s+",
        re.I,
    )
    for index, (line_number, line) in enumerate(lines):
        match = download_pattern.search(line)
        if not match:
            continue
        target = next((value for value in match.groups() if value), "").strip("\"'")
        if not target:
            continue
        for _, candidate in lines[index + 1 :]:
            if target in candidate and execution_pattern.search(candidate):
                return line_number, line
    return None


def validate_security(root: Path, manifest: dict[str, object] | None, report: Report) -> None:
    paths = security_paths(root, manifest)
    if len(paths) > SECURITY_FILE_COUNT_LIMIT:
        report.error(
            f"security scan has more than {SECURITY_FILE_COUNT_LIMIT} relevant files"
        )
        return
    total_size = sum(path.stat().st_size for path in paths)
    if total_size > SECURITY_SNAPSHOT_LIMIT:
        report.error(
            f"security scan input exceeds {SECURITY_SNAPSHOT_LIMIT} bytes"
        )
        return

    pipe_pattern = re.compile(
        r"\b(?:curl|wget)\b[^\n]*(?:\||\|&)\s*(?:/[^\s;&|]*/)?(?:ba|z|fi|da|a|k)?sh\b",
        re.I,
    )
    process_substitution_pattern = re.compile(
        r"(?:bash|sh|zsh|dash|ash|ksh|fish|source|\.)\s+(?:<\s*)?<\(\s*(?:curl|wget)\b",
        re.I,
    )
    command_substitution_pattern = re.compile(
        r"(?:eval\s+|(?:bash|sh|zsh|dash|ash|ksh|fish)\s+-c\s+)[\"']?\$\(\s*(?:curl|wget)\b",
        re.I,
    )
    cargo_git_pattern = re.compile(r"\bcargo\s+install\b[^\n]*\s--git(?:\s|=)", re.I)
    privilege_pattern = re.compile(r"\b(?:sudo|pkexec)\b", re.I)
    privilege_negative_pattern = re.compile(
        r"\b(?:no|without|never|does\s+not|doesn't)\b[^.!?\n]*\b(?:sudo|pkexec)\b",
        re.I,
    )
    package_pattern = re.compile(
        r"\b(?:pacman|paru|yay|apt|apt-get|dnf|zypper|apk)\s+(?:-[A-Za-z]*[SRU]|install|remove|upgrade|add|del)\b|"
        r"\bomarchy\s+pkg\s+(?:add|drop|remove|update)\b|"
        r"\b(?:npm|pnpm|yarn|bun|pipx?|cargo|gem|brew)\s+(?:install|add|remove|upgrade)\b",
        re.I,
    )
    service_pattern = re.compile(r"\b(?:systemctl|systemd-run)\b", re.I)
    shared_pid_pattern = re.compile(r"/tmp/[^\s\"']*\.pid\b", re.I)
    pid_read_pattern = re.compile(r"(?:cat\s+|<\s*)[^\n]*/tmp/[^\s\"']*\.pid|\$\(\s*cat\b", re.I)
    privileged_kill_pattern = re.compile(r"\b(?:sudo|pkexec)\b[^\n]*\b(?:kill|pkill)\b", re.I)
    passwordless_pattern = re.compile(r"\bNOPASSWD\s*:", re.I)
    dangerous_policy_pattern = re.compile(
        r"\bNOPASSWD\s*:\s*(?:ALL\b|[^\n]*(?:\*|/(?:ba|z|fi|da|a|k)?sh\b|/systemctl\b|/kill\b))",
        re.I,
    )

    for path in paths:
        label = relative(root, path)
        size = path.stat().st_size
        if size > SECURITY_FILE_LIMIT:
            report.error(f"{label} exceeds the static scan per-file limit")
            continue
        data = path.read_bytes()
        if b"\x00" in data:
            if path.stat().st_mode & 0o111:
                report.warning(f"{label}: bundled executable binary requires marketplace review")
            else:
                report.error(f"{label} is not a supported text file for static scanning")
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            report.error(f"{label} is not valid UTF-8 text")
            continue
        lines = runtime_lines(root, path, text)
        if not lines:
            continue

        for rule_name, pattern in (
            ("downloaded content is piped directly to a shell", pipe_pattern),
            ("downloaded content is executed through process substitution", process_substitution_pattern),
            ("downloaded content is executed through command substitution", command_substitution_pattern),
        ):
            match = first_match(pattern, lines)
            if match:
                report.error(f"{label}:{match[0]}: {rule_name}")

        downloaded_match = downloaded_file_execution(lines)
        if downloaded_match:
            report.error(
                f"{label}:{downloaded_match[0]}: downloaded content is executed without verification"
            )

        cargo_match = first_match(cargo_git_pattern, lines)
        if cargo_match and not has_full_revision(cargo_match[1]):
            report.error(
                f"{label}:{cargo_match[0]}: cargo installs an unpinned external Git source"
            )
        git_match = unpinned_git_execution(lines)
        if git_match:
            report.error(
                f"{label}:{git_match[0]}: external Git source is executed without a full detached commit pin"
            )

        joined = "\n".join(line for _, line in lines)
        if (
            shared_pid_pattern.search(joined)
            and pid_read_pattern.search(joined)
            and privileged_kill_pattern.search(joined)
        ):
            report.error(
                f"{label}: privileged process control must not trust a predictable shared /tmp PID file"
            )

        if passwordless_pattern.search(joined) and dangerous_policy_pattern.search(joined):
            report.error(f"{label}: dangerous passwordless privilege policy detected")

        privilege_match = first_match(privilege_pattern, lines)
        if privilege_match and not privilege_negative_pattern.search(privilege_match[1]):
            report.warning(
                f"{label}:{privilege_match[0]}: privilege boundary requires marketplace review"
            )
        package_match = first_match(package_pattern, lines)
        if package_match:
            report.warning(
                f"{label}:{package_match[0]}: package management requires marketplace review"
            )
        service_match = first_match(service_pattern, lines)
        if service_match or path.suffix.lower() == ".service":
            line_number = service_match[0] if service_match else 1
            report.warning(
                f"{label}:{line_number}: service management requires marketplace review"
            )


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"Usage: {Path(argv[0]).name} REPOSITORY_ROOT", file=sys.stderr)
        return 2
    root = Path(argv[1]).expanduser().resolve()
    if not root.is_dir():
        print(f"ERROR: repository root is not a directory: {root}", file=sys.stderr)
        return 2

    report = Report()
    validate_repository_shape(root, report)
    manifest = validate_manifest(root, report)
    validate_preview(root, report)
    validate_security(root, manifest, report)
    return report.finish()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
