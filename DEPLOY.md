# 出站流量监控（mitmproxy 透明代理）部署文档

> 场景：监控本机所有程序向外部发出的 HTTP/HTTPS 请求，完整记录并可在网页实时查看，支持自动修改请求头。
> 本仓库 = 当前正在运行的整套配置的存档，重装系统后照此恢复。

---

## 0. 目录文件说明

| 文件 | 说明 |
|---|---|
| `deploy.sh` | 一键部署脚本（在全新 Ubuntu 24.04 上自动完成所有步骤） |
| `mitmweb.service` | systemd 服务单元文件（已含所有启动参数） |
| `autopatch.py` | mitmproxy 插件：自动修改请求头（当前为 opencode UA 规则） |
| `90-mitmproxy.conf` | sysctl 内核转发配置 |
| `DEPLOY.md` | 本文档 |

备份方式：把这整个目录拷走即可（例如 `scp -r monitor-outbound 新机器`）。

---

## 1. 架构与原理

```
 本机任意程序(A)                 mitmproxy(系统服务)             目标服务器(B)
 ───────────────                ──────────────────             ──────────────
 A 连接 B:443
    │
    ▼
 iptables OUTPUT 链(仅 A 用户, 排除代理自身用户)
    │  NAT REDIRECT -> 127.0.0.1:8082
    ▼
 mitmweb 接收 -> 用系统CA伪造证书 -> MITM解密
    │  1. 记录完整内容(落盘 flows.json)
    │  2. 插件 autopatch.py 按规则自动改请求头
    │  3. 转发给真正的目标 B:443
    ▼
 浏览器打开 http://<本机IP>:8083  实时查看/编辑/重放
```

关键点：**为什么要独立用户 + `-m owner` 排除** —— 若不过滤掉代理自己，代理向目标服务器发起的新连接会再次被 REDIRECT 回自身，形成无限循环。

---

## 2. 环境要求

- Ubuntu 24.04 x86_64（20.04+ 均可，命令大同小异）
- root 权限
- 端口占用检查：确认 `8082`、`8083` 空闲（本机原方案曾因 8080 被其他项目占用而换用 8082/8083）

```bash
ss -tlnp | grep -E "8082|8083"   # 无输出即空闲
```

---

## 3. 快速部署（推荐）

```bash
# 上传本目录到新机器后
sudo bash deploy.sh
```

脚本自动完成：装依赖 → 建用户 → sysctl → systemd 服务 → 生成 CA → 信任 CA → iptables 规则 → 持久化 → 防火墙。结束后按提示访问网页界面即可。

---

## 4. 手动部署（逐步，供理解/排错）

### 4.1 安装
```bash
apt-get update
apt-get install -y mitmproxy iptables-persistent
```

### 4.2 创建专用用户（防代理自循环）
```bash
useradd --create-home --shell /bin/bash mitmproxyuser
```

### 4.3 sysctl 转发
```bash
cp 90-mitmproxy.conf /etc/sysctl.d/mitmproxy.conf
sysctl --system
```

### 4.4 部署 systemd 服务
```bash
mkdir -p /etc/mitmweb /var/lib/mitmweb
cp autopatch.py /etc/mitmweb/autopatch.py
cp mitmweb.service /etc/systemd/system/mitmweb.service
chown -R mitmproxyuser:mitmproxyuser /var/lib/mitmweb
systemctl daemon-reload
systemctl enable --now mitmweb
```
启动参数解释（见 `mitmweb.service`）：
- `--mode transparent` 透明模式，无需程序配置代理
- `--listen-host 127.0.0.1 --listen-port 8082` 代理只在本机 8082
- `--web-host 0.0.0.0 --web-port 8083` 网页界面开放给局域网
- `--scripts /etc/mitmweb/autopatch.py` 加载自动改头插件
- `--set block_global=false` 允许连接公网 IP（透明模式必需）
- `--set save_stream_file=+/var/lib/mitmweb/flows.json` 流量实时追加落盘
- `AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN` 非 root 用户读取被劫持连接原始目标地址所需

### 4.5 信任 CA 证书（HTTPS 解密关键）
```bash
cp /home/mitmproxyuser/.mitmproxy/mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/mitmproxy-ca.crt
update-ca-certificates
```

### 4.6 iptables 透明劫持（IPv4 + IPv6）
```bash
iptables -t nat -A OUTPUT -p tcp -m owner ! --uid-owner mitmproxyuser --dport 80  -j REDIRECT --to-port 8082
iptables -t nat -A OUTPUT -p tcp -m owner ! --uid-owner mitmproxyuser --dport 443 -j REDIRECT --to-port 8082
ip6tables -t nat -A OUTPUT -p tcp -m owner ! --uid-owner mitmproxyuser --dport 80  -j REDIRECT --to-port 8082
ip6tables -t nat -A OUTPUT -p tcp -m owner ! --uid-owner mitmproxyuser --dport 443 -j REDIRECT --to-port 8082
```
> 加入规则的瞬间，本机 80/443 出站即被接管；若此时 mitmweb 未运行，网络会不可用。紧急恢复：`iptables -t nat -F`

