"""把本地重建好的字体 + 面板脚本推送到 mido（Redmi Note 4x / Debian）

用法:
    python deploy.py            # 推送 + 重启 + 验证
    python deploy.py --check    # 只验证，不推送

推送清单:
    out_font/mido-30x40.psf              -> /usr/local/share/consolefonts/
    out_font/pua.sed                     -> /usr/local/share/consolefonts/
    out_font/Uni2-mido40x30.psf.gz        -> /usr/share/consolefonts/
    out_font/battery-panel.run.sh        -> /usr/local/bin/battery-panel.sh      (预编译版，systemd 实际跑的)
    battery-panel.sh                     -> /usr/local/bin/battery-panel.src.sh  (可读源码版)
"""
import io
import os
import sys
import time

import paramiko

# 连接参数从环境变量读，避免把口令写进仓库：
#   MIDO_HOST=192.168.1.x MIDO_PASS=你的口令 python deploy.py

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8",
                              errors="replace", line_buffering=True)

HOST = os.environ.get("MIDO_HOST", "192.168.1.100")
PORT = 22
USER = "root"
PASS = os.environ.get("MIDO_PASS", "")

FILES = [
    ("out_font/mido-30x40.psf", "/usr/local/share/consolefonts/mido-30x40.psf", 0o644),
    ("out_font/pua.sed", "/usr/local/share/consolefonts/pua.sed", 0o644),
    ("out_font/Uni2-mido40x30.psf.gz", "/usr/share/consolefonts/Uni2-mido40x30.psf.gz", 0o644),
    ("out_font/battery-panel.run.sh", "/usr/local/bin/battery-panel.sh", 0o755),
    ("battery-panel.sh", "/usr/local/bin/battery-panel.src.sh", 0o755),
]

STAMP = time.strftime("%Y%m%d-%H%M%S")

BACKUP = r"""
set -e
TS=%s
for f in /usr/local/share/consolefonts/mido-30x40.psf \
         /usr/local/share/consolefonts/pua.sed \
         /usr/share/consolefonts/Uni2-mido40x30.psf.gz \
         /usr/local/bin/battery-panel.sh; do
  [ -e "$f" ] && cp -a "$f" "$f.bak.$TS"
done
echo "备份完成 $TS"
""" % STAMP

VERIFY = r"""
echo "--- 文件 ---"
ls -l /usr/local/share/consolefonts/mido-30x40.psf \
      /usr/local/share/consolefonts/pua.sed \
      /usr/share/consolefonts/Uni2-mido40x30.psf.gz \
      /usr/local/bin/battery-panel.sh \
      /usr/local/bin/battery-panel.src.sh
echo "--- 预编译检查（正文里应无汉字，PUA_SED 应为空）---"
grep -c 'PUA_SED=""' /usr/local/bin/battery-panel.sh || true
python3 - <<'PY' 2>/dev/null || true
import io
# 注释里的汉字不参与渲染，必须先用 mkfont.py 同款逻辑剔掉再数，
# 否则行尾注释会被当成「漏编译」，天天报假警。
def split_comment(ln):
    out = []; q = None
    for i, ch in enumerate(ln):
        if q:
            out.append(ch)
            if ch == q: q = None
        elif ch in ("'", '"'): q = ch; out.append(ch)
        elif ch == '#' and (i == 0 or ln[i - 1] in ' \t'): break
        else: out.append(ch)
    return ''.join(out)
d = io.open('/usr/local/bin/battery-panel.sh', encoding='utf-8').read()
code = '\n'.join(split_comment(ln) for ln in d.split('\n'))
bad = [c for c in code if 0x4E00 <= ord(c) <= 0x9FFF]
print('正文残留汉字数（不含注释）:', len(bad), '' if not bad else '← 有漏编译！')
PY
echo "--- 服务状态 ---"
systemctl is-active battery-panel console-font-mido console-setup qinglong tailscaled
echo "--- 单位 ---"
stty -F /dev/tty1 size 2>/dev/null || true
cat /sys/class/graphics/fb0/virtual_size
echo "--- md5 ---"
md5sum /usr/local/share/consolefonts/mido-30x40.psf /usr/local/bin/battery-panel.sh
"""


def sh(client, cmd, timeout=300):
    _in, out, err = client.exec_command(cmd, timeout=timeout)
    o = out.read().decode("utf-8", errors="replace")
    e = err.read().decode("utf-8", errors="replace")
    rc = out.channel.recv_exit_status()
    if o:
        sys.stdout.write(o)
    if e.strip():
        sys.stdout.write("--- stderr ---\n" + e)
    return rc


def connect():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, PORT, USER, PASS, timeout=20,
              look_for_keys=False, allow_agent=False)
    return c


def push(client):
    sftp = paramiko.SFTPClient.from_transport(client.get_transport())
    for local, remote, mode in FILES:
        sftp.put(local, remote)
        sftp.chmod(remote, mode)
        print("  %-46s -> %s" % (local, remote))
    sftp.close()


def main():
    do_push = "--check" not in sys.argv
    client = connect()
    try:
        if do_push:
            print("== 备份 ==")
            sh(client, BACKUP)
            print("== 推送 ==")
            push(client)
            print("== 重启服务 ==")
            sh(client, "systemctl restart console-font-mido.service; "
                       "sleep 1; systemctl restart battery-panel.service; "
                       "sleep 1; systemctl --no-pager --lines=0 status battery-panel | head -5")
            print("（等 4 秒让看板画完第一帧）")
        print("== 验证 ==")
        sh(client, VERIFY)
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
