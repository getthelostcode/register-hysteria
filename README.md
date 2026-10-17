# register-hysteria

Hysteria2 节点一键安装 + 自动注册。装完即跑，成功后把节点信息上报到注册中心。

## 用法

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

环境变量：`HYSTERIA_ETC`、`HYSTERIA_BIN`、`HYSTERIA_SERVICE`、`SYSTEMD_UNIT_DIR`、
`MASQUERADE_DIR`、`HYSTERIA_LISTEN`、`HYSTERIA_VERSION`、`REG_API`、`PUBLIC_IP`、
`REG_PAYLOAD`。

## 脚本写入的值

模板：`config.yaml.example`（与本脚本同目录，装到 `/etc/hysteria/config.yaml.example`）。

| 字段 | 值 |
|------|----|
| `listen` | `':443'` |
| `tls.cert` / `tls.key` | `/etc/hysteria/cert.pem` / `key.pem`（优先用本目录 `cert`/`key`，否则现场自签 10 年） |
| `obfs.salamander.password` | **运营商识别码**（客户端需一致） |
| `trafficStats.listen` | `0.0.0.0:<随机 10000-19000>`（自动避开已占用端口；重跑时复用旧值，旧值不在区间则重新随机） |
| `trafficStats.secret` | `openssl rand -hex 24`（重跑时复用旧值） |
| `masquerade.file.dir` | `/var/www/hysteria`（自动建目录 + index.html） |
| `bandwidth.up/down` | `100 mbps` |

其余字段（auth、quic 等）原样保留。

## 上报

安装 + 验证通过后 POST 到 `https://hysteria.ipx.sarl/new`，JSON：

```json
{"ip":"<公网IP>","obfs_password":"<运营商识别码>","traffic_port":12345,"traffic_secret":"<48位hex>"}
```

- payload 同时落盘到 `/etc/hysteria/register.json`
- 失败只 WARN，不算安装失败；3 次重试后打印手动重试命令
- 字段名与服务端不一致时改 `REG_PAYLOAD` 即可，例如：
  `REG_PAYLOAD='{"ip":"__IP__","port":__PORT__,"secret":"__SECRET__"}' ./install.sh --code X`

## 装完检查

```bash
systemctl status hysteria-server
journalctl -u hysteria-server -n 30 --no-pager
ss -lunp | grep :443
./install.sh --verify-only
```

记得放行 **UDP 443**（云安全组 + 本机防火墙）。
