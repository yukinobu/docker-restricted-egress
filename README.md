# docker-restricted-egress

Docker コンテナからインターネットへの通信を許可しつつ、LAN などのプライベートネットワークへの通信を制限するための Docker ネットワークとファイアウォール設定を提供します。

主に以下の環境を対象としています。

* WSL2 上の Ubuntu（Ubuntu 24.04 LTS を開発・対応の基準とします）
* Ubuntu 内に `apt install docker-ce` で直接インストールした Docker Engine
* systemd が有効
* Docker が iptables firewall backend を使用

Docker Desktop の WSL integration を利用する構成は対象外です。

## 概要

本パッケージは、制限付き Docker bridge network `restricted-net` を作成し、そのネットワークから外部へ転送されるパケットを `iptables` で制御します。

デフォルトでは以下の通信を想定しています。

| 通信 | デフォルト |
| -------------------------- | ----- |
| コンテナ → インターネット | 許可 |
| コンテナ → `10.0.0.0/8` | 拒否 |
| コンテナ → `172.16.0.0/12` | 拒否 |
| コンテナ → `192.168.0.0/16` | 拒否 |
| `restricted-net` 内のコンテナ間通信 | 許可 |
| コンテナ → WSL/Linux ホスト自身 | 制限対象外 |

構成イメージ:

```text
                         WSL2 / Ubuntu
                               │
                         Docker Engine
                               │
                         restricted-net
                         172.30.0.0/24
                               │
                         br-restricted
                               │
                               ▼
                          DOCKER-USER
                               │
                               ▼
                  DOCKER-RESTRICTED-EGRESS
                               │
                   ┌───────────┴───────────┐
                   │                       │
             RFC1918 → REJECT      その他 → Docker 標準処理
                                           │
                                          NAT
                                           │
                                           ▼
                                        Internet
```

Docker が管理する `DOCKER-USER` chain は直接変更せず、Docker がユーザー定義ルール向けに提供する `DOCKER-USER` chain から専用の `DOCKER-RESTRICTED-EGRESS` chain へ分岐させます。

## インストール

ビルド済み Debian package がある場合は、次のようにインストールします。

```bash
sudo apt install ./docker-restricted-egress_1.0.0_all.deb
```

インストール後、次のリソースが作成されます。

```text
/etc/default/docker-restricted-egress
/usr/libexec/docker-restricted-egress/firewall
/usr/lib/systemd/system/docker-restricted-egress.service
```

加えて、Docker 上に以下が作成されます。

```text
Docker network : restricted-net
Bridge         : br-restricted
Subnet         : 172.30.0.0/24
```

iptables には以下のような構造が追加されます。

```text
DOCKER-USER
    │
    └── DOCKER-RESTRICTED-EGRESS
```

サービスの状態は次のコマンドで確認できます。

```bash
systemctl status docker-restricted-egress.service
```

正常時は `active (exited)` になります。

## Docker Compose から利用する

`restricted-net` は docker-restricted-egress 側で管理されるため、Compose では external network として参照します。

```yaml
services:
  app:
    image: alpine:latest
    command: sleep infinity
    networks:
      - restricted

networks:
  restricted:
    external: true
    name: restricted-net
```

起動します。

```bash
docker compose up -d
```

Compose 側で subnet、bridge、iptables などを設定する必要はありません。

複数の Compose project から同じ `restricted-net` を利用できます。

## `docker run` から利用する

Compose を使用しない場合は、`--network` で直接指定できます。

```bash
docker run --rm \
  --network restricted-net \
  alpine:latest \
  ping -c 1 1.1.1.1
```

## デフォルト設定

設定ファイルは以下です。

```text
/etc/default/docker-restricted-egress
```

デフォルト値:

```bash
NETWORK=restricted-net
BRIDGE=br-restricted
SUBNET=172.30.0.0/24
CHAIN=DOCKER-RESTRICTED-EGRESS

BLOCK_CIDRS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
```

### ブロック対象を追加する

例えば link-local と CGNAT 範囲も禁止する場合:

```bash
BLOCK_CIDRS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10"
```

設定変更後は以下を実行します。

```bash
sudo systemctl reload docker-restricted-egress.service
```

ファイアウォールルールが設定ファイルから再構築されます。

## 動作確認

### インターネット

```bash
docker run --rm \
  --network restricted-net \
  alpine:latest \
  ping -c 1 1.1.1.1
```

成功することを確認します。

DNS および HTTPS も確認する場合:

```bash
docker run --rm \
  --network restricted-net \
  curlimages/curl \
  https://example.com/
```

### LAN

例えば LAN の gateway が `192.168.1.1` の場合:

```bash
docker run --rm \
  --network restricted-net \
  alpine:latest \
  ping -c 1 192.168.1.1
```

通信できないことを確認します。

TCP についても必要に応じて確認してください。

```bash
docker run --rm \
  --network restricted-net \
  curlimages/curl \
  --connect-timeout 3 \
  http://192.168.1.1/
```

## iptables の確認

`DOCKER-USER` から専用 chain への接続を確認します。

```bash
sudo iptables \
  -L DOCKER-USER \
  -n -v --line-numbers
```

専用 chain:

```bash
sudo iptables \
  -L DOCKER-RESTRICTED-EGRESS \
  -n -v --line-numbers
```

概ね以下のようなルールになります。

