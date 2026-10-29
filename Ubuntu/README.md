# Ubuntu 按需初始化

为新装 Ubuntu LTS 提供交互菜单和命令行入口，支持安装、更新、卸载、状态检查和可选镜像配置。默认不安装任何组件。

目标系统：Ubuntu **22.04、24.04、26.04 LTS**，以拥有 sudo 权限的普通用户运行。其他系统会直接退出。保留整个 `Ubuntu` 目录：入口脚本依赖同目录的 `configure.py`，配置处理只使用 Python 标准库。

## 开始使用

以下命令均在**目标 Ubuntu 系统**的仓库根目录执行，**不要在脚本前加 sudo**。脚本只在 APT、Docker 系统配置等步骤调用 sudo，用户级工具安装到当前用户的 HOME。

```bash
# 菜单：先选择动作，再输入组件名；直接回车退出，不预选组件
bash Ubuntu/ubuntu-init.sh

# 只读检查所有组件；不联网、不 sudo、不写配置
bash Ubuntu/ubuntu-init.sh check

# 先检查已安装状态并预览，再执行明确选择的组件
bash Ubuntu/ubuntu-init.sh install dev docker node uv --dry-run
bash Ubuntu/ubuntu-init.sh install dev docker node uv

# 只安装指定的 APT 小工具
bash Ubuntu/ubuntu-init.sh install apt --packages htop,tree,tmux,jq

# 为持续运行的项目固定 Node 主版本，避免更新时切换到新 LTS 主版本
bash Ubuntu/ubuntu-init.sh install node --node-version 24
bash Ubuntu/ubuntu-init.sh update node --node-version 24

# 安装 zsh 和 OMZ；显式选择才修改登录 shell
bash Ubuntu/ubuntu-init.sh install omz --set-default-shell

# 更新已安装的所选软件，不执行全系统 upgrade
bash Ubuntu/ubuntu-init.sh update docker python uv miniforge apt --packages htop,tmux

# 明确选择后跳过脚本确认；APT remove 仍会显示依赖移除清单并要求确认
bash Ubuntu/ubuntu-init.sh install dev uv apt --packages htop,tmux --yes

bash Ubuntu/ubuntu-init.sh --help
```

安装动作会跳过已安装的软件，APT 仅补齐缺失包。Node 检查所选、仍受支持的 LTS 主版本，已安装该主版本时跳过安装；`update` 才安装该主版本最新补丁。nvm 的现有默认版本在跳过安装时保持不变，可自行执行 `nvm alias default 24`。

更新动作不会为缺失组件执行全新安装；所需的下载/配置辅助依赖可能需要补齐。`--dry-run` 只显示本地状态与操作计划，不查询在线可用版本，不下载或验证远端镜像的连通性。

## 组件与安装方式

| 组件 | 内容及方式 | 更新行为 |
| --- | --- | --- |
| `docker` | Docker 官方签名 APT stable 仓库，Engine、CLI、containerd.io、Buildx、Compose 插件 | APT 仅升级已安装的上述包，可能重启服务 |
| `node` | nvm 官方稳定标签安装器，用户级安装；从 Node 官方下载二进制；根据官方周期表选择受支持 LTS | 更新 nvm，再安装所选主版本最新补丁并设置为默认；保留旧 Node 版本和全局包 |
| `python` | Ubuntu APT 的 python3、python3-venv、python3-pip、python3-dev | 随当前 Ubuntu 发行版的仓库维护，不替换 `/usr/bin/python3` |
| `uv` | Astral 官方独立安装器，安装到 `~/.local/bin` | 本脚本安装的副本用 `uv self update`；指定版本时重跑官方安装器 |
| `miniforge` | conda-forge 官方 Miniforge 发行包，按架构下载并核对 SHA256 | 用 conda 更新 base 中的 conda/mamba，不升级全部项目环境 |
| `dev` | Ubuntu APT：build-essential、git、gcc、g++、make、cmake、pkg-config、ninja-build、gdb | APT 仅升级已安装包 |
| `zsh` | Ubuntu APT zsh | APT 更新 |
| `omz` | OMZ 官方 unattended 安装器，自动补齐 zsh；使用官方内置主题与插件 | 调用 OMZ 官方升级脚本，不覆盖 `.zshrc` |
| `apt` | 默认只有 htop，可用 `--packages` 明确选择其他工具 | APT 仅升级所列且已安装的包 |

APT 可选白名单：`htop tree jq unzip zip tmux ripgrep fd-find wget curl ca-certificates net-tools lsof`。开发工具用 `dev` 组件选择。按需补齐 `ca-certificates`、`curl`、`git`、`python3` 等必需依赖，不主动修改 Ubuntu 软件源或开启额外 PPA；目标系统需要有提供所选包的仓库。

Docker 使用官方仓库，不使用面向测试/开发的便利安装脚本。首次安装在 systemd 系统中启用并启动 Docker；已有 Engine 时保留服务状态。无 systemd 的 WSL/容器允许安装，但需自行启动 daemon；镜像自动应用需要 systemd。脚本不会自动把用户加入具有高权限的 docker 组，默认用 `sudo docker ...`。

