# register-hysteria

Hysteria2 节点一键安装 + 自动注册。装完即跑，成功后把节点信息上报到注册中心。

## 用法

```bash
git clone  https://github.com/getthelostcode/register-hysteria.git
```

```bash
# 交互式（提示单独一行，输入内容正常回显）
./install.sh

# 非交互：位置参数 / --code / 环境变量 / 管道喂值 都行
./install.sh 4f13b9d93a8afb6e98283702
./install.sh --code 4f13b9d93a8afb6e98283702
CODE=4f13b9d93a8afb6e98283702 ./install.sh
printf '4f13b9d93a8afb6e98283702\n' | ./install.sh
```

常用开关：

| 开关 | 作用 |
|------|------|
| `--dry-run` | 只打印渲染后的 config.yaml 和将要上报的 JSON，不动系统 |
| `--register-only` | 服务已装好，只从现有配置重新上报（不重装、不重启） |
| `--verify-only` | 只做健康检查：服务状态 / UDP 端口 / trafficStats API |
| `--no-register` | 装完不上报 |
| `--no-download` | 不下载二进制（用已有 `HYSTERIA_BIN`） |
| `--traffic-port N` / `--secret HEX` | 覆盖随机值 |
| `--listen ADDR` | 覆盖监听（默认 `:443`） |
| `--version vX.Y.Z` | 指定 hysteria 版本（默认 v2.13.0） |
| `--force` | 版本相同也强制重下二进制 |
| `--gen-cert` | 强制重新生成证书对 `cert`/`key`（旧的自动备份为 `*.bak.<时间戳>`） |

环境变量：`HYSTERIA_ETC`、`HYSTERIA_BIN`、`HYSTERIA_SERVICE`、`SYSTEMD_UNIT_DIR`、
`MASQUERADE_DIR`、`HYSTERIA_LISTEN`、`HYSTERIA_VERSION`、`REG_API`、`PUBLIC_IP`、
`REG_PAYLOAD`、`AUTH_URL`。

## 脚本写入的值

模板：`config.yaml.example`（与本脚本同目录，装到 `/etc/hysteria/config.yaml.example`）。

| 字段 | 值 |
|------|----|
| `listen` | `':443'` |
| `tls.cert` / `tls.key` | `/etc/hysteria/cert.pem` / `key.pem`，由脚本自动生成（见下） |
| `obfs.salamander.password` | **运营商识别码**（客户端需一致） |
| `auth.http.url` | `AUTH_URL`，默认 `https://auth.ipx.sarl/auth`；改用面板鉴权就传 `https://hysteria.ipx.sarl/auth`（用户由面板 `/join/{code}` 注册） |
| `trafficStats.listen` | `0.0.0.0:<随机 10000-19000>`（自动避开已占用端口；重跑时复用旧值，旧值不在区间则重新随机） |
| `trafficStats.secret` | `openssl rand -hex 24`（重跑时复用旧值） |
| `masquerade.file.dir` | `/var/www/hysteria`（自动建目录 + index.html） |
| `bandwidth.up/down` | `100 mbps` |

其余字段（quic 等）原样保留。

面板鉴权示例：

```bash
AUTH_URL=https://hysteria.ipx.sarl/auth ./install.sh --code <运营商识别码>
```

用户登录名是注册时填的**邮箱**，密码就是他自己设的；面板 `/auth` 成功后返回该用户的 uuid，
流量统计与踢人都以这个 uuid 为准。

### 重跑（幂等）与重启时机

重跑 `install.sh` 时：

1. 旧配置先备份为 `config.yaml.bak.<时间戳>`
2. 写完新配置后用 `cmp` 与备份对比，算 sha256 打印出来
3. **配置写完后立刻 `systemctl restart hysteria-server`**，不等后续步骤——保证新值马上生效
4. 配置内容、二进制、systemd 单元**都没变**时跳过重启（不会平白断一次连接），日志写「配置未变更，跳过重启」

重启原因会打印在 `→ 重启 hysteria-server（配置变更 / 二进制更新 / systemd 单元变更）` 里。

## 证书（自动生成，不入库）

安装时脚本自动生成两个文件（仓库里**不含私钥**）：

| 文件 | 内容 |
|------|------|
| `/etc/hysteria/cert.pem` | 自签证书，EC P-256，10 年 |
| `/etc/hysteria/key.pem` | 对应私钥，权限 600 |

- SAN 自动带上：主机名、`localhost`、`127.0.0.1`、该节点探测到的公网 IP
- 已存在且配对就复用（重跑不会换证书）；缺失或不配对就重新生成
- `--gen-cert` 强制重生成，旧的备份为 `cert.pem.bak.<时间戳>`
- 想用固定证书：把 `cert`、`key` 两个文件放到 `install.sh` 同目录，脚本会直接装过去（覆盖自动生成）
- 客户端侧自签证书默认不信任：要么客户端 `tls.insecure: true`，要么把 `cert.pem` 作为 `ca` 下发，
  **或者用指纹固定**（推荐，安装时会自动上报给面板）

### 证书指纹（安装时自动计算并上报）

```bash
# hex（给人核对，面板里显示）
openssl x509 -in /etc/hysteria/cert.pem -noout -fingerprint -sha256
# base64(SHA256(DER))（= Hysteria 客户端 tls.pinSHA256）
openssl x509 -in /etc/hysteria/cert.pem -outform der | openssl dgst -sha256 -binary | base64 -w0
```

安装日志里会打印这两行，并随注册 payload 上报（`cert_sha256` / `cert_pin_sha256`）。
面板拿到 pin 后，生成的客户端配置就是 `tls.insecure: false` + `pinSHA256: <base64>`，
既不用信任自签 CA，也不用关掉证书校验。

查看生成结果：

```bash
openssl x509 -in /etc/hysteria/cert.pem -noout -subject -dates -ext subjectAltName
ls -l /etc/hysteria/key.pem   # 期望 -rw-------
```

## 上报

安装 + 验证通过后 POST 到 `https://hysteria.ipx.sarl/new`，JSON：

```json
{
  "ip": "<公网IP>",
  "obfs_password": "<运营商识别码>",
  "traffic_port": 12345,
  "traffic_secret": "<48位hex>",
  "cert_sha256": "AB:CD:…:EF",
  "cert_pin_sha256": "<base64(SHA256(DER))>"
}
```

- `cert_sha256`：`openssl -fingerprint -sha256` 的 hex（95 字符，带冒号）
- `cert_pin_sha256`：base64 的 SHA256(DER)，Hysteria 客户端 `tls.pinSHA256` 直接可用
- 读不到证书时这两个字段为空字符串，上报照常成功（面板侧可选字段）

- payload 同时落盘到 `/etc/hysteria/register.json`
- 失败只 WARN，不算安装失败；3 次重试后打印手动重试命令
- 字段名与服务端不一致时改 `REG_PAYLOAD` 即可，占位符：
  `__IP__` `__CODE__` `__PORT__` `__SECRET__` `__CERT_SHA256__` `__CERT_PIN__`，例如：
  `REG_PAYLOAD='{"ip":"__IP__","port":__PORT__,"secret":"__SECRET__"}' ./install.sh --code X`

## 装完检查

```bash
systemctl status hysteria-server
journalctl -u hysteria-server -n 30 --no-pager
ss -lunp | grep :443
./install.sh --verify-only
```

记得放行 **UDP 443**（云安全组 + 本机防火墙）。