### 4.7 网页界面防火墙（无内置账号密码，必须限制来源）
```bash
iptables -I INPUT 1 -p tcp --dport 8083 -s 127.0.0.1 -j ACCEPT
iptables -A INPUT -p tcp --dport 8083 -s 192.168.1.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 8083 -j DROP
```
> `192.168.1.0/24` 换成你实际的局域网网段。如需 tailscale 访问，追加：`iptables -A INPUT -p tcp --dport 8083 -s 100.64.0.0/10 -j ACCEPT`（放在 DROP 之前）。

### 4.8 持久化
```bash
netfilter-persistent save   # 保存 iptables（v4+v6）
```
sysctl 已随 4.3 持久化，systemd 服务随 4.4 开机自启。

---

## 5. 验证部署

```bash
systemctl is-active mitmweb          # 应为 active
ss -tlnp | grep -E "8082|8083"       # 两个端口在监听

# 触发真实请求（会被透明劫持并记录）
curl -s -o /dev/null -w "%{http_code}\n" https://www.baidu.com   # 返回 200

# 查看是否已被记录（从 mitmweb API 拉取流量列表）
curl -s http://127.0.0.1:8083/flows | python3 -m json.tool | head -20
```

---

## 6. 日常使用

### 6.1 查看流量
- **局域网内**：浏览器打开 `http://<本机IP>:8083`，实时列表，点任一条看完整请求/响应，可搜索筛选。
- **远程/外出**：SSH 隧道后本机访问
  ```bash
  ssh -L 8083:127.0.0.1:8083 用户@服务器
  # 浏览器打开 http://localhost:8083
  ```
- **命令行翻历史**：
  ```bash
  mitmdump -n -r /var/lib/mitmweb/flows.json | tail
  ```

### 6.2 查看/修改自动改头规则
```bash
vim /etc/mitmweb/autopatch.py
systemctl restart mitmweb
```
当前规则（`autopatch.py`）：
- 只匹配 `opencode.ai` 的 `/zen/v1/chat/completions`
- 若请求 User-Agent 不含 `opencode`，则统一替换为：
  `opencode/1.17.13 ai-sdk/provider-utils/4.0.23 runtime/bun/1.3.14`
- 其它请求一律不碰

### 6.3 界面里的 Edit / Replay
- **Edit**：把选中请求改成可编辑状态，可改请求头/URL/请求体，保存后点 **Replay** 原样重发。
- **Replay**：把请求原样再发一次（POST/下单类请求重放有副作用，慎点）。
- 与插件 `autopatch.py` 的区别：插件是**所有匹配请求自动改**，Edit+Replay 是**手动改一条再发**。

---

## 7. 运维维护

### 7.1 流量日志会无限增长
`/var/lib/mitmweb/flows.json` 实测一天可达数百 MB。建议定时清理（保留最近 N 天）：
```bash
# 每周日凌晨 3 点轮转：停服->改名->重启->删7天前
cat > /etc/systemd/system/mitmweb-rotate.service <<'EOF'
[Unit]
Description=Rotate mitmweb flows

[Service]
Type=oneshot
ExecStartPre=/usr/bin/systemctl stop mitmweb
ExecStart=/bin/mv /var/lib/mitmweb/flows.json /var/lib/mitmweb/flows-$(date +\%Y\%m\%d).json
ExecStartPost=/usr/bin/systemctl start mitmweb
ExecStartPost=/bin/bash -c 'find /var/lib/mitmweb -name "flows-*.json" -mtime +7 -delete'
EOF
cat > /etc/systemd/system/mitmweb-rotate.timer <<'EOF'
[Unit]
Description=Weekly rotate mitmweb flows

[Timer]
OnCalendar=Sun 03:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload && systemctl enable --now mitmweb-rotate.timer
```

### 7.2 彻底停用监控
```bash
systemctl disable --now mitmweb
iptables -t nat -F                    # 清空 NAT（恢复直连，不影响其他服务规则则按需重加）
netfilter-persistent save
```

---

## 8. 已知限制（重要）

1. **Docker 容器**的流量走桥接转发路径，不经过本机 OUTPUT 链，**默认抓不到**。容器需用 `docker run --network host` 才会被监控。
2. **锁定证书（cert pinning）**的程序（如部分 SDK/客户端）无法 MITM，只能看到目标域名、看不到内容，且这类程序可能因证书不匹配而报错。
3. **DNS 查询**（UDP 53）不记录；非 80/443 端口出站不记录。
4. HTTPS 解密依赖"程序信任系统 CA"这一前提，未信任系统 CA 的静态编译程序解密不了。
5. 重装后 mitmproxy 会**重新生成新 CA**（属正常）。若需要旧流量文件的历史数据，`flows.json` 内容可继续用 `mitmdump -r` 读取，不依赖旧 CA。

---

## 9. 排错速查

| 现象 | 检查 |
|---|---|
| 加规则后所有网络不通 | mitmweb 没起来；先 `systemctl start mitmweb`，或 `iptables -t nat -F` 紧急恢复 |
| HTTPS 显示 "证书错误" | CA 未装入系统：重跑 4.5；或该程序 cert pinning（见 8） |
| 网页界面打不开 | 检查来源 IP 是否在防火墙白名单；`iptables -L INPUT -n` 看 8083 规则 |
| 服务反复重启 | `journalctl -u mitmweb -n 50` 看日志；常见：端口被占（改端口）、插件语法错 |
| 想换端口 | 改 `mitmweb.service` 里的 8082/8083 + iptables 规则里的 `--to-port`，保持一致 |