如果检测到 `docker.io`、`containerd`、`runc` 等冲突包，会停止并列出冲突。核对已有容器或 Kubernetes 依赖后，才明确迁移：

```bash
bash Ubuntu/ubuntu-init.sh install docker --migrate-docker
```

脚本拒绝直接覆盖不匹配的现有 Docker APT 源，也不自动接管 Snap、Docker Desktop 或 rootless Docker。现有 nvm、conda、OMZ 的自定义路径不会被自动迁移；nvm/OMZ 管理标准目录 `~/.nvm`、`~/.oh-my-zsh`，Miniforge 管理 `~/miniforge3`。自定义 `ZDOTDIR` 会用于定位 `.zshrc`。

## Python 的选择

系统 Python、uv、Miniforge 可独立选择。uv 安装不依赖预先安装 Python，也不会自动额外下载一个 Python；本脚本为了编辑配置可能补齐 Ubuntu 的 python3。需要独立 Python 时，安装 uv 后可自行运行：

```bash
uv python install 3.12
uv venv --python 3.12 .venv
```

uv 使用 Astral 维护的 Python 发行构建，区别于 Ubuntu 维护的系统 Python。脚本不执行 `sudo pip install`，不修改 `update-alternatives` 或覆盖系统解释器。Miniforge 提供独立 Python 和 conda/mamba，初始化只加载 conda 函数，不自动激活 base。项目依赖请装在 venv 或 conda 环境中。

## 可选镜像与 OMZ 设置

默认使用官方来源，只有 `configure` 动作会修改镜像。以下 `*.example` 是占位地址，需替换为自己认可且可访问的 HTTPS 服务。不会自动选用第三方镜像或关闭 TLS 验证。

```bash
# 合并 /etc/docker/daemon.json，仅变更 registry-mirrors
bash Ubuntu/ubuntu-init.sh configure docker \
  --docker-mirror https://registry-mirror.example

# 清除 Docker registry-mirrors，其他 daemon 配置保留
bash Ubuntu/ubuntu-init.sh configure docker --docker-mirror none

# pip 与 uv 的包索引；不是 Python 解释器安装包的下载镜像
bash Ubuntu/ubuntu-init.sh configure python uv \
  --pypi-index https://pypi-mirror.example/simple

# Miniforge 的完整 conda-forge 频道地址
bash Ubuntu/ubuntu-init.sh configure miniforge \
  --conda-channel https://conda-mirror.example/anaconda/cloud/conda-forge

# npm 包仓库；Node 二进制仍来自 Node 官方
bash Ubuntu/ubuntu-init.sh configure node \
  --npm-registry https://npm-mirror.example

# 恢复官方包源
bash Ubuntu/ubuntu-init.sh configure python uv --pypi-index official
bash Ubuntu/ubuntu-init.sh configure miniforge --conda-channel official
bash Ubuntu/ubuntu-init.sh configure node --npm-registry official

# 仅从已安装 OMZ 的官方内置主题/插件中选择，不自动安装第三方插件
bash Ubuntu/ubuntu-init.sh configure omz \
  --omz-theme robbyrussell --omz-plugins git,sudo,docker,python,pip
```

pip、uv、npm 镜像通过 `~/.config/ubuntu-init/env.sh` 的管理块导出 `PIP_INDEX_URL`、`UV_DEFAULT_INDEX`、`NPM_CONFIG_REGISTRY`；`.bashrc` 和 `.zshrc` 添加一条可重复执行的加载块，修改在**新会话**生效。需要当前 Bash/Zsh 立即生效可执行：

```bash
source "$HOME/.config/ubuntu-init/env.sh"
```

这些环境变量优先于包管理器配置中的对应值；显式命令行参数可以覆盖。服务、cron 和非交互 shell 若不读取这些启动文件，需要自行设置环境变量或加载该文件。Docker 的 `registry-mirrors` 主要用于 Docker Hub，其他 registry、Docker APT 仓库、uv 安装器和 Miniforge 安装器不随之切换。

Conda 将频道策略写入 `~/miniforge3/condarc.d/ubuntu-init.yml`，使用官方 `#!final` 配置规则避免其他 `.condarc` 把原始频道合并回来，设置 strict 优先级。它会限制其他 rc 文件中的 `channels`；如需多个频道，可手动编辑这个独立文件。通过 `conda config --show-sources`、`conda config --show channels` 检查最终结果。恢复 `official` 表示仅使用官方 conda-forge 频道；删除该管理文件可撤销本脚本的频道策略并恢复其他 rc 文件的合并行为。

Docker 配置先生成候选 JSON，合并并保留已有参数，再执行 `dockerd --validate`，通过后备份原文件并原子替换。仅当系统 Docker 服务原本正在运行时重启；重启失败则恢复原配置并尝试恢复服务。重启可能影响正在运行的容器，请在合适的维护时间执行。

