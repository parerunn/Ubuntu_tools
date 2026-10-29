# Ubuntu工具

## 说明
在Ubuntu服务器上用到的各种工具，脚本的合集

包含以下工具

+ Ubuntu 新系统按需初始化：[使用文档](Ubuntu/README.md)
  + Docker、nvm/Node、Python/uv/Miniforge、开发工具、zsh/OMZ、APT 软件
  + 交互选择、安装前检查、安装/更新/卸载、可选镜像、只读预览
+ V2ray管理脚本
  + 自动统计每日用户流量使用情况

## 启动方式

### Ubuntu 初始化

在目标 Ubuntu LTS 上以有 sudo 权限的普通用户运行，不要加 `sudo`：

```bash
bash Ubuntu/ubuntu-init.sh          # 交互菜单，不预选软件
bash Ubuntu/ubuntu-init.sh check    # 只读状态检查
```

完整命令、配置与卸载说明见 [Ubuntu/README.md](Ubuntu/README.md)。

### V2ray管理
添加到crontab每天运行，按每月添加文件

## 依赖

### V2ray tools
None

## 配置

### V2ray tools
None
