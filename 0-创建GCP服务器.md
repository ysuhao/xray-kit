# 任务零：在 Google Cloud 上开一台免费服务器，然后部署成节点

> **给人看的（一句话用法）**
> 把整个 `xray-kit` 文件夹交给能执行命令的 AI 助手，对它说：
> 「读 `0-创建GCP服务器.md`，照着做。」
> 它会帮你装好 gcloud，用 Google Cloud 免费套餐开一台服务器（e2-micro + 标准网络层），放行端口，然后接着按 `1-部署节点.md` 部署好节点，装上每月 195 GiB 的流量上限，最后交给你一个 `clash-mi-名字.yaml`。
> 中途会请你在浏览器里登录一次 Google 账号。

---

## 以下是给 AI 助手的说明

你要做的事：用 `gcloud` 命令行在用户的 Google Cloud 项目里，按**免费套餐**的规格创建一台 Debian 12 服务器，放行代理端口，配置好 SSH 密钥登录，然后**接着执行 `1-部署节点.md`**，把它部署成节点。整个过程都用下面给出的命令。

使用免费套餐的规格：

| 项目 | 取值 |
|---|---|
| 机器类型 | `e2-micro`（每个结算账号免费 1 台） |
| 地区 | `us-west1`（俄勒冈）、`us-central1`（艾奥瓦）、`us-east1`（南卡）三选一 |
| 磁盘 | `pd-standard`，30 GB |
| 网络层 | `STANDARD`（标准网络层，每个结算账号每月 200 GiB 免费出站流量） |

### 第 0 步：向用户确认这几项（缺什么问什么）

1. **地区**：上表三个里选一个，用户没要求就用 `us-west1`。
2. **节点名字**：显示在 Clash Mi 里，比如 `GCP俄勒冈`。
3. **用哪个 GCP 项目**：有就用现有的，没有就新建（见第 2 步）。

### 第 1 步：装好 gcloud 并登录

先检查 gcloud 是否已安装：

```bash
gcloud --version
```

没有的话按系统安装：

- Windows：`winget install --id Google.CloudSDK -e`，装完后重新打开终端
- macOS：`brew install --cask google-cloud-sdk`
- Linux：`curl -fsSL https://sdk.cloud.google.com | bash -s -- --disable-prompts`，然后运行 `exec -l $SHELL`

先看是否已经登录：

```bash
gcloud auth list
```

列表里有账号、并且前面带 `*` 就是已登录，直接跳到第 2 步。没有的话运行下面这条命令，浏览器会打开 Google 登录页，用户登录并点「允许」即可：

```bash
gcloud auth login
```

### 第 2 步：选项目，确认已开通结算

列出现有项目：

```bash
gcloud projects list
```

- **有项目**：问用户用哪一个，然后设为默认：`gcloud config set project 项目ID`
- **没有项目**：新建一个，项目 ID 要全球唯一，后面加几位随机数：

  ```bash
  gcloud projects create xkit-$RANDOM --name="xkit"
  gcloud config set project 刚才的项目ID
  ```

确认这个项目已经关联了结算账号（输出 `True` 才能开机器）：

```bash
gcloud billing projects describe 项目ID --format="value(billingEnabled)"
```

如果输出是 `False`：

```bash
gcloud billing accounts list
gcloud billing projects link 项目ID --billing-account=结算账号ID
```

如果 `gcloud billing accounts list` 输出为空，说明用户还没有结算账号（免费套餐也需要绑卡）。请用户打开 https://console.cloud.google.com/billing 绑一张卡，等用户说办好了再继续。

开启 Compute Engine 接口（第一次大约要 1 分钟）：

```bash
gcloud services enable compute.googleapis.com
```

查看这个项目里有没有已经在跑的 e2-micro：

```bash
gcloud compute instances list --format="table(name,zone.basename(),machineType.basename(),status)"
```

免费额度是**每个结算账号**一台 e2-micro。如果列表里已经有一台 e2-micro 在免费地区运行，或者用户说同一个结算账号下的其他项目里已经有一台，那么新开的这台会按量收费，把这一点告诉用户。

### 第 3 步：准备 SSH 密钥

检查本机有没有密钥，没有就生成一个：

```bash
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
```

（Windows PowerShell 里用 `Test-Path $env:USERPROFILE\.ssh\id_ed25519.pub` 检查，用 `ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\id_ed25519` 生成，遇到提示直接回车。）

把公钥写成 GCP 需要的格式，用户名用 `xkit`：

```bash
printf 'xkit:%s\n' "$(cat ~/.ssh/id_ed25519.pub)" > gcp-ssh-keys.txt
```

