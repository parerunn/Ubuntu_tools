#!/usr/bin/env bash
# Run as a normal Ubuntu user. Only system operations use sudo.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_HELPER="$SCRIPT_DIR/configure.py"
ACTION=''
COMPONENTS=()
DRY_RUN=0
ASSUME_YES=0
SET_DEFAULT_SHELL=0
MIGRATE_DOCKER=0
NVM_VERSION=latest
NODE_VERSION=lts
UV_VERSION=''
MINIFORGE_VERSION=latest
DOCKER_MIRROR=''
PYPI_INDEX=''
CONDA_CHANNEL=''
NPM_REGISTRY=''
OMZ_THEME=robbyrussell
OMZ_PLUGINS=git,sudo,docker,python,pip
APT_PACKAGES=(htop)
DEV_PACKAGES=(build-essential git gcc g++ make cmake pkg-config ninja-build gdb)
PYTHON_PACKAGES=(python3 python3-venv python3-pip python3-dev)
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
DOCKER_CONFLICTS=(docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc)
NVM_HOME="$HOME/.nvm"
FORGE_HOME="$HOME/miniforge3"
OMZ_HOME="$HOME/.oh-my-zsh"
USER_BIN="$HOME/.local/bin"
ENV_FILE="$HOME/.config/ubuntu-init/env.sh"
STATE_DIR="$HOME/.local/state/ubuntu-init"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
APT_REFRESHED=0
WORK_DIR=''
DOCKER_CONFIG=/etc/docker/daemon.json

log() { printf '\n[ubuntu-init] %s\n' "$*"; }
die() { printf '\n错误: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
contains() { local wanted=$1 item; shift; for item in "$@"; do [[ $item != "$wanted" ]] || return 0; done; return 1; }
installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == 'install ok installed' ]]; }
systemd_running() { [[ -d /run/systemd/system ]]; }
run() { printf '+ '; printf '%q ' "$@"; printf '\n'; "$@"; }
cleanup() { [[ -z $WORK_DIR ]] || rm -rf -- "$WORK_DIR"; }

usage() {
    cat <<'EOF'
Ubuntu 按需初始化（请用普通用户运行，不要 sudo bash）

用法: bash Ubuntu/ubuntu-init.sh [动作] [组件 ...] [选项]
动作: install | update | remove | check | configure
无参数: 显示菜单；不预选任何组件。check 不写文件、不联网、不使用 sudo。
组件: docker node python uv miniforge dev zsh omz apt
  node: nvm + Node LTS；python: Ubuntu 系统 Python + venv/pip/dev
  dev: git/gcc/g++/make/cmake/pkg-config/ninja/gdb/build-essential
  omz 会在安装时带上 zsh；apt 默认仅 htop，可用 --packages 指定

选项:
  --dry-run                  只显示状态和计划，不下载、不写文件、不 sudo
  --yes                      同意所选操作（仍保留 APT 自身的卸载确认）
  --packages htop,tree,tmux   apt 组件的软件白名单，见 README
  --node-version lts|22|24   默认 lts；数字必须仍在官方 LTS 支持期
  --nvm-version vX.Y.Z       固定 nvm 官方标签，默认最新稳定版
  --uv-version X.Y.Z         固定 uv 版本；省略使用官方最新稳定版
  --miniforge-version TAG    固定官方发行标签；默认 latest
  --migrate-docker           允许移除已检测的 Docker 冲突包（APT 会确认）
  --set-default-shell        显式将登录 shell 设为 zsh
  --docker-mirror URL[,URL]  configure docker；none 清除 registry-mirrors
  --pypi-index URL|official  configure python/uv；pip、uv 共用 PyPI 镜像
  --conda-channel URL|official  configure miniforge；提供完整 conda-forge 频道 URL
  --npm-registry URL|official   configure node；npm registry
  --omz-theme NAME           configure omz；默认 robbyrussell
  --omz-plugins git,sudo     configure omz；仅官方内置插件
  -h, --help                 显示帮助

示例:
  bash Ubuntu/ubuntu-init.sh check
  bash Ubuntu/ubuntu-init.sh install docker node uv --dry-run
  bash Ubuntu/ubuntu-init.sh install dev apt --packages htop,tmux
  bash Ubuntu/ubuntu-init.sh configure python uv --pypi-index https://your-mirror.example/simple
EOF
}

need_value() { [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "$1 缺少参数"; }
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            install|update|remove|check|configure)
                [[ -z $ACTION ]] || die '只能指定一个动作'; ACTION=$1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --yes) ASSUME_YES=1; shift ;;
            --set-default-shell) SET_DEFAULT_SHELL=1; shift ;;
            --migrate-docker) MIGRATE_DOCKER=1; shift ;;
            --packages) need_value "$@"; IFS=',' read -r -a APT_PACKAGES <<< "$2"; shift 2 ;;
            --node-version) need_value "$@"; NODE_VERSION=$2; shift 2 ;;
            --nvm-version) need_value "$@"; NVM_VERSION=$2; shift 2 ;;
            --uv-version) need_value "$@"; UV_VERSION=$2; shift 2 ;;
            --miniforge-version) need_value "$@"; MINIFORGE_VERSION=$2; shift 2 ;;
            --docker-mirror) need_value "$@"; DOCKER_MIRROR=$2; shift 2 ;;
            --pypi-index) need_value "$@"; PYPI_INDEX=$2; shift 2 ;;
            --conda-channel) need_value "$@"; CONDA_CHANNEL=$2; shift 2 ;;
            --npm-registry) need_value "$@"; NPM_REGISTRY=$2; shift 2 ;;
            --omz-theme) need_value "$@"; OMZ_THEME=$2; shift 2 ;;
            --omz-plugins) need_value "$@"; OMZ_PLUGINS=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            --*) die "未知选项: $1" ;;
            *) COMPONENTS+=("$1"); shift ;;
        esac
    done
}

