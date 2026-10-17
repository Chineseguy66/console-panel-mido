# 终端看板（Console Panel）

在 **TTY1** 上用纯 bash 画的一屏系统监控面板，**不需要桌面环境**：
36 列 × 48 行的字符界面，每 5 秒刷新一次，把电池 / 充电配置 / 系统负载 / 青龙面板 / WLAN /
内网穿透六组状态全部铺在一屏里。

本工具基于 [debian-on-mido](https://github.com/calico-cat-3333/debian-on-mido) 镜像开发，
专门适配 Debian 13 trixie + `6.16.3-calicocat-msm8953+` 内核。
tty1 开机自启、常驻显示，像一块挂在墙上的「系统状态牌」。

![看板效果](console-panel-mido/preview.png)

CPU / 内存 / 交换 / 温度 / 磁盘超过阈值会自动变黄、变红，一眼能看出哪项不对：

![告警配色](console-panel-mido/preview-alert.png)

## 环境依赖

* 只依赖 bash 和几个基础命令（`awk` / `ip` / `iw` / `df` / `ss` / `tailscale`），
  不装 Node、不装 Python 也能跑；
* 单帧 CPU 开销约 **0.265 秒**（8 核 A53，折合整机约 0.036%），常驻内存 1.5～2.8 MB；
* 中文能正常显示，是因为配了一套**自制的 30×40 控制台点阵字体**（含常用汉字），
  并按「预编译成 PUA 码点」的方式让每个汉字只占 1 格 —— 这也是这份看板排版能做得比较紧凑的原因。

## 安装

把 `mido-console-panel-20261017.tar.gz` 下载到手机上，然后：

```bash
tar xzf mido-console-panel-20261017.tar.gz
cd mido-console-panel
sudo ./install.sh
```

`install.sh` 会自动完成：环境检查 → **分辨率校验** → 装依赖 → 备份原文件 → 部署字体与脚本
→ 启用三个 systemd 服务 → 渲染一帧自检。

## 可选参数

```bash
sudo ./install.sh --dry-run     # 只看会改哪些文件，不动系统（建议先跑一遍）
sudo ./install.sh --no-deps     # 跳过 apt 装依赖
sudo ./install.sh --no-adapt    # 跳过硬件路径自适应（本机就是 mido 时可用）
```

装完不用重启，看板会自己刷出来。卸载用 `sudo ./uninstall.sh`。

## 自定义署名

看板右上角默认显示「机主」。想换成自己的昵称：

```bash
cd mido-console-panel/source
vim battery-panel.src.sh          # 找到最上面「用户配置」里的 OWNER= 那一行改掉
bash build.sh                     # ⚠ 必须重建字体，见下
```

改完把 `out_font/` 里的 4 个产物按 `deploy.py` 的清单推上去，或者直接重跑一次 `install.sh --force`。

> **为什么必须重建字体**：中文是靠「编译期把汉字换成 PUA 码点」来做到 1 格宽的，
> 字形由 `mkfont.py` 从脚本正文里提取。**新出现的字如果不在字体里，会静默地变成 `- + * #` 这种方块。**
> 只改成 ASCII（比如 `mido`）则不用重建。

## 注意事项

* **屏幕必须是 1080×1920**。字体固定 30×40，栅格固定 36 列 × 48 行，`install.sh` 会硬校验分辨率，
  不符就直接停下 —— 换分辨率要重新生成字体并改栅格常量，不是 `--force` 能绕过的。
* **部署到 `/usr/local/bin/battery-panel.sh` 的那份是预编译版，不要直接改它**。
  要改就改 `source/battery-panel.src.sh`，再跑 `bash build.sh`。
* **调试不要用 `bash -x` 往 `/tmp` 写日志**。这个镜像里 `/tmp` 是 tmpfs（内存文件系统），
  整脚本追踪一次会输出三万行以上日志，**直接把内存打满**，然后被 OOM 杀掉。
  真要追踪就写到磁盘目录（如 `/var/log/`），并且只在排查问题时用，正式运行不要带。
* 字体同时放在两个路径：`/usr/local/share/consolefonts/mido-30x40.psf`（`setfont` 直接加载）和
  `/usr/share/consolefonts/Uni2-mido40x30.psf.gz`（`console-setup` 按 `Uni2-<FACE><SIZE>` 规则查找）。
  **两处必须同内容**，少一处会在不同的启动路径下掉回默认字体。
* 看板会每帧清屏，所以**看不到 tty1 的登录提示符**，这是正常的。
  如果需要在 tty1 上敲命令，就先 `sudo systemctl stop battery-panel`。

## 卸载

```bash
sudo ./uninstall.sh
```

会停掉并禁用三个服务、删掉字体与脚本，并恢复安装时备份的原文件（备份在
`/root/mido-panel-backup/<时间戳>/`）。

## 问题反馈

1. 面板脚本、功能 Bug：在本仓库提交 Issue
2. debian-on-mido 底层系统问题：前往 [debian-on-mido](https://github.com/calico-cat-3333/debian-on-mido) 原仓库

## License

MIT