### 第 4 步：放行端口（云防火墙）

```bash
gcloud compute firewall-rules create xkit-node --network default --direction INGRESS \
  --target-tags xkit-node --allow tcp:443,udp:443,udp:30000-39999 --source-ranges 0.0.0.0/0
```

如果报 `already exists`，说明之前已经创建过，直接跳过这一步。

### 第 5 步：创建服务器

区域填 `地区-b`，例如 `us-west1-b`：

```bash
gcloud compute instances create xkit-node --zone us-west1-b \
  --machine-type e2-micro --image-family debian-12 --image-project debian-cloud \
  --boot-disk-size 30GB --boot-disk-type pd-standard --network-tier STANDARD \
  --tags xkit-node --metadata-from-file ssh-keys=gcp-ssh-keys.txt
```

如果报 `ZONE_RESOURCE_POOL_EXHAUSTED`（这个区域的机器卖完了），把 `-b` 换成 `-a` 或 `-c` 再试，地区保持不变。

命令输出里的 `EXTERNAL_IP` 就是服务器 IP。之后也可以用这条命令再查：

```bash
gcloud compute instances describe xkit-node --zone 区域 --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
```

某条命令报错、下面又没写怎么处理时，把完整报错交给用户。

### 第 6 步：等服务器启动，确认能登录

新机器启动大约需要 30～60 秒：

```bash
ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 xkit@服务器IP 'id; sudo -n true && echo SUDO_OK'
```

连不上就隔 15 秒再试，最多试 6 次。看到 `SUDO_OK` 就继续。

### 第 7 步：部署节点

打开 `1-部署节点.md`，从第 2 步开始照做，用到的信息如下：

- 服务器 IP：第 5 步拿到的 `EXTERNAL_IP`
- SSH 端口：22
- 用户：`xkit`（GCP 不能直接用 root 登录；它有免密 sudo，按 `1-部署节点.md` 里「登录用户不是 root」的写法操作）
- 私钥：`~/.ssh/id_ed25519`
- 节点名字：第 0 步定好的名字

云防火墙已经在第 4 步放行过了，不用再让用户去控制台操作。

这台服务器也可以作为 `2-链式出口.md` 里的第一台（A）；出口机（B）用另一家服务商的机器，比如住宅 IP。

### 第 8 步：装上每月 195 GiB 流量上限

标准网络层每月免费 200 GiB 出站流量。装上这个之后，服务器每分钟统计一次本月发出的流量，到 195 GiB 就停掉 Xray，下个月 1 号（美国太平洋时间）自动恢复，SSH 一直可以登录。

```bash
scp -i ~/.ssh/id_ed25519 gcp-egress-cap.sh xkit@服务器IP:gcp-egress-cap.sh
ssh -i ~/.ssh/id_ed25519 xkit@服务器IP 'sudo bash ~/gcp-egress-cap.sh'
```

看到 `✅ 流量上限已开启` 和一段本月用量就完成了。

- 用户想到量后整台关机：在安装命令后面加 `--action poweroff`。关机后外网 IP 会被收回，下次开机 IP 会变，需要用户去控制台手动开机。
- 用户想换上限：加 `--limit 数字`，单位 GiB。
- 200 GiB 是整个结算账号共用的。同一个结算账号下还有其他用标准网络层的机器时，按用户的情况把上限调小。

### 告诉用户

1. 服务器名、地区、IP。
2. Clash Mi 文件的位置和导入方法（见 `1-部署节点.md` 第 5 步）。
3. 费用：
   - e2-micro 机器和 30 GB 标准磁盘在免费额度内。
   - 标准网络层每月 200 GiB 免费出站流量；第 8 步装的上限会在 195 GiB 时停掉 Xray，不会产生流量费。在服务器上运行 `egress-cap` 可以看本月用量；当月想继续用，运行 `sudo egress-cap allow`（超出部分按流量计费）。
   - 外网 IP 不在免费额度内，每小时 0.005 美元，一个月大约 3.6 美元。
   - 账单在 https://console.cloud.google.com/billing 查看。
4. 重启服务器 IP 不变。**关机（stop）再开机，IP 会变**，这时在服务器上重跑一次 `sudo bash ~/xray-kit.sh install`，再取回新的 `clash-mi.yaml` 重新导入。
5. 不用了就删掉，删除后不再计费：

   ```bash
   gcloud compute instances delete xkit-node --zone 区域 --quiet
   gcloud compute firewall-rules delete xkit-node --quiet
   ```
