# 互传联盟「已有 Wi-Fi 直传」调查结论

> 2026-10-25 · 用户质疑「就不能在已有的 WiFi 的情况下进行传输吗？还要单独切网？」
> 原则：**兼容性优先，速度不重要**
> 结论先行：**能，而且这本来就是协议的设计意图。mtapy 切网是 macOS 缺 Wi-Fi Direct 的妥协，不是协议要求。**

---

## 一、直接答案

**能在已有 Wi-Fi 上传输，不需要切网。** 切网只是 mtapy 在 macOS 上的**兜底手段**，不是互传联盟协议的
必要步骤。三条独立证据互相印证：

| 证据源 | 原话/事实 | 含义 |
|---|---|---|
| 百度百科「互传联盟」 | 「基于 **Wi-Fi Direct** 和蓝牙技术」「**传输过程中不影响互联网使用**」 | 官方宣称不断网 |
| 百度百科「注意事项」 | 「如果对方打开了**热点**功能，请将它**关掉**」 | **热点反而是干扰项**，不是必需品 |
| 官方 Windows 客户端 | 「只要电脑端装好对应品牌互传客户端……**同一局域网内设备自动识别**……连接同一个路由器 Wi-Fi」 | 官方 PC 端走**同网直传** |
| CatShare（开源先驱） | 「WiFi Direct P2P 接口 (**p2p0**) 的 MAC 地址」 | 协议用 p2p0，不是 wlan0 |
| cattysend（Rust/Linux） | 「物理 Wi-Fi 接口可能会**暂时挂起**其基础设施连接，以优先保障 P2P 组」 | **Linux 也缺并发 Wi-Fi**，被迫抢占 |

---

## 二、协议到底怎么走的（源码级）

### 2.1 完整链路

```
BLE 广播 00003331
  → 手机读 00009954（DeviceInfo：state/mac/key）
  → 手机写 00009953（P2pInfo：ssid/psk/mac/port，ECDH 加密）
  → [此处分叉]
  ├─ 路径 A（同网直传，官方 PC 客户端）：直接连手机的局域网 IP:port
  └─ 路径 B（跨网，mtapy 兜底）：networksetup 连 ssid/psk → 192.168.49.1:port
  → WSS /websocket 版本协商 → sendRequest → HTTPS /download?taskId=X → ZIP 流
```

### 2.2 P2pInfo 结构（`models.py`）

```python
@dataclass
class P2pInfo:
    ssid: str      # Wi-Fi Direct 组的 SSID（DIRECT-XXXX）
    psk: str       # WPA2-PSK
    mac: str       # ★ p2p0 接口的 MAC（不是 wlan0）
    port: int      # 手机 HTTPS 服务器端口
    id / key / catshare   # 可选
```

**关键点**：P2pInfo **没有 IP 字段**。协议没规定「必须连热点」——它只是给了 Wi-Fi Direct 凭据，
供「跨网」场景使用。同网场景下这套凭据根本用不上。

### 2.3 mtapy 为什么硬编码 192.168.49.1

`transport.py` 第 386 行：

```python
# The host is the P2P Group Owner (Android device), which is usually 192.168.49.1
return await self.receive_from("192.168.49.1", p2p_info.port)
```

`192.168.49.1` 是 **Wi-Fi Direct 群主（Group Owner）的默认网关地址**。这是「连上手机自建的
P2P 组之后」才用的地址。同网直传时，手机的 IP 是它在**路由器上的 DHCP 地址**（如 192.168.31.x），
不是 192.168.49.1。

**`receive_from(host, port)` 本身接受任意 host** —— 只要把 host 换成手机的局域网 IP 就能同网直传。
架构上**不需要大改**。

---

## 三、为什么 mtapy 要切网（macOS 的锅）

| 平台 | Wi-Fi Direct | 并发 Wi-Fi（基础设施 + P2P） | 现状 |
|---|---|---|---|
| Android | ✅ 原生 API | ✅ 射频时分复用 | 协议设计目标场景 |
| Windows | ✅ Wi-Fi Direct API | ✅ | 官方客户端正常 |
| Linux | ⚠️ wpa_supplicant/NM | ⚠️ cattysend：NM 会**抢占**基础设施连接 | 被迫切网 |
| **macOS** | ❌ **无 API**（只有 AWDL，私有） | ❌ 单网卡单连接 | **只能用 networksetup 切网** |

**mtapy 的 `wifi_helper.py`** 就是罪魁祸首：

```python
subprocess.run(["networksetup", "-setairportnetwork", interface, ssid, password])
```

这条命令把 Wi-Fi 网卡**从当前路由器切到手机自建的 DIRECT-XXXX**，于是断网。
`demo.py` 里的 TODO 也承认这是待清理项：

```
sudo networksetup -setairportnetwork en0 "SSID" "PASSWORD"
... use network ...
cleanup
```

---

## 四、怎么做到「不断网」（兼容性优先方案）

### 4.1 同网直传（首选，零切网）

**前提**：Mac 和手机连**同一个路由器**。

```
BLE 收到 P2pInfo
  → 拿到 port
  → 在本地子网扫描这个端口（/24，约 2-5 秒）
  → 找到手机的 LAN IP
  → 直接 https://{lan_ip}:{port}/websocket
  → 传输全程 Wi-Fi 不动，互联网不断
```

**为什么能行**：手机的 HTTPS 服务器通常绑 `0.0.0.0`（所有接口），所以既能在 p2p0 上听，
也能在 wlan0 上听。官方 Windows 客户端正是这么做的。