```text
Chain DOCKER-RESTRICTED-EGRESS

target  destination
REJECT  10.0.0.0/8
REJECT  172.16.0.0/12
REJECT  192.168.0.0/16
RETURN  0.0.0.0/0
```

`pkts` / `bytes` カウンタを見ることで、どのルールに通信が到達したか確認できます。

## Docker network の確認

```bash
docker network inspect restricted-net
```

Linux bridge:

```bash
ip addr show br-restricted
```

デフォルト設定では以下のアドレスを持ちます。

```text
172.30.0.1/24
```

## systemd

ファイアウォール設定は systemd により管理されます。

```bash
sudo systemctl start docker-restricted-egress
sudo systemctl stop docker-restricted-egress
sudo systemctl reload docker-restricted-egress
```

`start` 時には、Docker network の存在と設定を確認した上でファイアウォールを適用します。

`reload` 時には専用 chain を現在の設定から再構築します。

`stop` 時には `DOCKER-USER` からの jump と `DOCKER-RESTRICTED-EGRESS` chain を削除します。

Docker Engine 起動後にファイアウォールが設定されるよう systemd の依存関係が構成されます。

## アンインストール

### 通常の削除

```bash
sudo apt remove docker-restricted-egress
```

削除時には以下を行います。

1. `restricted-net` が使用中でないことを確認
2. ファイアウォールルールを解除
3. `restricted-net` を削除
4. systemd service と実行ファイルを削除
5. `/etc/default/docker-restricted-egress` は保持

### 完全削除

設定ファイルも含めて削除する場合:

```bash
sudo apt purge docker-restricted-egress
```

### 使用中の network が存在する場合

安全のため、`restricted-net` にコンテナが接続された状態でのアンインストールは拒否します。

先に対象コンテナを停止・削除してください。

```bash
docker network inspect restricted-net
```

Compose project で利用している場合:

```bash
docker compose down
```

その後、再度アンインストールします。

これは、ファイアウォールだけが削除されて `restricted-net` のコンテナが LAN にアクセス可能になる状態を防止するための仕様です。

## セキュリティモデル

このパッケージは Docker の forwarding path に対してファイアウォールを設定します。

主な対象は次の通信です。

```text
container
    │
    ▼
Docker bridge
    │
    ▼
Linux FORWARD
    │
    ▼
DOCKER-USER
    │
    ▼
LAN / Internet
```

したがって、

```text
container → LAN
```

のような転送通信は制御できます。

一方、

```text
container → WSL/Linux host 自身
```

の通信は Linux の `INPUT` path に入るため、このパッケージのデフォルトポリシーでは制限しません。

このパッケージは、コンテナを完全な hostile-code sandbox として隔離することを目的としたものではありません。

必要なセキュリティ要件が、

```text
Internet               OK
LAN                    NG
他 Docker network      NG
WSL host               NG
Windows host           NG
link-local             NG
IPv6 local network     NG
```

まで及ぶ場合は、追加の host firewall policy が必要です。

## DNS に関する注意

環境によっては DNS の上流サーバーが RFC1918 のアドレスに存在する場合があります。

その場合、プライベートネットワークへの通信をすべて拒否すると DNS 名前解決にも影響する可能性があります。

以下のような状態になった場合:

```text
1.1.1.1 には通信できる
example.com は名前解決できない
```

コンテナ、Docker、WSL の DNS 構成を確認してください。

必要であれば特定の DNS resolver の UDP/TCP 53 番ポートのみを例外として許可します。

## IPv6

本バージョンでは IPv4 の制御を対象とします。

IPv6 が有効な環境では、IPv4 の RFC1918 相当だけを拒否しても LAN への IPv6 通信を防止できません。

IPv6 を利用する場合は少なくとも以下を別途検討してください。

```text
fc00::/7   Unique Local Address
fe80::/10  Link-local
```

IPv6 を含む完全な egress policy は将来の対応項目とします。

## Docker firewall backend

このパッケージは Docker の `iptables` firewall backend を前提とします。

以下で現在の chain を確認できます。

```bash
sudo iptables -L DOCKER-USER
```

`DOCKER-USER` が存在しない環境では、本パッケージはファイアウォール設定を適用せずエラー終了します。

なお、

```bash
iptables -V
```

が以下のように表示されることがあります。

```text
iptables v1.8.x (nf_tables)
```

これは `iptables` コマンドが nftables compatibility layer を利用していることを示すものであり、Docker 自体が nftables firewall backend を使用していることと同義ではありません。

## 対象外

以下の環境は本バージョンでは対象外です。

* Docker Desktop for Windows の WSL integration
* Docker の nftables firewall backend
* rootless Docker
* IPv6 の egress 制御
* Kubernetes / CNI network
* Docker Swarm overlay network

## 設計方針

このパッケージでは責務を以下のように分離します。

```text
docker-restricted-egress package
    │
    ├── Docker network の管理
    ├── Linux bridge の管理
    ├── firewall policy の管理
    └── systemd lifecycle の管理

Application
    │
    └── external restricted-net を利用
```

アプリケーション側の Compose file にホスト firewall の実装を持ち込まないことで、ネットワークセキュリティポリシーとアプリケーション定義を分離します。

また、ホスト上に配置されるすべてのファイルを Debian package の所有物とすることで、

```bash
dpkg -L docker-restricted-egress
```

から管理対象を確認できます。
