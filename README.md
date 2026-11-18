# xray-kit

把这个仓库交给任何一个能执行命令的 AI 助手（Kimi CLI、Qwen Code、DeepSeek 接入的 Cline / Cursor / Trae 等），一句话就能：

1. **部署一台节点**：Xray，VLESS-Reality（TCP 443）+ Hysteria2（UDP 443，Salamander 混淆，UDP 30000-39999 端口跳跃），输出一份写好规则的 **Clash Mi** 配置。
2. **加一台出口机做链式代理**：默认流量 你 → 节点 → 出口机（比如住宅 IP）→ 网站；视频、下载这类大流量从节点直接出，不绕路。

配置全部由脚本生成，AI 只负责上传、运行、取回文件，换哪家模型结果都一样。

## 用法

下载本仓库（右上角 Code → Download ZIP，或 `git clone`），在这个文件夹里打开你的 AI 助手，对它说：

**还没有服务器：在 Google Cloud 上开一台**

```
读 0-创建GCP服务器.md，照着做。
```

AI 会装好 gcloud（中途请你在浏览器里登录一次 Google 账号），按免费套餐开一台 Debian 12（e2-micro、30 GB 标准磁盘、标准网络层，地区俄勒冈），放行端口，然后接着部署节点，装上每月 195 GiB 流量上限（到量停 Xray，下月自动恢复，不产生流量费），最后交给你 Clash Mi 配置。

**第一步：部署节点（已有服务器）**

```
读 1-部署节点.md，照着做。服务器 IP 是 1.2.3.4，SSH 端口 22，用户 root，私钥是 ~/.ssh/id_ed25519。节点名字叫 洛杉矶。
```

AI 会把 `clash-mi-洛杉矶.yaml` 放到这个文件夹里，导入 Clash Mi 即可。

**第二步：接一台出口机（链式）**

```
读 2-链式出口.md，照着做。第一台 A：IP 1.2.3.4，端口 22，root，私钥 ~/.ssh/id_ed25519。出口 B：IP 5.6.7.8，端口 22，root，同一把私钥。B 的名字叫 住宅。
```

完成后得到新的 `clash-mi-链式.yaml`，里面有两条线路：

| 线路 | 普通流量 | 大流量（视频 / 下载） |
|---|---|---|
| 洛杉矶→住宅 | 从 B 出 | 从 A 出 |
| 洛杉矶直出 | 从 A 出 | 从 A 出 |

## 不用 AI，自己跑

在服务器上（root）：

```bash
curl -fsSLO https://raw.githubusercontent.com/ysuhao/xray-kit/main/xray-kit.sh

# 第一台：部署节点，配置在 /root/xray-kit/clash-mi.yaml
bash xray-kit.sh install --name 洛杉矶

# 第二台：部署出口，只接受第一台连接，最后一行输出 XKIT1: 开头的口令
bash xray-kit.sh exit --relay-ip 第一台的IP --name 住宅

# 回到第一台：接上出口，重新生成 clash-mi.yaml
bash xray-kit.sh chain 'XKIT1:……'
```

其他命令：

| 命令 | 作用 |
|---|---|
| `bash xray-kit.sh test` | 自检：在服务器上模拟客户端，逐条线路核对出口 IP |
| `bash xray-kit.sh show` | 再看一次汇总和文件位置 |
| `bash xray-kit.sh unchain` | 拆掉链式，全部恢复从第一台出 |

参数：`--name` 节点名，`--sni` 指定 Reality 伪装站（默认自动挑一个支持 TLS1.3 + H2 的），`--port` 指定端口（install 时是 Reality 端口，exit 时是出口端口，默认随机 40000-60000）。

脚本可以反复运行，已有的密码和密钥保持不变，发出去的配置一直有效。

## 分流规则

**节点上（链式之后）**

- 从节点直接出：YouTube、Twitch、Vimeo、Spotify、SoundCloud、Steam / Epic / 主机平台下载、Apple 和 Windows 更新、Google 下载、Google Drive、Colab、GitHub、Docker、HuggingFace、npm、PyPI、Dropbox、OneDrive、MEGA、测速网站。
- 其余全部从出口机出：Google 搜索和账号、ChatGPT / Claude / Gemini 等 AI、Netflix、Disney+、TikTok、支付网站等。
- 出口机断线时链式线路直接断开，IP 不会悄悄变成节点的；这时切到「直出」。
- 出口机只接受节点 IP 的连接，其他来源一律静默丢弃。

**Clash Mi 配置里**

- 国内网站和 App（微信、QQ、支付宝、银行、B 站、抖音等）直连。
- DNS 全部加密：国内域名走国内 DoH，其余经代理远程解析。
- IPv6 全部丢弃，浏览器 UDP 不直连，防止 DNS 和 WebRTC 暴露真实 IP。
- AI 网站强制 TCP。
- 节点里 HY2 优先，HY2 不通自动切 Reality。

## 导入 Clash Mi

1. 「配置 / 订阅」→ 从文件导入 yaml。
2. 覆写方式选 **「内置-不覆写」**，关掉 **TUN 覆写**，配置里自带的 DNS 和 TUN 才会生效。
3. 打开 TUN，在「🚀 节点选择」里选线路。

服务商控制台的安全组需要放行：节点 TCP 443、UDP 443、UDP 30000-39999；出口机放行它的出口端口。

## 文件

| 文件 | 内容 |
|---|---|
| `xray-kit.sh` | 全部逻辑：装 Xray、生成密钥和证书、写配置、端口跳跃、BBR、防火墙放行、自检、生成 Clash Mi 配置 |
| `0-创建GCP服务器.md` | 给 AI 的说明：用 gcloud 开 GCP 服务器、放行端口，再接着部署节点 |
| `gcp-egress-cap.sh` | GCP 每月出站流量上限：每分钟统计，到 195 GiB 停 Xray（或 `--action poweroff` 关机），下月自动恢复 |
| `1-部署节点.md` | 给 AI 的第一步操作说明 |
| `2-链式出口.md` | 给 AI 的第二步操作说明 |

## 环境

Debian 11+ / Ubuntu 20.04+，root 或有 sudo 的用户，服务器能访问 GitHub。脚本只管理自己的文件：`/usr/local/etc/xray/`、`/root/xray-kit/`、`xray-kit-*.service`、nft 表 `xray_kit_*`。

已在 Debian 12 + Xray 26.11.9 上完整跑通：由 Kimi CLI 只读这两份说明，独立完成部署、链式、重启和撤回，再用 Clash Mi 配置从外部逐条验证分流。