menu() {
    [[ -t 0 ]] || die '非交互环境必须显式指定动作和组件，使用 --help 查看用法'
    local choice selected item
    printf '\n1) 安装  2) 更新  3) 卸载  4) 检查  5) 配置  0) 退出\n'
    read -r -p '选择动作（直接回车退出）: ' choice || exit 0
    case $choice in
        1) ACTION=install ;; 2) ACTION=update ;; 3) ACTION=remove ;;
        4) ACTION=check ;; 5) ACTION=configure ;; ''|0) exit 0 ;; *) die '无效选择' ;;
    esac
    printf '组件: docker node python uv miniforge dev zsh omz apt\n'
    read -r -p '输入组件名称，以空格分隔（不选择则退出；检查可回车看全部）: ' selected || exit 0
    read -r -a COMPONENTS <<< "$selected"
    if [[ ${#COMPONENTS[@]} -eq 0 && $ACTION != check ]]; then exit 0; fi
    if contains apt "${COMPONENTS[@]}"; then
        read -r -p 'APT 软件，用逗号分隔（回车仅 htop）: ' selected || exit 0
        [[ -z $selected ]] || IFS=',' read -r -a APT_PACKAGES <<< "$selected"
    fi
    if [[ $ACTION == configure ]]; then
        for item in "${COMPONENTS[@]}"; do
            case $item in
                docker) read -r -p 'Docker HTTPS 镜像（逗号分隔，none 清除）: ' DOCKER_MIRROR ;;
                python|uv) [[ -n $PYPI_INDEX ]] || read -r -p 'PyPI HTTPS simple 地址（official 恢复官方）: ' PYPI_INDEX ;;
                node) read -r -p 'npm HTTPS registry（official 恢复官方）: ' NPM_REGISTRY ;;
                miniforge) read -r -p 'conda-forge 完整 HTTPS 频道地址（official 恢复官方）: ' CONDA_CHANNEL ;;
                zsh) read -r -p '将登录 shell 改为 zsh？[y/N] ' selected; [[ $selected != y && $selected != Y ]] || SET_DEFAULT_SHELL=1 ;;
                omz) read -r -p 'OMZ 主题（回车 robbyrussell）: ' selected; OMZ_THEME=${selected:-robbyrussell} ;;
            esac
        done
    fi
}

validate_args() {
    local component package value
    [[ ${#COMPONENTS[@]} -gt 0 || $ACTION == check ]] || die '请至少选择一个组件'
    for component in ${COMPONENTS[@]+"${COMPONENTS[@]}"}; do
        case $component in docker|node|python|uv|miniforge|dev|zsh|omz|apt) ;; *) die "未知组件: $component" ;; esac
    done
    [[ $NVM_VERSION == latest || $NVM_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'nvm 标签格式应为 vX.Y.Z'
    [[ -z $UV_VERSION || $UV_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'uv 版本格式应为 X.Y.Z'
    [[ $NODE_VERSION == lts || $NODE_VERSION =~ ^[0-9]+$ ]] || die 'Node 版本仅支持 lts 或 LTS 主版本号'
    [[ $MINIFORGE_VERSION =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die '非法 Miniforge 标签'
    [[ $OMZ_THEME =~ ^[a-zA-Z0-9_.-]+$ && $OMZ_PLUGINS =~ ^[a-zA-Z0-9_,.-]+$ ]] || die '非法 OMZ 主题/插件'
    [[ ${#APT_PACKAGES[@]} -gt 0 ]] || die 'APT 软件列表不能为空'
    for package in "${APT_PACKAGES[@]}"; do
        case $package in
            htop|tree|jq|unzip|zip|tmux|ripgrep|fd-find|wget|curl|ca-certificates|net-tools|lsof) ;;
            *) die "不在 APT 可选白名单中: $package" ;;
        esac
    done
    for value in "$DOCKER_MIRROR" "$PYPI_INDEX" "$CONDA_CHANNEL" "$NPM_REGISTRY"; do
        [[ -z $value || $ACTION == configure ]] || die '镜像参数只用于 configure 动作'
    done
    if [[ $ACTION == configure ]]; then
        for component in "${COMPONENTS[@]}"; do
            case $component in
                docker) [[ -n $DOCKER_MIRROR ]] || die '需要 --docker-mirror' ;;
                python|uv) [[ -n $PYPI_INDEX ]] || die '需要 --pypi-index' ;;
                node) [[ -n $NPM_REGISTRY ]] || die '需要 --npm-registry' ;;
                miniforge) [[ -n $CONDA_CHANNEL ]] || die '需要 --conda-channel' ;;
                zsh) [[ $SET_DEFAULT_SHELL -eq 1 ]] || die 'configure zsh 需要 --set-default-shell' ;;
                omz) ;;
                *) die "$component 不支持 configure" ;;
            esac
        done
    fi
    if [[ $SET_DEFAULT_SHELL -eq 1 ]]; then
        [[ $ACTION == install || $ACTION == configure ]] || die '--set-default-shell 只用于 install/configure'
        contains zsh "${COMPONENTS[@]}" || contains omz "${COMPONENTS[@]}" || die '设置默认 shell 需选择 zsh 或 omz'
    fi
}

require_ubuntu() {
    [[ $(uname -s) == Linux && -r /etc/os-release ]] || die '只支持 Ubuntu；本机未执行任何安装'
    local ID='' VERSION_ID='' VERSION_CODENAME='' UBUNTU_CODENAME=''
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ $ID == ubuntu ]] || die '仅支持 Ubuntu，不自动处理衍生发行版'
    case $VERSION_ID in 22.04|24.04|26.04) ;; *) die "支持的 Ubuntu LTS: 22.04 / 24.04 / 26.04；当前 $VERSION_ID" ;; esac
    UBUNTU_SUITE=${UBUNTU_CODENAME:-$VERSION_CODENAME}
    [[ $UBUNTU_SUITE =~ ^[a-z]+$ ]] || die '无法识别 Ubuntu codename'
}

