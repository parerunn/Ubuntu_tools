"""Offline tests: temp files and mocked system commands only; no installs/sudo/network."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "ubuntu-init.sh"
spec = importlib.util.spec_from_file_location("configure", ROOT / "configure.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_block_preserves_user_content_and_is_idempotent(self):
        path = self.root / ".bashrc"
        original = "# user\nexport CUSTOM=1\n"
        path.write_text(original)
        path.chmod(0o640)
        config.edit_block(path, "env", "export EXAMPLE=1\n")
        first = path.read_text()
        self.assertTrue(first.startswith(original))
        self.assertEqual(len(list(self.root.glob("*.bak"))), 1)
        config.edit_block(path, "env", "export EXAMPLE=1\n")
        self.assertEqual(path.read_text(), first)
        self.assertEqual(len(list(self.root.glob("*.bak"))), 1)
        self.assertEqual(path.stat().st_mode & 0o777, 0o640)
        config.edit_block(path, "env", "")
        self.assertEqual(path.read_text(), original)

    def test_reject_broken_block_without_touching_file(self):
        path = self.root / "bad"
        original = "# >>> ubuntu-init:env >>>\nkeep me\n"
        path.write_text(original)
        with self.assertRaises(ValueError):
            config.edit_block(path, "env", "replacement")
        self.assertEqual(path.read_text(), original)

    def test_reject_symlink_without_touching_target(self):
        target = self.root / "target"
        target.write_text("keep")
        path = self.root / "link"
        path.symlink_to(target)
        with self.assertRaises(ValueError):
            config.edit_block(path, "env", "replacement")
        self.assertEqual(target.read_text(), "keep")

    def test_docker_merge_keeps_other_options_and_none_removes_only_mirrors(self):
        source, destination = self.root / "old.json", self.root / "new.json"
        original = {"data-root": "/srv/docker", "log-driver": "json-file", "features": {"containerd-snapshotter": True}}
        source.write_text(json.dumps(original))
        config.docker_merge(source, destination, ["https://mirror.example", "https://mirror.example/"])
        result = json.loads(destination.read_text())
        self.assertEqual(result.pop("registry-mirrors"), ["https://mirror.example"])
        self.assertEqual(result, original)
        config.docker_merge(destination, source, ["none"])
        self.assertEqual(json.loads(source.read_text()), original)

    def test_invalid_docker_config_does_not_create_output(self):
        source, output = self.root / "old", self.root / "new"
        for invalid in ("[]", "{not json}"):
            source.write_text(invalid)
            with self.assertRaises(ValueError):
                config.docker_merge(source, output, ["https://mirror.example"])
            self.assertFalse(output.exists())

    def test_reject_insecure_and_credential_urls(self):
        for url in ("http://mirror.example", "https://user:secret@mirror.example", "https://mirror.example/\n", "https://mirror.example:bad", "https:///simple", "https://mirror.example?q=secret"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                config.https_url(url)

    def make_omz(self):
        directory = self.root / "oh-my-zsh"
        (directory / "themes").mkdir(parents=True)
        (directory / "themes/robbyrussell.zsh-theme").touch()
        (directory / "plugins/git").mkdir(parents=True)
        return directory

    def test_omz_replaces_one_loader_preserves_other_settings(self):
        directory = self.make_omz()
        path = self.root / ".zshrc"
        path.write_text('export CUSTOM=1\nplugins=(\n  old-plugin\n)\nsource "$ZSH/oh-my-zsh.sh"\nalias ll="ls -l"\n')
        config.configure_omz(path, directory, "robbyrussell", ["git"])
        result = path.read_text()
        self.assertEqual(result.count('source "$ZSH/oh-my-zsh.sh"'), 1)
        self.assertIn('alias ll="ls -l"', result)
        self.assertIn("plugins=(git)", result)
        config.configure_omz(path, directory, "robbyrussell", ["git"])
        self.assertEqual(path.read_text(), result)
        config.edit_block(path, "omz", "")
        self.assertNotIn("oh-my-zsh.sh", path.read_text())

    def test_omz_rejects_unknown_plugins_before_modification(self):
        directory = self.make_omz()
        path = self.root / ".zshrc"
        path.write_text("# user config\n")
        with self.assertRaises(ValueError):
            config.configure_omz(path, directory, "robbyrussell", ["not-a-builtin"])
        self.assertEqual(path.read_text(), "# user config\n")

    def test_shell_mirror_values_are_quoted_and_repeatable(self):
        path = self.root / "env.sh"
        url = "https://mirror.example/simple;echo-pwned"
        args = ["python3", "-B", str(ROOT / "configure.py"), "env", str(path), "UV_DEFAULT_INDEX", url]
        subprocess.run(args, check=True, capture_output=True)
        text = path.read_text()
        result = subprocess.run(["bash", "-c", '. "$1"; printf "%s" "$UV_DEFAULT_INDEX"', "test", str(path)], capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, url)
        subprocess.run(args, check=True, capture_output=True)
        self.assertEqual(path.read_text(), text)


class ShellTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.guard = self.root / "guard"
        self.guard.mkdir()
        # Every mutating/system endpoint fails closed if a mock is missed.
        for name in ("sudo", "apt-get", "curl", "wget", "git", "systemctl", "dockerd", "chsh", "docker", "conda", "uv", "uvx"):
            path = self.guard / name
            path.write_text('#!/bin/sh\nprintf "UNEXPECTED %s\\n" "$0" >&2\nexit 99\n')
            path.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.root / "home"), PATH=str(self.guard) + ":" + os.environ["PATH"], PYTHONDONTWRITEBYTECODE="1")
        for key in ("NVM_DIR", "ZSH", "ZDOTDIR", "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS"):
            self.env.pop(key, None)
        Path(self.env["HOME"]).mkdir()

    def shell(self, body, success=True):
        prefix = "source " + shlex.quote(str(SCRIPT)) + "\n"
        # macOS system Bash 3.2 treats empty arrays as unset under nounset;
        # target Ubuntu's Bash >= 4.4 doesn't. Keep error/pipefail checks on.
        result = subprocess.run(["bash", "-c", prefix + "set +u\n" + body], env=self.env, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("UNEXPECTED", result.stderr)
        return result

    def test_dry_run_all_actions_never_call_sudo_network_or_write_home(self):
        for action, components, options in (
            ("install", "docker node python uv miniforge dev zsh omz apt", ""),
            ("update", "docker node python uv miniforge dev zsh omz apt", ""),
            ("remove", "docker node python uv miniforge dev zsh omz apt", ""),
            ("configure", "docker python uv node miniforge omz", "--docker-mirror https://docker.example --pypi-index https://pypi.example/simple --npm-registry official --conda-channel official"),
        ):
            with self.subTest(action=action):
                self.shell('require_ubuntu() { :; }; status_component() { printf "checked:%s\\n" "$1"; }; main ' + action + " " + components + " " + options + " --dry-run")
                self.assertEqual(list(Path(self.env["HOME"]).iterdir()), [])

    def test_check_all_is_read_only(self):
        result = self.shell('require_ubuntu() { :; }; status_component() { printf "checked:%s\\n" "$1"; }; main check')
        self.assertEqual(result.stdout.count("checked:"), 9)
        self.assertEqual(list(Path(self.env["HOME"]).iterdir()), [])

    def test_install_only_missing_packages_and_refresh_once(self):
        result = self.shell('''
installed() { [[ $1 == git ]]; }
run() { printf 'MOCK:'; printf '%s ' "$@"; printf '\\n'; }
apt_action install git cmake
apt_action install htop
''')
        self.assertEqual(result.stdout.count("APT::Update::Error-Mode=any update"), 1)
        self.assertIn("install -y --no-remove cmake", result.stdout)
        self.assertIn("install -y --no-remove htop", result.stdout)
        self.assertNotIn("--no-remove git", result.stdout)

    def test_update_only_existing_packages(self):
        result = self.shell('''
installed() { [[ $1 == git ]]; }
run() { printf 'MOCK:'; printf '%s ' "$@"; printf '\\n'; }
apt_action update git cmake
''')
        self.assertIn("--only-upgrade git", result.stdout)
        self.assertNotIn("--only-upgrade git cmake", result.stdout)

    def test_remove_preserves_system_python(self):
        result = self.shell('ACTION=remove; apt_action() { printf "%s\\n" "$*"; }; dispatch python')
        self.assertEqual(result.stdout.strip(), "remove python3-venv python3-pip python3-dev")

    def test_docker_conflicts_are_not_removed_implicitly(self):
        result = self.shell('ACTION=install; installed() { [[ $1 == containerd ]]; }; docker_action', success=False)
        self.assertIn("--migrate-docker", result.stderr)

    def test_unmanaged_directories_are_not_uninstalled(self):
        directory = Path(self.env["HOME"]) / ".nvm"
        directory.mkdir()
        (directory / "keep").write_text("data")
        result = self.shell('ACTION=remove; node_action', success=False)
        self.assertIn("并非本脚本安装", result.stderr)
        self.assertEqual((directory / "keep").read_text(), "data")

    def test_owned_uninstall_archives_and_retains_environments(self):
        directory = Path(self.env["HOME"]) / "miniforge3"
        (directory / "envs/project").mkdir(parents=True)
        (directory / "envs/project/keep").write_text("data")
        (directory / ".ubuntu-init-managed").write_text("miniforge\n")
        self.shell('ACTION=remove; miniforge_action')
        self.assertFalse(directory.exists())
        backups = list((Path(self.env["HOME"]) / ".local/state/ubuntu-init/removed").glob("miniforge-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "envs/project/keep").read_text(), "data")

    def test_miniforge_rejects_bad_checksum_before_running_installer(self):
        # Mock downloads contain no executable installer and a deliberately bad
        # checksum. The guarded run would reveal an attempt to execute it.
        result = self.shell('''
ACTION=install; MINIFORGE_VERSION=26.0.0-0
WORK_DIR="$HOME/work"; mkdir -p "$WORK_DIR"
have() { return 1; }
uname() { printf x86_64; }
apt_action() { :; }
download() {
    case $2 in *.sha256) printf '%064d  installer\\n' 0 > "$2";; *) printf 'not an installer' > "$2";; esac
}
sha256sum() { return 1; }
miniforge_action
''', success=False)
        self.assertIn("SHA256 校验失败", result.stderr)
        self.assertFalse((Path(self.env["HOME"]) / "miniforge3").exists())

    def test_reject_unsafe_package_arguments(self):
        for packages in ("-y", "htop;reboot", "htop,unknown"):
            with self.subTest(packages=packages):
                result = self.shell("parse_args install apt --packages " + shlex.quote(packages) + "; validate_args", success=False)
                self.assertIn("白名单", result.stderr)

    def test_noninteractive_default_does_nothing(self):
        result = self.shell("main", success=False)
        self.assertIn("非交互环境", result.stderr)
        self.assertEqual(list(Path(self.env["HOME"]).iterdir()), [])

    def test_node_install_uses_maintained_major_not_stale_local_lts_alias(self):
        home = Path(self.env["HOME"])
        (home / ".nvm").mkdir()
        (home / ".nvm/nvm.sh").write_text('''
nvm() {
    printf '%s\\n' "$*" >> "$HOME/nvm-calls"
    case $1 in version) printf 'v42.1.0';; *) return 0;; esac
}
''')
        self.shell('''
ACTION=install; WORK_DIR="$HOME/work"; mkdir -p "$WORK_DIR"
apt_action() { :; }
download() { printf '%s' '{"v10":{"lts":"2001-01-01","end":"2002-01-01"},"v42":{"lts":"2002-01-01","end":"9999-01-01"}}' > "$2"; }
node_action
''')
        self.assertEqual((home / "nvm-calls").read_text().strip(), "version 42")
        self.assertTrue((home / ".config/ubuntu-init/env.sh").is_file())

    def test_node_eol_request_fails_before_installer(self):
        result = self.shell('''
ACTION=install; NODE_VERSION=10; WORK_DIR="$HOME/work"; mkdir -p "$WORK_DIR"
apt_action() { :; }
download() { printf '%s' '{"v10":{"lts":"2001-01-01","end":"2002-01-01"}}' > "$2"; }
node_action
''', success=False)
        self.assertIn("LTS", result.stderr)
        self.assertFalse((Path(self.env["HOME"]) / ".nvm").exists())

    def docker_test_preamble(self):
        return '''
WORK_DIR="$HOME/work"; mkdir -p "$WORK_DIR"
DOCKER_CONFIG="$HOME/docker/daemon.json"; mkdir -p "$HOME/docker"
DOCKER_MIRROR=https://mirror.example
installed() { return 0; }
systemd_running() { return 0; }
sudo() {
    case $1 in
        dockerd) printf 'validate\\n' >> "$HOME/events"; return "${VALIDATE_RESULT:-0}" ;;
        systemctl)
            case $2 in
                is-active) return "${ACTIVE_RESULT:-0}" ;;
                restart) printf 'restart\\n' >> "$HOME/events"; return "${RESTART_RESULT:-0}" ;;
            esac ;;
        *) "$@" ;;
    esac
}
'''

    def test_docker_restart_failure_restores_exact_config(self):
        home = Path(self.env["HOME"])
        (home / "docker").mkdir()
        original = '{ "data-root": "/srv/docker", "log-driver": "local" }\n'
        (home / "docker/daemon.json").write_text(original)
        result = self.shell(self.docker_test_preamble() + 'RESTART_RESULT=1; docker_mirror', success=False)
        self.assertIn("已恢复原配置", result.stderr)
        self.assertEqual((home / "docker/daemon.json").read_text(), original)
        self.assertEqual((home / "events").read_text(), "validate\nrestart\nrestart\n")

    def test_docker_validation_failure_leaves_config_untouched(self):
        home = Path(self.env["HOME"])
        (home / "docker").mkdir()
        original = '{"log-driver":"local"}\n'
        (home / "docker/daemon.json").write_text(original)
        self.shell(self.docker_test_preamble() + 'VALIDATE_RESULT=1; docker_mirror', success=False)
        self.assertEqual((home / "docker/daemon.json").read_text(), original)
        self.assertEqual((home / "events").read_text(), "validate\n")

    def test_docker_mirror_repeat_run_does_not_restart_again(self):
        home = Path(self.env["HOME"])
        self.shell(self.docker_test_preamble() + 'docker_mirror; docker_mirror')
        self.assertEqual((home / "events").read_text(), "validate\nrestart\nvalidate\n")
        self.assertEqual(json.loads((home / "docker/daemon.json").read_text()), {"registry-mirrors": ["https://mirror.example"]})


if __name__ == "__main__":
    unittest.main()
