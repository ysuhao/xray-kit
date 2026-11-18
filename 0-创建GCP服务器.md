# 任务零：在 Google Cloud 上开一台服务器，然后部署成节点

> **给人看的（一句话用法）**
> 把整个 `xray-kit` 文件夹交给能执行命令的 AI 助手，对它说：
> 「读 `0-创建GCP服务器.md`，照着做。」
> 它会帮你装好 gcloud、开一台 GCP 服务器、放行端口，然后接着按 `1-部署节点.md` 部署好节点，最后交给你一个 `clash-mi-名字.yaml`。
> 中途会请你在浏览器里登录一次 Google 账号。

---

## 以下是给 AI 助手的说明

你要做的事：用 `gcloud` 命令行在用户的 Google Cloud 项目里创建一台 Debian 12 服务器，放行代理端口，配置好 SSH 密钥登录，然后**接着执行 `1-部署节点.md`**，把它部署成节点。整个过程都用下面给出的命令，不要去网页控制台点。

### 第 0 步：向用户确认这几项（缺什么问什么）

1. **地区**。不确定就用 `us-west1`（俄勒冈）。可选：

   | 地区代码 | 位置 | 说明 |
   |---|---|---|
   | `us-west1` | 美国俄勒冈 | 免费套餐地区，默认推荐 |
   | `us-central1` | 美国艾奥瓦 | 免费套餐地区 |
   | `us-east1` | 美国南卡 | 免费套餐地区 |
   | `asia-east1` | 台湾 | 离大陆近，延迟低，不在免费套餐内 |
   | `asia-northeast1` | 东京 | 离大陆近，不在免费套餐内 |

   每个结算账号可以免费用 1 台 e2-micro，条件是放在上表前三个地区，并且使用 30 GB 以内的 `pd-standard` 磁盘。

2. **节点名字**：显示在 Clash Mi 里，比如 `GCP俄勒冈`。服务器名用英文小写，比如 `xkit-node`。
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

登录这一步要**请用户自己完成**：运行下面这条命令，浏览器会打开 Google 登录页，由用户登录并点「允许」。不要替用户输入账号密码。

```bash
gcloud auth login
```

登录后确认账号：

```bash
gcloud auth list
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

如果 `gcloud billing accounts list` 输出为空，说明用户还没有结算账号。请用户打开 https://console.cloud.google.com/billing 绑一张卡（新用户会送试用额度）。等用户说办好了，再继续。

开启 Compute Engine 接口（第一次大约要 1 分钟）：

```bash
gcloud services enable compute.googleapis.com
```

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

免费套餐地区（`us-west1` / `us-central1` / `us-east1`）用这条，区域填 `地区-b`，例如 `us-west1-b`：

```bash
gcloud compute instances create xkit-node --zone us-west1-b \
  --machine-type e2-micro --image-family debian-12 --image-project debian-cloud \
  --boot-disk-size 30GB --boot-disk-type pd-standard --network-tier STANDARD \
  --tags xkit-node --metadata-from-file ssh-keys=gcp-ssh-keys.txt
```

其他地区把 `--machine-type` 换成 `e2-small`，`--boot-disk-size` 换成 `10GB`，其余参数不变。

- `--network-tier STANDARD`：用标准网络层。每个结算账号每月有 200 GiB 免费出站流量。如果报这个地区不支持 STANDARD，就去掉这个参数重试，改用默认的高级网络层。
- 如果报 `ZONE_RESOURCE_POOL_EXHAUSTED`（这个区域机器卖完了），把 `-b` 换成 `-a` 或 `-c` 再试。

命令输出里的 `EXTERNAL_IP` 就是服务器 IP。之后也可以用这条命令再查：

```bash
gcloud compute instances describe xkit-node --zone 区域 --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
```

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

### 做链式出口（可选）

要再开一台 GCP 服务器当出口，配合 `2-链式出口.md` 使用：

```bash
gcloud compute firewall-rules create xkit-exit --network default --direction INGRESS \
  --target-tags xkit-exit --allow tcp:40000-60000 --source-ranges 第一台的IP/32

gcloud compute instances create xkit-exit --zone 区域 \
  --machine-type e2-small --image-family debian-12 --image-project debian-cloud \
  --boot-disk-size 10GB --network-tier STANDARD \
  --tags xkit-exit --metadata-from-file ssh-keys=gcp-ssh-keys.txt
```

然后按 `2-链式出口.md` 操作：A 是第一台，B 是这台，两台的用户都是 `xkit`。注意免费的 e2-micro 每个结算账号只有 1 台，这台要按 e2-small 计费。

### 告诉用户

1. 服务器名、地区、IP。
2. Clash Mi 文件的位置和导入方法（见 `1-部署节点.md` 第 5 步）。
3. 费用：
   - 免费地区的 e2-micro 机器本身免费。
   - 外网 IP 按小时收费，每小时 0.005 美元，一个月大约 3.6 美元。
   - 标准网络层每月 200 GiB 免费出站流量，超出部分按流量计费；看视频、下载会很快用掉这部分。
   - 账单在 https://console.cloud.google.com/billing 查看。
4. 重启服务器 IP 不变。**关机（stop）再开机，IP 会变**，这时在服务器上重跑一次 `sudo bash ~/xray-kit.sh install`，再取回新的 `clash-mi.yaml` 重新导入。
5. 不用了就删掉，删除后不再计费：

   ```bash
   gcloud compute instances delete xkit-node --zone 区域 --quiet
   gcloud compute firewall-rules delete xkit-node --quiet
   ```

   做过链式的，把 `xkit-exit` 机器和防火墙规则也按同样的方法删掉。

### 规矩

- 只创建上面列出的资源（`xkit-node`、`xkit-exit` 两台服务器和同名防火墙规则）。不要修改、删除用户项目里已有的服务器、防火墙规则、磁盘和 IP。
- 登录 Google、绑定银行卡这两件事都由用户自己在浏览器里完成。
- `gcp-ssh-keys.txt` 里只有公钥，可以留着；私钥 `~/.ssh/id_ed25519` 不要发给任何人，也不要上传到任何地方。
- 某条命令报错、而上面又没写怎么处理时，停下来，把完整报错给用户看。