show_command() {
    local label=$1 cmd=$2 version
    shift 2
    if have "$cmd"; then
        version=$("$cmd" "$@" 2>&1 | head -n 1) || true
        printf '  %-14s %s [%s]\n' "$label" "${version:-版本未知}" "$(command -v "$cmd")"
    else
        printf '  %-14s 未在 PATH 中找到\n' "$label"
    fi
}

nvm_exec() (
    # nvm documents incompatibility with errexit/nounset. Isolate its options.
    set +eu
    trap - ERR
    export NVM_DIR="$NVM_HOME"
    # shellcheck disable=SC1091
    . "$NVM_HOME/nvm.sh" --no-use || exit $?
    nvm "$@"
)

status_component() {
    local item=$1 package version
    printf '\n[%s]\n' "$item"
    case $item in
        docker)
            show_command docker docker --version
            if have docker; then docker compose version 2>/dev/null || true; fi
            for package in "${DOCKER_PACKAGES[@]}" "${DOCKER_CONFLICTS[@]}"; do
                if installed "$package"; then dpkg-query -W -f='  ${Package}: ${Version}\n' "$package"; fi
            done
            if have systemctl; then systemctl is-active docker 2>/dev/null || true; fi ;;
        node)
            if [[ -s $NVM_HOME/nvm.sh ]]; then
                version=$(nvm_exec --version); printf '  nvm: %s [%s]\n' "$version" "$NVM_HOME"
                nvm_exec ls --no-colors || true
            else printf '  nvm: 常规目录未安装\n'; fi
            show_command node node --version; show_command npm npm --version ;;
        python) show_command python3 python3 --version; show_command pip3 pip3 --version ;;
        uv) show_command uv uv --version
            if [[ -x $USER_BIN/uv && $(command -v uv || true) != "$USER_BIN/uv" ]]; then "$USER_BIN/uv" --version; fi ;;
        miniforge)
            if [[ -x $FORGE_HOME/bin/conda ]]; then "$FORGE_HOME/bin/conda" --version; else printf '  Miniforge: 常规目录未安装\n'; fi
            show_command conda conda --version ;;
        dev) for package in git gcc g++ make cmake pkg-config ninja gdb; do show_command "$package" "$package" --version; done ;;
        zsh) show_command zsh zsh --version; printf '  登录 shell: %s\n' "$(getent passwd "$(id -un)" | cut -d: -f7)" ;;
        omz)
            if [[ -f $OMZ_HOME/oh-my-zsh.sh ]]; then
                printf '  OMZ: %s (commit %s)\n' "$OMZ_HOME" "$(git -C "$OMZ_HOME" rev-parse --short HEAD 2>/dev/null || printf '未知')"
            else printf '  OMZ: 常规目录未安装\n'; fi ;;
        apt) for package in "${APT_PACKAGES[@]}"; do
            if installed "$package"; then dpkg-query -W -f='  ${Package}: ${Version}\n' "$package"; else printf '  %s: 未安装\n' "$package"; fi
        done ;;
    esac
}

plan() {
    local item
    log "动作: ${ACTION}；组件: ${COMPONENTS[*]}"
    for item in "${COMPONENTS[@]}"; do
        status_component "$item"
        case $item in
            docker) printf '  计划: 官方 Docker APT stable 仓库；安装/更新 Engine、CLI、containerd、Buildx、Compose；不删除容器数据。\n' ;;
            node) printf '  计划: 用户级 nvm %s，Node %s（官方受支持 LTS，二进制）；不迁移全局 npm 包。\n' "$NVM_VERSION" "$NODE_VERSION" ;;
            python) printf '  计划: Ubuntu APT python3/venv/pip/dev；卸载仅移除 venv/pip/dev，保留系统 python3。\n' ;;
            uv) printf '  计划: 官方 uv 独立安装器（%s）；安装至 ~/.local/bin，不自动下载额外 Python。\n' "${UV_VERSION:-最新稳定版}" ;;
            miniforge) printf '  计划: 官方 Miniforge %s 安装器 + SHA256；更新只处理 base 的 conda/mamba；不激活 base。\n' "$MINIFORGE_VERSION" ;;
            dev) printf '  APT 软件: %s\n' "${DEV_PACKAGES[*]}" ;;
            apt) printf '  APT 软件: %s\n' "${APT_PACKAGES[*]}" ;;
            zsh) printf '  计划: Ubuntu APT zsh；是否切换登录 shell: %s。\n' "$SET_DEFAULT_SHELL" ;;
            omz) printf '  计划: 官方 OMZ 安装器，保留 .zshrc 并添加管理块；主题 %s；插件 %s。\n' "$OMZ_THEME" "$OMZ_PLUGINS" ;;
        esac
    done
    if [[ $ACTION == configure ]]; then
        printf '\n镜像配置（未指定的项目不修改）:\nDocker: %s\nPyPI: %s\nconda-forge: %s\nnpm: %s\n' "${DOCKER_MIRROR:-保持}" "${PYPI_INDEX:-保持}" "${CONDA_CHANNEL:-保持}" "${NPM_REGISTRY:-保持}"
        [[ -z $DOCKER_MIRROR ]] || printf 'Docker 配置会验证并重启正在运行的系统 Docker 服务，可能影响容器。\n'
    fi
    if [[ $ACTION == update ]]; then printf '\n更新仅作用于已安装的所选组件；不会全系统 upgrade。Docker 更新可能重启服务。\n'; fi
    if [[ $ACTION == remove ]]; then printf '\nAPT remove 保留配置且不 autoremove；用户级工具仅卸载本脚本安装的副本，目录移至 ~/.local/state/ubuntu-init/removed；不删除环境/容器数据。\n'; fi
    if [[ $ACTION == install ]]; then printf '\n已安装的工具跳过；可能补齐依赖 ca-certificates/curl/git/python3。安装 Docker 会启动系统服务。\n'; fi
}

