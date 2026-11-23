#!/usr/bin/env python3
"""
screen-idle.py —— 红米 mido Debian 息屏守护
- 空闲 120 秒自动关背光 (brightness=0)
- 按音量键/电源键/触摸唤醒 (brightness=2048)
- 只关背光，不关机

python3-evdev 属于可选依赖：没装时脚本会打印安装提示并以 0 正常退出，
不会抛 ImportError 崩溃（服务单元是 Restart=on-failure，退出码 0 不会拉起）。
"""
import threading
import time
import os
import select

try:
    from evdev import InputDevice, list_devices, ecodes
    HAVE_EVDEV = True
except ImportError:
    HAVE_EVDEV = False
    InputDevice = list_devices = ecodes = None

BACKLIGHT = "/sys/class/backlight/backlight/brightness"
BRIGHT_ON = 2048   # 亮屏亮度
BRIGHT_OFF = 0     # 息屏亮度
IDLE_SEC = 120     # 空闲多久息屏
POLL = 1.0         # 检查周期(秒)

# 感兴趣的设备名关键字（音量键/电源键/触摸屏）
WATCH_NAMES = ("gpio-keys", "pm8941_pwrkey", "pm8941_resin", "ft5x06")

# 需要唤醒的按键：音量+/音量-/电源/触摸
# （evdev 没装时 ecodes 为 None，这里必须留空集合，避免 import 阶段就 NameError）
WAKE_CODES = ({ecodes.KEY_VOLUMEUP, ecodes.KEY_VOLUMEDOWN,
               ecodes.KEY_POWER, ecodes.BTN_TOUCH} if HAVE_EVDEV else set())

def set_bright(v):
    try:
        with open(BACKLIGHT, "w") as f:
            f.write(str(v))
    except Exception as e:
        print(f"brightness write failed: {e}", flush=True)

def get_bright():
    try:
        with open(BACKLIGHT, "r") as f:
            return int(f.read().strip())
    except Exception:
        return None

def open_devices():
    devs = []
    for path in list_devices():
        try:
            dev = InputDevice(path)
            if any(k in dev.name for k in WATCH_NAMES):
                devs.append(dev)
                print(f"watching: {dev.name} ({dev.path})", flush=True)
        except Exception:
            pass
    return devs

def main():
    if not HAVE_EVDEV:
        print("python3-evdev 未安装：息屏守护不启动，屏幕保持常亮。\n"
              "安装后重启服务即可启用：apt install python3-evdev && "
              "systemctl restart screen-idle", flush=True)
        return 0

    last_activity = time.time()
    screen_on = True
    devs = open_devices()
    if not devs:
        print("NO WATCHABLE DEVICES", flush=True)
        # 退化为仅定时息屏
        while True:
            time.sleep(IDLE_SEC)
            set_bright(BRIGHT_OFF)

    # 用 select 多路复用读按键，不阻塞
    fds = {dev.fd: dev for dev in devs}

    while True:
        r, _, _ = select.select(list(fds.keys()), [], [], POLL)
        for fd in r:
            dev = fds[fd]
            try:
                for event in dev.read():
                    if event.type == ecodes.EV_KEY and event.value == 1:  # key down
                        is_power = event.code == ecodes.KEY_POWER
                        is_wake = event.code in WAKE_CODES
                        if is_power or is_wake:
                            print(f"keydown code={event.code} name={ecodes.KEY.get(event.code, '?')}", flush=True)
                            last_activity = time.time()
                            # 电源键: 亮则关(手动息屏)，息则亮(唤醒)
                            if is_power:
                                if screen_on:
                                    set_bright(BRIGHT_OFF)
                                    screen_on = False
                                    print("power: manual off", flush=True)
                                else:
                                    set_bright(BRIGHT_ON)
                                    screen_on = True
                                    print("power: wake", flush=True)
                            # 音量键: 仅唤醒
                            elif not screen_on:
                                set_bright(BRIGHT_ON)
                                screen_on = True
                                print("woke up", flush=True)
            except (OSError, IOError):
                pass

        # 空闲检查
        if screen_on and (time.time() - last_activity) > IDLE_SEC:
            set_bright(BRIGHT_OFF)
            screen_on = False
            print("idle, screen off", flush=True)

if __name__ == "__main__":
    main()