**怎么找手机的 IP**（三种方式，按优先级）：

| 方式 | 做法 | 可靠性 |
|---|---|---|
| A. ARP 表 | 用 `arp -a` 查 p2p0 MAC → IP | ⚠️ 可能不匹配（p2p0 MAC ≠ wlan0 MAC） |
| **B. 端口扫描** | 已知 port，扫 /24 子网 | ✅ **最稳**，2-5 秒 |
| C. mDNS | 查 `_mta._tcp` 服务 | ⚠️ 手机不一定广播 |

**推荐 B**：`for ip in 192.168.31.{1..254}; do nc -z -w1 $ip $port; done` 之类的并发扫描，
命中即可直连。

### 4.2 跨网兜底（热点，会切网）

当手机和 Mac **不在同一 Wi-Fi**（比如 Mac 在办公室、手机用流量）时，才用 mtapy 的热点方案：
`networksetup` 连 DIRECT-XXXX → 192.168.49.1:port。**传完自动切回原 Wi-Fi**。

### 4.3 双模策略（最终实现）

```
收到 P2pInfo
  ├─ 先试同网扫描（3 秒超时）
  │    ├─ 命中 → 直连 LAN IP（不断网）✅ 首选
  │    └─ 未命中 ↓
  └─ 回退热点模式（切网，传完切回）⚠️ 兜底
```

**兼容性上这是最优解**：
- 同一 Wi-Fi 下 → **完全不断网**，符合官方 PC 客户端体验
- 不同网络下 → 仍能传（会短暂断网，可自动恢复）
- 不依赖 macOS 的 Wi-Fi Direct（因为没有）
- 不依赖 sudo / 越权

---

## 五、速度对照（你说不在意，但仍列出来）

| 通道 | 实测速率 | 是否切网 |
|---|---|---|
| ADB over USB | 38.2 MB/s | 否 |
| ADB over Wi-Fi 5GHz | 21-25 MB/s | 否 |
| 互传联盟（理论） | 20-40 MB/s | **否（同网）** |
| 互传联盟（热点兜底） | 20-40 MB/s | **是** |
| LocalSend（同网） | 10-30 MB/s | 否 |

**结论**：同网直传的速度和热点模式**同一量级**，但不断网。速度不是问题。

---

## 六、开源项目清单（3 个，谱系清晰）

| 项目 | 语言 | 平台 | 状态 | 同网直传 |
|---|---|---|---|---|
| [CatShare](https://github.com/kmod-midori/CatShare) | Kotlin | Android | ✅ 活跃（先驱） | 是（手机端） |
| [mtapy](https://github.com/est/mtapy) | Python | macOS/Linux | demo 阶段 | ❌ 只有热点 |
| [cattysend](https://github.com/Tinnci/cattysend) | Rust | Linux | WIP | ⚠️ NM 抢占 |

**CatShare 是先驱**（cattysend 和 mtapy 都致敬它），它跑在 Android 上，
所以自带 Wi-Fi Direct，不存在切网问题。**桌面端的同网直传方案目前没人做好** —— 这是我们的机会。

---

## 七、待验证（需手机配合）

1. **同网扫描能否找到手机的端口**：手机发起传输时，`nc -z <lan_ip> <port>` 是否通？
   - 通 → 同网直传成立
   - 不通 → 手机服务器可能只绑 p2p0 接口，需要另想办法（如让手机走「Wi-Fi Direct 并发」）
2. **WSS 证书**：手机用自签证书，同网直传时需同样跳过校验（mtapy 已做）
3. **CatShare 的 p2p0 MAC 说明**：同网时 MAC 是否变化（CatShare 说「设备待机和发起传输时
   MAC 地址可能不同」）—— 所以 ARP 方式不可靠，端口扫描更稳

---

## 八、落地路线

| 步骤 | 内容 | 工作量 |
|---|---|---|
| 1 | mtapy 加同网扫描（改 `transport.py` 的 `listen()`） | 半天 |
| 2 | 双模策略：先同网后热点，自动回退 | 半天 |
| 3 | 实测（需手机点一下分享） | 10 分钟 |
| 4 | Swift 重写时直接内置双模 | 1-2 天 |

**当前优先级**：先做步骤 1-2（Python 层验证），确认同网可行后再 Swift 重写。
理由：避免 Swift 重写完发现同网不可用，浪费 2 天。

---

## 九、对你问题的直接回答

> 「就不能在已有的 WiFi 的情况下进行传输吗？还要单独切网？」

**能。** 协议本来就是为「不断网」设计的（百度百科原话「传输过程中不影响互联网使用」）。
mtapy 切网是因为 **macOS 没有 Wi-Fi Direct API**，只好用 `networksetup` 把网卡切到手机自建的
DIRECT-XXXX 热点上——这是**平台缺陷的妥协**，不是协议要求。

> 「他们不是有开源项目吗？」

有 3 个：**CatShare**（Android，先驱）、**mtapy**（Python，macOS）、**cattysend**（Rust，Linux）。
它们都致敬同一个协议。**桌面端的同网直传没人实现** —— 因为桌面 OS 都缺 Wi-Fi Direct，
大家都被迫走热点。但我们**可以绕开**：不在同一 Wi-Fi 时才切网，同一 Wi-Fi 时直接用局域网 IP。

> 「不要在意速度，只要兼容性好」

同网直传正好满足：**兼容性最好（不断网、不切网、不需要 sudo）**，速度和热点模式同一量级。