confirm() {
    local answer
    [[ $ASSUME_YES -eq 0 ]] || return 0
    [[ -t 0 ]] || die '非交互执行需要 --yes（建议先 --dry-run）'
    read -r -p '执行以上操作？[y/N] ' answer
    [[ $answer == y || $answer == Y ]] || exit 0
}

apt_refresh() {
    if [[ $APT_REFRESHED -eq 0 ]]; then run sudo apt-get -o APT::Update::Error-Mode=any update; APT_REFRESHED=1; fi
}

apt_action() {
    local action=$1 package
    shift
    local selected=()
    for package in "$@"; do
        if [[ $action == install ]]; then
            if installed "$package"; then log "$package 已安装，跳过"; else selected+=("$package"); fi
        elif installed "$package"; then selected+=("$package"); fi
    done
    [[ ${#selected[@]} -gt 0 ]] || return 0
    if [[ $action == remove ]]; then
        # Let apt show dependent removals and require its own approval; never autoremove.
        run sudo apt-get --no-auto-remove remove "${selected[@]}"
    else
        apt_refresh
        if [[ $action == update ]]; then
            run sudo apt-get install -y --no-remove --only-upgrade "${selected[@]}"
        else run sudo apt-get install -y --no-remove "${selected[@]}"; fi
    fi
}

download() { run curl --fail --location --show-error --silent --retry 3 --connect-timeout 20 --proto '=https' --proto-redir '=https' "$1" -o "$2"; [[ -s $2 ]] || die "下载文件为空: $1"; }
cfg() { run python3 "$CONFIG_HELPER" "$@"; }
block() { cfg block "$1" "$2" "$3"; }

init_profiles() {
    cat > "$WORK_DIR/profile" <<'EOF'
[ ! -f "$HOME/.config/ubuntu-init/env.sh" ] || . "$HOME/.config/ubuntu-init/env.sh"
EOF
    block "$HOME/.bashrc" env "$WORK_DIR/profile"
    block "$ZSHRC" env "$WORK_DIR/profile"
}

mark_owned() { printf '%s\n' "$1" > "$2/.ubuntu-init-managed"; }
owned() { [[ -f $2/.ubuntu-init-managed && $(cat "$2/.ubuntu-init-managed") == "$1" ]]; }
require_owned() { owned "$1" "$2" || die "$1 并非本脚本安装，拒绝卸载；请使用其原安装方式处理: $2"; }
archive_dir() {
    local kind=$1 directory=$2 destination
    [[ -d $directory ]] || { log "$kind 未安装，跳过"; return; }
    require_owned "$kind" "$directory"
    [[ ! -L $directory && $directory == "$HOME/"* && $directory != "$HOME/" && $directory != *'/../'* ]] || die "拒绝移动不安全目录: $directory"
    destination="$STATE_DIR/removed/$kind-$(date +%Y%m%dT%H%M%S)-$$"
    run mkdir -p "$STATE_DIR/removed"
    run mv -- "$directory" "$destination"
    log "已卸载；完整数据备份: $destination"
}

docker_repository() {
    local architecture file
    architecture=$(dpkg --print-architecture)
    case $architecture in amd64|arm64|armhf|s390x|ppc64el) ;; *) die "Docker 不支持架构: $architecture" ;; esac
    # Refuse to create duplicate repositories or overwrite someone else's configuration.
    while IFS= read -r file; do
        if [[ $file != /etc/apt/sources.list.d/docker.sources ]] && grep -qE '^[^#]*download\.docker\.com/linux/ubuntu' "$file"; then
            die "发现已有 Docker 源 ${file}，请手动合并至官方 docker.sources 后重试"
        fi
    done < <(find /etc/apt -maxdepth 2 -type f \( -name '*.list' -o -name '*.sources' \))
    cat > "$WORK_DIR/docker.sources" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $UBUNTU_SUITE
Components: stable
Architectures: $architecture
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    if [[ -e /etc/apt/sources.list.d/docker.sources ]] && ! cmp -s "$WORK_DIR/docker.sources" /etc/apt/sources.list.d/docker.sources; then
        die '现有 docker.sources 与预期不符，请先手动核对；未覆盖'
    fi
    download https://download.docker.com/linux/ubuntu/gpg "$WORK_DIR/docker.asc"
    run sudo install -m 0755 -d /etc/apt/keyrings
    run sudo install -m 0644 "$WORK_DIR/docker.asc" /etc/apt/keyrings/docker.asc
    run sudo install -m 0644 "$WORK_DIR/docker.sources" /etc/apt/sources.list.d/docker.sources
    APT_REFRESHED=0
}

docker_action() {
    local package conflicts=() new_engine=0
    if [[ $ACTION == remove ]]; then
        apt_action remove "${DOCKER_PACKAGES[@]}" docker-ce-rootless-extras
        log '保留 Docker 数据、daemon.json、仓库与密钥；再次安装可复用'
        return
    fi
    if [[ $ACTION == update ]]; then
        installed docker-ce || { log '未安装官方 docker-ce，跳过更新'; return; }
        [[ -r /etc/apt/sources.list.d/docker.sources || -r /etc/apt/sources.list.d/docker.list ]] || die 'Docker 缺少官方仓库，请先核对源配置'
        apt_action update "${DOCKER_PACKAGES[@]}"; return
    fi
    for package in "${DOCKER_CONFLICTS[@]}"; do installed "$package" && conflicts+=("$package"); done
    if [[ ${#conflicts[@]} -gt 0 ]]; then
        [[ $MIGRATE_DOCKER -eq 1 ]] || die "检测到冲突包 ${conflicts[*]}；核对依赖后用 --migrate-docker 显式迁移"
        log "迁移将移除 ${conflicts[*]}，可能影响现有容器/Kubernetes"
        apt_action remove "${conflicts[@]}"
    fi
    if ! installed docker-ce; then
        new_engine=1
        if have docker; then die '发现其他 Docker 安装方式，未自动覆盖，请先手动处理'; fi
        apt_action install ca-certificates curl
        docker_repository
    fi
    apt_action install "${DOCKER_PACKAGES[@]}"
    if [[ $new_engine -eq 0 ]]; then
        log 'Docker Engine 已安装；仅补齐缺失软件包，保留当前服务状态'
    elif systemd_running; then
        run sudo systemctl enable --now docker
        run sudo docker info --format '{{.ServerVersion}}'
    else log '未运行 systemd（如部分 WSL/容器）；安装完成，请按环境手动启动 Docker daemon'; fi
}

node_action() {
    if [[ -n ${NVM_DIR:-} && $NVM_DIR != "$NVM_HOME" ]]; then die "发现自定义 NVM_DIR=${NVM_DIR}，请使用原 nvm 管理，本脚本仅管理 $NVM_HOME"; fi
    if [[ $ACTION == remove ]]; then
        [[ ! -d $NVM_HOME ]] || require_owned node "$NVM_HOME"
        block "$ENV_FILE" nvm -
        archive_dir node "$NVM_HOME"; return
    fi
    if [[ $ACTION == update && ! -s $NVM_HOME/nvm.sh ]]; then log 'nvm 未安装，跳过更新'; return; fi
    apt_action install ca-certificates curl
    # Resolve the maintained major from the official schedule, not nvm's possibly
    # stale local lts/* alias (which can refer to an end-of-life release).
    local node_major
    download https://raw.githubusercontent.com/nodejs/Release/main/schedule.json "$WORK_DIR/node-schedule.json"
    node_major=$(python3 - "$WORK_DIR/node-schedule.json" "$NODE_VERSION" <<'PY'
import datetime, json, re, sys
schedule = json.load(open(sys.argv[1]))
today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
supported = [int(key[1:]) for key, release in schedule.items()
             if re.fullmatch(r'v[0-9]+', key) and isinstance(release.get('lts'), str)
             and release['lts'] <= today < release.get('end', '')]
requested = max(supported) if sys.argv[2] == 'lts' and supported else int(sys.argv[2]) if sys.argv[2] != 'lts' else 0
if requested not in supported:
    raise SystemExit('所选 Node 主版本未处于官方受支持的 LTS 阶段')
print(requested)
PY
)
    if [[ ! -s $NVM_HOME/nvm.sh || $ACTION == update ]]; then
        [[ ! -e $NVM_HOME || -s $NVM_HOME/nvm.sh ]] || die "目录已存在且不是有效 nvm: $NVM_HOME"
        apt_action install ca-certificates curl git
        if [[ $NVM_VERSION == latest ]]; then
            download https://api.github.com/repos/nvm-sh/nvm/releases/latest "$WORK_DIR/nvm-release.json"
            NVM_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$WORK_DIR/nvm-release.json")
            [[ $NVM_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '无效官方 nvm 稳定版本'
        fi
        if [[ -s $NVM_HOME/nvm.sh ]]; then
            local origin
            origin=$(git -C "$NVM_HOME" remote get-url origin) || die '现有 nvm 不是 git 安装，请用原安装器更新'
            case $origin in https://github.com/nvm-sh/nvm|https://github.com/nvm-sh/nvm.git|git@github.com:nvm-sh/nvm.git) ;; *) die '现有 nvm 的 origin 并非官方，未更新' ;; esac
            git -C "$NVM_HOME" diff --quiet && git -C "$NVM_HOME" diff --cached --quiet || die 'nvm 仓库有未提交的修改，请先保存后更新'
        fi
        download "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" "$WORK_DIR/nvm-install.sh"
        local was_new=0
        [[ -s $NVM_HOME/nvm.sh ]] || was_new=1
        run mkdir -p "$NVM_HOME"
        run env -u NVM_SOURCE -u NODE_VERSION -u NVM_INSTALL_GITHUB_REPO NVM_DIR="$NVM_HOME" PROFILE=/dev/null METHOD=git NVM_INSTALL_VERSION="$NVM_VERSION" bash "$WORK_DIR/nvm-install.sh"
        [[ $was_new -eq 0 ]] || mark_owned node "$NVM_HOME"
    fi
    (
        set +eu
        trap - ERR
        export NVM_DIR="$NVM_HOME"
        export NVM_NODEJS_ORG_MIRROR=https://nodejs.org/dist
        # shellcheck disable=SC1091
        . "$NVM_HOME/nvm.sh" --no-use || exit $?
        local resolved
        resolved=$(nvm version "$node_major") || true
        if [[ $ACTION == install && $resolved != N/A && -n $resolved ]]; then
            log "所选 Node 已安装 ($resolved)，跳过"
        else
            # -b forbids a fallback source build, preserving upstream binaries.
            nvm install -b "$node_major" || exit $?
            nvm alias default "$(nvm current)" || exit $?
        fi
    )
    cat > "$WORK_DIR/nvm-env" <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ ! -s "$NVM_DIR/nvm.sh" ] || . "$NVM_DIR/nvm.sh"
EOF
    block "$ENV_FILE" nvm "$WORK_DIR/nvm-env"
    init_profiles
}

uv_action() {
    local url=https://astral.sh/uv/install.sh executable
    if [[ $ACTION != install && ! -f $STATE_DIR/uv-owned ]] && ! have uv && [[ ! -x $USER_BIN/uv ]]; then
        log 'uv 未安装，跳过'; return
    fi
    if [[ $ACTION == remove ]]; then
        [[ -f $STATE_DIR/uv-owned ]] || die 'uv 并非本脚本安装，拒绝卸载，请使用原包管理器'
        local destination="$STATE_DIR/removed/uv-$(date +%Y%m%dT%H%M%S)-$$"
        # One timestamp, even when this operation crosses a second boundary.
        run mkdir -p "$destination"
        for executable in uv uvx; do
            if [[ -e $USER_BIN/$executable ]]; then run mv -- "$USER_BIN/$executable" "$destination/"; fi
        done
        run mv -- "$STATE_DIR/uv-owned" "$destination/"
        block "$ENV_FILE" uv-path -
        log "uv 已卸载至 ${destination}；保留 uv 工具、缓存和 Python 数据"; return
    fi
    if [[ $ACTION == install ]] && { have uv || [[ -x $USER_BIN/uv ]]; }; then log 'uv 已安装，跳过'; return; fi
    if [[ $ACTION == update ]]; then
        [[ -f $STATE_DIR/uv-owned && -x $USER_BIN/uv ]] || die '更新 uv 需要本脚本安装的独立副本；其他安装方式请用原包管理器'
        if [[ -z $UV_VERSION ]]; then run env UV_NO_MODIFY_PATH=1 "$USER_BIN/uv" self update; return; fi
    fi
    [[ ! -e $USER_BIN/uvx || -f $STATE_DIR/uv-owned ]] || die 'uvx 已存在，未覆盖'
    apt_action install ca-certificates curl
    [[ -z $UV_VERSION ]] || url="https://astral.sh/uv/$UV_VERSION/install.sh"
    download "$url" "$WORK_DIR/uv-install.sh"
    run env -u UV_DOWNLOAD_URL -u INSTALLER_DOWNLOAD_URL -u UV_UNMANAGED_INSTALL UV_INSTALL_DIR="$USER_BIN" UV_NO_MODIFY_PATH=1 sh "$WORK_DIR/uv-install.sh"
    run mkdir -p "$STATE_DIR"
    printf '%s\n' "$USER_BIN" > "$STATE_DIR/uv-owned"
    cat > "$WORK_DIR/uv-env" <<'EOF'
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
EOF
    block "$ENV_FILE" uv-path "$WORK_DIR/uv-env"
    init_profiles
    run "$USER_BIN/uv" --version
}

miniforge_action() {
    if [[ $ACTION == remove ]]; then
        [[ ! -d $FORGE_HOME ]] || require_owned miniforge "$FORGE_HOME"
        block "$ENV_FILE" conda -
        archive_dir miniforge "$FORGE_HOME"; return
    fi
    if [[ -x $FORGE_HOME/bin/conda ]]; then
        if [[ $ACTION == install ]]; then log 'Miniforge 已安装，跳过'; else
            run "$FORGE_HOME/bin/conda" update --yes --name base conda mamba
        fi
        return
    fi
    if [[ $ACTION == update ]]; then log 'Miniforge 未安装，跳过更新'; return; fi
    if have conda; then die '发现其他 conda 安装，请使用原安装管理器，避免重复初始化'; fi
    [[ ! -e $FORGE_HOME ]] || die "Miniforge 目录已存在: $FORGE_HOME"
    local architecture url tag filename checksum
    architecture=$(uname -m)
    case $architecture in x86_64|aarch64|ppc64le) ;; *) die "Miniforge 不支持此架构: $architecture" ;; esac
    apt_action install ca-certificates curl
    tag=$MINIFORGE_VERSION
    if [[ $tag == latest ]]; then
        download https://api.github.com/repos/conda-forge/miniforge/releases/latest "$WORK_DIR/forge-release.json"
        tag=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$WORK_DIR/forge-release.json")
        [[ $tag =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die '无效官方 Miniforge 发行标签'
    fi
    filename="Miniforge3-Linux-$architecture.sh"
    url="https://github.com/conda-forge/miniforge/releases/download/$tag/$filename"
    download "$url" "$WORK_DIR/$filename"
    download "$url.sha256" "$WORK_DIR/$filename.sha256"
    checksum=$(awk 'NR == 1 {print $1}' "$WORK_DIR/$filename.sha256")
    [[ $checksum =~ ^[a-fA-F0-9]{64}$ ]] || die '无效 SHA256 文件'
    printf '%s  %s\n' "$checksum" "$WORK_DIR/$filename" | sha256sum --check --status || die 'Miniforge SHA256 校验失败'
    run bash "$WORK_DIR/$filename" -b -p "$FORGE_HOME"
    mark_owned miniforge "$FORGE_HOME"
    run "$FORGE_HOME/bin/conda" config --file "$FORGE_HOME/.condarc" --set auto_activate_base false
    cat > "$WORK_DIR/conda-env" <<'EOF'
[ ! -f "$HOME/miniforge3/etc/profile.d/conda.sh" ] || . "$HOME/miniforge3/etc/profile.d/conda.sh"
EOF
    block "$ENV_FILE" conda "$WORK_DIR/conda-env"
    init_profiles
    run "$FORGE_HOME/bin/conda" --version
}

omz_action() {
    if [[ -n ${ZSH:-} && $ZSH != "$OMZ_HOME" ]]; then die "发现自定义 ZSH=${ZSH}；请使用原 OMZ 管理方式"; fi
    if [[ $ACTION == remove ]]; then
        [[ ! -d $OMZ_HOME ]] || require_owned omz "$OMZ_HOME"
        block "$ZSHRC" omz -
        archive_dir omz "$OMZ_HOME"; return
    fi
    if [[ $ACTION == update ]]; then
        [[ -f $OMZ_HOME/oh-my-zsh.sh ]] || { log 'OMZ 未安装，跳过'; return; }
        local origin
        origin=$(git -C "$OMZ_HOME" remote get-url origin) || die 'OMZ 不是有效 git 安装'
        case $origin in https://github.com/ohmyzsh/ohmyzsh|https://github.com/ohmyzsh/ohmyzsh.git|git@github.com:ohmyzsh/ohmyzsh.git) ;; *) die 'OMZ origin 并非官方，请用原安装方式更新' ;; esac
        run env ZSH="$OMZ_HOME" zsh -f "$OMZ_HOME/tools/upgrade.sh"; return
    fi
    if [[ -f $OMZ_HOME/oh-my-zsh.sh ]]; then log 'OMZ 已安装，跳过；用 configure omz 调整主题和插件'; return; fi
    [[ ! -e $OMZ_HOME ]] || die "OMZ 目录已存在: $OMZ_HOME"
    apt_action install zsh git curl ca-certificates
    # Prevent the installer from generating a template, which we manage explicitly.
    [[ -e $ZSHRC ]] || { run mkdir -p "$(dirname -- "$ZSHRC")"; touch "$ZSHRC"; }
    download https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh "$WORK_DIR/omz-install.sh"
    run env ZSH="$OMZ_HOME" ZDOTDIR="$(dirname -- "$ZSHRC")" REPO=ohmyzsh/ohmyzsh REMOTE=https://github.com/ohmyzsh/ohmyzsh.git BRANCH=master CHSH=no RUNZSH=no KEEP_ZSHRC=yes sh "$WORK_DIR/omz-install.sh" --unattended
    mark_owned omz "$OMZ_HOME"
    configure_omz
}

configure_omz() {
    [[ -f $OMZ_HOME/oh-my-zsh.sh ]] || die 'OMZ 未安装'
    local plugins=()
    IFS=',' read -r -a plugins <<< "$OMZ_PLUGINS"
    cfg omz "$ZSHRC" "$OMZ_HOME" "$OMZ_THEME" "${plugins[@]}"
}

docker_mirror() {
    local mirrors=() backup="$DOCKER_CONFIG.ubuntu-init.$(date +%Y%m%dT%H%M%S).$$.bak" had_config=0 active=0 directory
    directory=$(dirname -- "$DOCKER_CONFIG")
    installed docker-ce || die '镜像配置仅支持系统官方 docker-ce（不修改 rootless/Desktop 配置）'
    systemd_running || die 'Docker 镜像自动应用需要 systemd'
    [[ ! -L $DOCKER_CONFIG ]] || die 'daemon.json 是符号链接，拒绝覆盖'
    if sudo test -e "$DOCKER_CONFIG"; then
        had_config=1
        sudo cat "$DOCKER_CONFIG" > "$WORK_DIR/daemon-old.json"
    else printf '{}\n' > "$WORK_DIR/daemon-old.json"; fi
    IFS=',' read -r -a mirrors <<< "$DOCKER_MIRROR"
    cfg docker "$WORK_DIR/daemon-old.json" "$WORK_DIR/daemon-new.json" "${mirrors[@]}"
    run sudo dockerd --validate --config-file "$WORK_DIR/daemon-new.json"
    if cmp -s "$WORK_DIR/daemon-old.json" "$WORK_DIR/daemon-new.json"; then log 'Docker 配置无需更改'; return; fi
    sudo systemctl is-active --quiet docker && active=1
    [[ $had_config -eq 0 ]] || run sudo cp -p "$DOCKER_CONFIG" "$backup"
    run sudo install -m 0755 -d "$directory"
    run sudo install -m 0644 "$WORK_DIR/daemon-new.json" "$directory/.daemon-ubuntu-init-$$.json"
    run sudo mv -f "$directory/.daemon-ubuntu-init-$$.json" "$DOCKER_CONFIG"
    if [[ $active -eq 1 ]] && ! run sudo systemctl restart docker; then
        if [[ $had_config -eq 1 ]]; then run sudo cp -p "$backup" "$DOCKER_CONFIG"
        else run sudo rm -- "$DOCKER_CONFIG"; fi
        sudo systemctl restart docker || log '原配置已恢复，但服务仍启动失败，请检查 journalctl -u docker'
        die 'Docker 重启失败，已恢复原配置'
    fi
    log "Docker 镜像配置已应用；原配置备份（原文件存在时）: $backup"
}

configure_component() {
    local component=$1
    case $component in
        docker) docker_mirror ;;
        python|uv)
            [[ $PYPI_INDEX != official ]] || PYPI_INDEX=https://pypi.org/simple
            cfg env "$ENV_FILE" PIP_INDEX_URL "$PYPI_INDEX"
            cfg env "$ENV_FILE" UV_DEFAULT_INDEX "$PYPI_INDEX"
            init_profiles ;;
        node)
            [[ $NPM_REGISTRY != official ]] || NPM_REGISTRY=https://registry.npmjs.org
            cfg env "$ENV_FILE" NPM_CONFIG_REGISTRY "$NPM_REGISTRY"
            init_profiles ;;
        miniforge)
            [[ -x $FORGE_HOME/bin/conda ]] || die 'Miniforge 未安装'
            # A separate snippet preserves unrelated .condarc settings.
            # conda reads $CONDA_ROOT/condarc.d/*.yml in addition to .condarc.
            local target="$FORGE_HOME/condarc.d/ubuntu-init.yml"
            local channel=$CONDA_CHANNEL
            [[ $channel != official ]] || channel=https://conda.anaconda.org/conda-forge
            cfg conda "$target" "$channel"
            run "$FORGE_HOME/bin/conda" config --show channels
            log 'Conda 频道策略已设置（#!final）；可用 conda config --show-sources 核对；命令行覆盖仍可用' ;;
        omz) configure_omz ;;
        zsh) : ;;
    esac
}