OMZ 默认主题 `robbyrussell`，插件 `git sudo docker python pip`，更新方式为提示。首次安装保留 `.zshrc`，以管理块设置主题、插件并加载一次 OMZ。已有标准 OMZ 加载语句会替换为管理块；复杂或多个加载语句会拒绝自动处理，原文件保留。其他用户配置保留，但放在管理块之后的自定义语句仍可能改变最终行为。符号链接形式的配置文件拒绝自动覆盖，请手动编辑其目标。

## 版本控制与卸载

默认使用各项目最新稳定管理器。可固定安装标签以便记录、复用；显式版本也允许回到指定旧版本，请自行选择仍受维护的版本。

```bash
bash Ubuntu/ubuntu-init.sh install node --nvm-version v0.40.8 --node-version 24
bash Ubuntu/ubuntu-init.sh install uv --uv-version 0.13.1
# --miniforge-version 使用官方 releases 页上的完整 tag；只影响首次安装

bash Ubuntu/ubuntu-init.sh remove node uv miniforge omz
bash Ubuntu/ubuntu-init.sh remove apt --packages htop,tree
```

- APT 使用 `remove`，保留配置，不执行 `purge`、`autoremove` 或全系统升级。APT 自身会显示额外依赖移除清单并确认，`--yes` 不绕过这次确认。
- `remove python` 仅选择 python3-venv、python3-pip、python3-dev；不选择移除系统 python3。APT 可能列出依赖这些开发包的软件，请在其确认界面核对。
- Docker 卸载保留镜像、卷、容器数据、daemon 配置、官方源和密钥，便于重装。
- nvm/Node、Miniforge、OMZ 仅卸载本脚本新安装并标记的副本，整个目录移至 `~/.local/state/ubuntu-init/removed/`，保留全局包、环境及自定义插件。移动后的环境不保证原地可用，备份用于还原到原路径。外部安装可以检测、按支持方式更新，但不会被本脚本擅自移除。
- uv 只更新/卸载本脚本安装的独立副本；卸载将 uv/uvx 二进制移至上述备份目录，保留 uv 管理的工具、Python 和缓存。
- OMZ 与 zsh 分开卸载；当前用户以 zsh 为登录 shell 时拒绝卸载 zsh，先执行 `chsh -s /bin/bash` 并重新登录。共享主机还需确认其他用户是否使用 zsh。

配置实际变化前会创建邻近的 `.ubuntu-init.<时间>.<标识>.bak` 备份，相同配置重跑不重复写入或备份。Shell 管理块可以单独删除，回退前请比较备份与当前文件。目录卸载使用移动备份，不释放其占用的磁盘空间；确认不再需要时再自行清理。

某一步失败即停止，保留错误输出；已完成的软件安装不会整体回滚，可修复后重跑。网络失败不降级到非官方源，不自动禁用证书检查。nvm/Miniforge 默认标签通过 GitHub 官方 API 查询，触发 API 限流时可稍后重试或显式固定标签。

## 检查与测试

本项目的验证使用临时目录和模拟的 sudo/APT/网络/Docker 命令，不在开发机安装任何目标软件。覆盖配置幂等与备份、现有设置保留、HTTPS 校验、OMZ 单次加载、依赖筛选、过期 LTS 拒绝、Miniforge 校验失败、Docker 验证及回滚。尚未在实际 Ubuntu 虚拟机中完成在线安装验收。

```bash
bash -n Ubuntu/ubuntu-init.sh
python3 -B -m unittest discover -s Ubuntu/tests -v
```

## 官方参考

- [Docker Engine：Ubuntu 官方 APT 安装、更新与卸载](https://docs.docker.com/engine/install/ubuntu/)
- [Docker daemon 配置](https://docs.docker.com/engine/daemon/)
- [nvm 官方安装与更新](https://github.com/nvm-sh/nvm#installing-and-updating)
- [Node.js 发布周期与生产环境 LTS 选择](https://nodejs.org/en/about/previous-releases)
- [uv 官方安装与自更新](https://docs.astral.sh/uv/getting-started/installation/)
- [uv 安装器选项](https://docs.astral.sh/uv/reference/installer/)
- [uv 管理 Python](https://docs.astral.sh/uv/guides/install-python/)
- [Miniforge 官方安装、初始化及卸载](https://github.com/conda-forge/miniforge)
- [Conda 配置搜索路径](https://docs.conda.io/projects/conda/en/latest/dev-guide/api/conda/base/constants/)
- [Conda 的 final 配置规则](https://docs.conda.io/projects/conda/en/26.3.x/user-guide/configuration/admin-multi-user-install.html)
- [Oh My Zsh 官方安装说明](https://github.com/ohmyzsh/ohmyzsh#basic-installation)
- [Ubuntu 软件包管理与脚本中使用 apt-get](https://ubuntu.com/server/docs/how-to/software/package-management/)
