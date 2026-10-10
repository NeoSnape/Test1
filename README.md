# tee_check.sh — Android TEE 环境检测脚本

在手机上检测 TEE（可信执行环境）及相关安全环境，只读不改系统。

## 检测内容

| 节 | 内容 |
|---|---|
| 0 | 运行环境（root / Termux / adb） |
| 1 | 设备信息、SoC、Android 版本、首发 API |
| 2 | 启动验证 `verifiedbootstate`、BL 锁、Knox 熔断位；root 下与内核启动参数交叉校验（识别 resetprop 伪装） |
| 3 | 安全补丁级别及过期月数 |
| 4 | TEE 实现识别：Qualcomm QSEE、Trustonic Kinibi、Samsung TEEGRIS、Huawei iTrustee、OP-TEE、Google Trusty、Microtrust/Beanpod；StrongBox 芯片（Titan M、Qualcomm SPU） |
| 5 | Keymaster/KeyMint 版本、StrongBox、App Attest Key、设备 ID 证明、VINTF 中声明的安全 HAL、Binder 服务、RKP、keystore2 进程 |
| 6 | SELinux 状态 |
| 7 | su、Magisk / KernelSU / APatch / SUSFS、模块列表（高亮 TrickyStore / PIF / Shamiko 等）、TrickyStore keybox、dmesg TEE 日志 |
| 8 | 总结 |

## 使用方法

**Termux**
```sh
sh tee_check.sh            # 普通权限
su -c sh tee_check.sh      # root（推荐，结果最完整）
```

**MT 管理器 / 其他文件管理器**：选中脚本 → 执行（勾选 root 执行可获得完整结果）。

**电脑 adb**
```sh
adb push tee_check.sh /data/local/tmp/
adb shell sh /data/local/tmp/tee_check.sh
```

> 脚本放在 `/sdcard` 时不能直接 `./tee_check.sh`（存储挂载为 noexec），请用 `sh tee_check.sh`。

选项：`-n` 关闭颜色，`-o <文件>` 指定日志路径，`-h` 帮助。
日志默认保存到 `/sdcard/Download/tee_check_时间.log`（无颜色代码，方便发给别人）。

## 局限

Shell 只能判断 TEE 是否存在/运行及环境状态，**无法验证硬件证明证书链、keybox 是否被吊销**。
判断“TEE 损坏”或证明链是否可信，请配合 **Key Attestation**（vvb2060）等 App。