change_shell() {
    local shell_path current
    shell_path=$(command -v zsh) || die 'zsh 尚未安装'
    grep -Fxq "$shell_path" /etc/shells || die "zsh 未列在 /etc/shells: $shell_path"
    current=$(getent passwd "$(id -un)" | cut -d: -f7)
    if [[ $current != "$shell_path" ]]; then run sudo chsh -s "$shell_path" "$(id -un)"; else log '登录 shell 已是 zsh'; fi
}

dispatch() {
    local component=$1
    if [[ $ACTION == configure ]]; then configure_component "$component"; return; fi
    case $component in
        docker) docker_action ;;
        node) node_action ;;
        python)
            if [[ $ACTION == remove ]]; then apt_action remove python3-venv python3-pip python3-dev
            else apt_action "$ACTION" "${PYTHON_PACKAGES[@]}"; fi ;;
        uv) uv_action ;;
        miniforge) miniforge_action ;;
        dev) apt_action "$ACTION" "${DEV_PACKAGES[@]}" ;;
        zsh)
            if [[ $ACTION == remove && $(getent passwd "$(id -un)" | cut -d: -f7) == */zsh ]]; then die '当前登录 shell 是 zsh，请先手动 chsh -s /bin/bash 并重新登录后再卸载'; fi
            apt_action "$ACTION" zsh ;;
        omz) omz_action ;;
        apt) apt_action "$ACTION" "${APT_PACKAGES[@]}" ;;
    esac
}

