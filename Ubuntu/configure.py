#!/usr/bin/env python3
"""Small, dependency-free config editor for ubuntu-init.sh (Python >= 3.8)."""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import tempfile
from urllib.parse import urlsplit
import uuid
from datetime import datetime, timezone


def https_url(value):
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username
            or parsed.password or parsed.fragment or parsed.query
            or any(c.isspace() or ord(c) < 32 for c in value)):
        raise ValueError("地址必须是无凭据、查询参数或片段的 HTTPS URL")
    _ = parsed.port  # Reject malformed ports.
    return value.rstrip("/")


def read_text(path):
    if path.is_symlink():
        raise ValueError("拒绝覆盖符号链接，请手动编辑其目标: " + str(path))
    return path.read_text(encoding="utf-8") if path.exists() else ""


def atomic_write(path, content):
    old = read_text(path)
    if old == content:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    if path.exists():
        suffix = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = path.with_name(path.name + ".ubuntu-init." + suffix + "." + uuid.uuid4().hex[:8] + ".bak")
        shutil.copy2(path, backup)
        print("配置备份: " + str(backup))
    fd, temporary = tempfile.mkstemp(prefix=".ubuntu-init-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
            os.fchmod(handle.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def block_text(old, name, content):
    if not re.fullmatch(r"[a-z0-9-]+", name):
        raise ValueError("非法配置块名称")
    start = "# >>> ubuntu-init:" + name + " >>>"
    end = "# <<< ubuntu-init:" + name + " <<<"
    if old.count(start) != old.count(end) or old.count(start) > 1:
        raise ValueError("配置块损坏或重复: " + name)
    block = start + "\n" + content.rstrip("\n") + "\n" + end + "\n" if content else ""
    if start in old:
        pattern = re.compile(r"^" + re.escape(start) + r"\n.*?^" + re.escape(end) + r"(?:\n|$)", re.M | re.S)
        if not pattern.search(old):
            raise ValueError("配置块边界错误: " + name)
        return pattern.sub(lambda _: block, old, count=1)
    if not content:
        return old
    return old + ("\n" if old and not old.endswith("\n") else "") + block


def edit_block(path, name, content):
    atomic_write(path, block_text(read_text(path), name, content))


def configure_omz(path, omz_dir, theme, plugins):
    if not re.fullmatch(r"[a-zA-Z0-9_.-]+", theme):
        raise ValueError("非法主题名")
    if not (omz_dir / "themes" / (theme + ".zsh-theme")).is_file():
        raise ValueError("主题不存在: " + theme)
    for plugin in plugins:
        if not re.fullmatch(r"[a-zA-Z0-9_-]+", plugin) or not (omz_dir / "plugins" / plugin).is_dir():
            raise ValueError("内置插件不存在: " + plugin)
    body = ("export ZSH=" + shlex.quote(str(omz_dir)) + "\n"
            + "ZSH_THEME=" + shlex.quote(theme) + "\n"
            + "plugins=(" + " ".join(plugins) + ")\n"
            + "zstyle ':omz:update' mode reminder\n"
            + '[ ! -f "$ZSH/oh-my-zsh.sh" ] || source "$ZSH/oh-my-zsh.sh"\n')
    old = read_text(path)
    if "# >>> ubuntu-init:omz >>>" in old:
        edit_block(path, "omz", body)
        return
    # Override settings immediately before the existing standard OMZ load.
    # Avoid sourcing OMZ twice and preserve all unrelated user configuration.
    lines = old.splitlines(keepends=True)
    active = [i for i, line in enumerate(lines)
              if "oh-my-zsh.sh" in line and line.strip() and not line.lstrip().startswith("#")]
    if len(active) > 1:
        raise ValueError("发现多个 OMZ 加载语句，请先手动整理 .zshrc")
    new_block = block_text("", "omz", body)
    if active:
        line = lines[active[0]].strip()
        if not re.fullmatch(r'(?:source|\.)\s+[\"\']?\$(?:ZSH|\{ZSH\})/oh-my-zsh\.sh[\"\']?\s*;?', line):
            raise ValueError("OMZ 加载语句包含自定义逻辑，请手动整理后再配置")
        lines[active[0]] = new_block
        atomic_write(path, "".join(lines))
    else:
        atomic_write(path, block_text(old, "omz", body))


def docker_merge(source, destination, mirrors):
    data = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("daemon.json 顶层必须为 JSON 对象")
    if mirrors == ["none"]:
        data.pop("registry-mirrors", None)
    else:
        data["registry-mirrors"] = list(dict.fromkeys(https_url(url) for url in mirrors))
    destination.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["block", "env", "omz", "docker", "url", "conda"])
    parser.add_argument("args", nargs="*")
    opts = parser.parse_args()
    args = opts.args
    if opts.command == "block":
        path, name, content_file = args
        edit_block(Path(path), name, Path(content_file).read_text(encoding="utf-8") if content_file != "-" else "")
    elif opts.command == "env":
        path, key, value = args
        if key not in ("PIP_INDEX_URL", "UV_DEFAULT_INDEX", "NPM_CONFIG_REGISTRY"):
            raise ValueError("不支持的环境变量")
        edit_block(Path(path), key.lower().replace("_", "-"), "export " + key + "=" + shlex.quote(https_url(value)) + "\n" if value != "none" else "")
    elif opts.command == "omz":
        path, directory, theme, *plugins = args
        configure_omz(Path(path), Path(directory), theme, plugins)
    elif opts.command == "docker":
        source, destination, *mirrors = args
        if not mirrors:
            raise ValueError("至少提供一个镜像或 none")
        docker_merge(Path(source), Path(destination), mirrors)
    elif opts.command == "url":
        https_url(args[0])
    elif opts.command == "conda":
        path, channel = args
        # Conda's documented final flag prevents merging the upstream channel
        # back in from another rc file. CLI overrides remain possible.
        atomic_write(Path(path), 'channels: #!final\n  - ' + json.dumps(https_url(channel))
                     + '\nchannel_priority: strict\n')


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit("配置失败: " + str(error))