main() {
    parse_args "$@"
    [[ -n $ACTION ]] || menu
    validate_args
    require_ubuntu
    if [[ $ACTION == check && ${#COMPONENTS[@]} -eq 0 ]]; then COMPONENTS=(docker node python uv miniforge dev zsh omz apt); fi
    if [[ $ACTION == check ]]; then
        local component
        for component in "${COMPONENTS[@]}"; do status_component "$component"; done
        return
    fi
    plan
    if [[ $DRY_RUN -eq 1 ]]; then log '预览结束：没有写文件、下载软件或使用 sudo'; return; fi
    [[ $EUID -ne 0 ]] || die '请用有 sudo 权限的普通用户运行，勿 sudo bash（避免写入 /root）'
    have sudo || die '找不到 sudo'
    [[ -r $CONFIG_HELPER ]] || die "缺少配置辅助文件: ${CONFIG_HELPER}（请保留整个 Ubuntu 目录）"
    confirm
    run sudo -v
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ubuntu-init.XXXXXXXX")
    trap cleanup EXIT
    trap 'printf "\n执行失败（行 %s），已停止。已完成的步骤不会整体回滚；可以修复后重跑。\n" "$LINENO" >&2' ERR
    umask 022
    # Used solely for atomic config edits; also available on minimal Ubuntu images.
    if ! have python3; then apt_action install python3; fi
    local component
    for component in "${COMPONENTS[@]}"; do
        log "处理 $component"
        dispatch "$component"
    done
    [[ $SET_DEFAULT_SHELL -eq 0 ]] || change_shell
    log '所选操作已完成。用户环境/镜像配置在新 Bash/Zsh 会话生效；请重新登录以应用登录 shell 的变化。'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
