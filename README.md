# docker-restricted-egress

Docker コンテナからインターネットへの通信を許可しながら、LAN などのプライベートネットワークへの通信を拒否します。
制限の対象は、専用の Docker ブリッジネットワークから転送される IPv4 通信です。

主に次の環境を対象としています。

- WSL2 上の Ubuntu（Ubuntu 24.04 LTS を開発および対応の基準とします）
- Ubuntu に直接インストールした Docker Engine（`docker-ce`）
- systemd が有効な環境
- Docker が iptables ファイアウォールバックエンドを使用する環境

Docker Desktop の WSL 統合を利用する構成は対象外です。
ホスト自身への通信と IPv6 通信も制限しません。
隔離範囲が要件を満たすか、インストール前に「セキュリティモデル」を確認してください。

## 概要

docker-restricted-egress は、制限付き Docker ブリッジネットワーク `restricted-net` を作成します。
このネットワークから外部へ転送されるパケットを `iptables` で制御します。

デフォルトの通信制限は次のとおりです。

| 通信 | デフォルト |
| -------------------------- | ----- |
| コンテナ → インターネット | 許可 |
| コンテナ → `10.0.0.0/8` | 拒否 |
| コンテナ → `172.16.0.0/12` | 拒否 |
| コンテナ → `192.168.0.0/16` | 拒否 |
| `restricted-net` 内のコンテナ間通信 | 許可 |
| コンテナ → WSL/Linux ホスト自身 | 制限対象外 |

起動時と再起動時は、制限ルールの適用が完了するまで `restricted-net` から外部への IPv4 転送通信を一時的に遮断します。
この間はインターネットにも接続できません。
適用に失敗した場合は遮断を維持し、ルールを適用しないまま通信できる状態を防ぎます。

通常動作時の構成は次のとおりです。

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

docker-restricted-egress は、Docker がユーザー定義ルール向けに提供する `DOCKER-USER` チェインから、専用の `DOCKER-RESTRICTED-EGRESS` チェインへ分岐させます。
それ以外の既存ルールは保持します。

起動時などに使用する一時遮断は、Docker のチェインに依存しません。
そのため、分岐や専用チェインがまだ存在しない段階でも機能します。

## インストール

ビルド済み Debian パッケージがある場合は、次のようにインストールします。

```bash
sudo apt install ./docker-restricted-egress_0.0.1_all.deb
```

インストール後、主なリソースとして次のファイルが配置されます。

```text
/etc/default/docker-restricted-egress
/usr/libexec/docker-restricted-egress/firewall
/usr/lib/systemd/system/docker-restricted-egress.service
```

Docker 起動前の一時遮断と起動後のルール適用を連動させる systemd 設定も配置されます。
これらの設定は本パッケージが管理します。

Docker 上には次の構成が作成されます。

```text
Docker network : restricted-net
Bridge         : br-restricted
Subnet         : 172.30.0.0/24
```

iptables には次の構造が追加されます。

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

インストール時は、ネットワークを新規作成する前に一時遮断を適用します。
制限ルールの適用を確認できた場合に限り、一時遮断を解除します。
インストールがルール適用エラーで終了した場合は、利用を開始する前に「適用失敗時の確認と復旧」を参照してください。

パッケージ更新時も、制限ルールを再適用する間は一時遮断します。

## Docker Compose から利用する

`restricted-net` は docker-restricted-egress が管理します。
Compose からは外部ネットワークとして参照します。

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

Compose 側でサブネット、ブリッジ、iptables を設定する必要はありません。

複数の Compose プロジェクトから同じ `restricted-net` を利用できます。

既存の `restricted-net` がある場合、制限ルールの適用前にコンテナが起動することがあります。
その場合も、適用完了までは外部への IPv4 転送通信を遮断します。
起動直後に外部接続が必要なアプリケーションは、接続を再試行できるようにしてください。

## `docker run` から利用する

Compose を使用しない場合は、`--network` で直接指定できます。

```bash
docker run --rm \
  --network restricted-net \
  alpine:latest \
  ping -c 1 1.1.1.1
```

## デフォルト設定

設定ファイルは次の場所にあります。

```text
/etc/default/docker-restricted-egress
```

デフォルト値は次のとおりです。

```bash
NETWORK=restricted-net
BRIDGE=br-restricted
SUBNET=172.30.0.0/24
CHAIN=DOCKER-RESTRICTED-EGRESS

BLOCK_CIDRS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
```

`reload` で変更できるのは `BLOCK_CIDRS` です。
`NETWORK`、`BRIDGE`、`SUBNET`、`CHAIN` は、初回の構成作成時に使用します。
作成後にこれらを変更する場合は「ネットワーク構成を変更する」の手順に従ってください。
サービスがこれらの変更を検出した場合は構成を移行せず、エラーとして変更前のネットワークの一時遮断を維持します。

同名の Docker ネットワークがすでに存在し、ブリッジやサブネットなどの設定が一致しない場合もエラーになります。
既存ネットワークを自動で削除または再作成することはありません。

### ブロック対象を追加する

例えば、リンクローカルアドレスと CGNAT の範囲も禁止する場合は、次のように設定します。

```bash
BLOCK_CIDRS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10"
```

設定変更後は次のコマンドを実行します。

```bash
sudo systemctl reload docker-restricted-egress.service
```

ファイアウォールルールを再構築する前に一時遮断を適用します。
再構築に成功した場合に限り、一時遮断を解除します。
この間は外部との通信が一時的に途切れる可能性があります。
再構築に失敗した場合は遮断を維持します。

### ネットワーク構成を変更する

`NETWORK`、`BRIDGE`、`SUBNET`、`CHAIN` を変更する場合は、利用中のコンテナを停止して削除したうえで構成を再作成します。
この作業中は対象アプリケーションを利用できません。

1. 対象ネットワークを利用するすべてのコンテナを停止して削除します。
   Compose を利用している場合は、該当する各プロジェクトで `docker compose down` を実行します。
2. 設定ファイルを変更前の値に保ったまま `sudo apt remove docker-restricted-egress` を実行し、既存ネットワークと保護ルールの削除が成功したことを確認します。
3. 削除後も残る `/etc/default/docker-restricted-egress` を編集します。
   新しいサブネットには、LAN、VPN、他の Docker ネットワークと重ならない範囲を指定します。
4. `sudo apt install ./docker-restricted-egress_0.0.1_all.deb` で再インストールし、変更した設定でネットワークと制限ルールを作成します。
5. サービスの正常動作を確認してからコンテナを再作成し、インターネットへの接続と LAN への通信拒否を確認します。
   `NETWORK` を変更した場合は、Compose の外部ネットワーク名と `docker run --network` の指定も変更します。

削除に失敗した場合は、設定の編集や再インストールに進まず、原因を解消してください。
先に設定を書き換えた場合は、変更前の値に戻してから削除します。
元の構成で利用を再開する場合は、設定を戻したうえでサービスを `restart` してください。

## 動作確認

### インターネット

```bash
docker run --rm \
  --network restricted-net \
  alpine:latest \
  ping -c 1 1.1.1.1
```

成功することを確認します。

DNS および HTTPS も確認する場合は、次のコマンドを実行します。

```bash
docker run --rm \
  --network restricted-net \
  curlimages/curl \
  https://example.com/
```

### LAN

例えば、LAN のゲートウェイが `192.168.1.1` の場合は次のように確認します。

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

次のコマンドで制限ルールを確認できます。
起動中、停止中、適用失敗時には一時遮断も有効になるため、専用チェインの内容だけでは通信の可否を判断できません。
サービスの状態とログも確認してください。

`DOCKER-USER` から専用チェインへの分岐を確認します。

```bash
sudo iptables \
  -L DOCKER-USER \
  -n -v --line-numbers
```

専用チェインのルールを確認します。

```bash
sudo iptables \
  -L DOCKER-RESTRICTED-EGRESS \
  -n -v --line-numbers
```

次の例は、`restricted-net` から外部への転送通信に適用する拒否ルールです。
同じブリッジ内のコンテナ間通信には、この拒否ルールを適用しません。
デフォルトのサブネット `172.30.0.0/24` はブロック対象の `172.16.0.0/12` に含まれますが、通常動作時は `restricted-net` 内のコンテナ同士で通信できます。

```text
Chain DOCKER-RESTRICTED-EGRESS

target  destination
REJECT  10.0.0.0/8
REJECT  172.16.0.0/12
REJECT  192.168.0.0/16
RETURN  0.0.0.0/0
```

`pkts` / `bytes` カウンタを見ることで、どのルールに通信が到達したか確認できます。

## Docker ネットワークの確認

```bash
docker network inspect restricted-net
```

Linux ブリッジを確認します。

```bash
ip addr show br-restricted
```

デフォルト設定では次のアドレスを持ちます。

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

各操作の動作は次のとおりです。

| 操作 | 動作 |
| ------ | ------------------------------------------------------------ |
| `start` | 一時遮断、ネットワーク検証、制限ルール適用、検証成功後の遮断解除 |
| `reload` | 一時遮断、現在の設定によるルール再構築、検証成功後の遮断解除 |
| `stop` | 一時遮断、制限ルールと専用チェインへの分岐の削除（ネットワークと一時遮断は維持） |
| `restart` | 停止から再適用完了まで一時遮断を維持 |

`stop` は通信制限の解除にはなりません。
停止中は `restricted-net` からインターネットを含む外部への IPv4 転送通信が遮断されます。
通常動作に戻すには `start` を実行してください。

### ホスト起動時と Docker 再起動時

systemd 経由で Docker Engine を起動または再起動すると、次の順序で保護します。

```text
restricted-net 用の一時遮断を適用
    ↓
Docker Engine を起動（既存ネットワークとコンテナを復元）
    ↓
制限ルールを適用して確認
    ↓
一時遮断を解除して通常動作へ
```

Docker の再起動ポリシーによってコンテナが自動起動する場合も、通常の制限ルールが有効になるまで外部への IPv4 転送通信を遮断します。
Docker の停止処理に入る際にも先に一時遮断を適用し、再起動中に保護が途切れないようにします。

Docker 起動前の一時遮断に失敗した場合は、Docker Engine の起動も失敗します。
この場合は `restricted-net` 以外のコンテナの起動にも影響します。
Docker 起動後の通常ルールの適用に失敗した場合は、`restricted-net` の一時遮断を維持します。

### 適用失敗時の確認と復旧

設定の誤りなどで適用に失敗した場合は、ネットワークが存在していても外部通信を再開しません。
まず、サービスの状態とログを確認してください。
`reload` に失敗してもサービスが `active (exited)` のままの場合があるため、コマンドの終了結果とログも確認します。

```bash
systemctl status docker-restricted-egress.service docker.service
sudo journalctl -b -u docker-restricted-egress.service -u docker.service
```

ログに記録された原因を解消します。
Docker Engine 自体が起動に失敗していた場合は、先に Docker を起動します。

```bash
sudo systemctl start docker.service
```

続いて、通常の制限ルールを再適用します。

```bash
sudo systemctl restart docker-restricted-egress.service
```

再適用に成功したら、インターネットへの接続と LAN への通信拒否を再確認してください。
docker-restricted-egress のパッケージ設定が未完了の場合は、原因を解消してからインストールコマンドも再実行してください。

## アンインストール

### 通常の削除

```bash
sudo apt remove docker-restricted-egress
```

削除時には次の処理を行います。

1. `restricted-net` が使用中でないことを確認する
2. 一時遮断を適用し、維持したまま `restricted-net` を削除する
3. ネットワークの削除後に、制限ルールと一時遮断を解除する
4. 本パッケージの systemd 設定と実行ファイルを削除する
5. `/etc/default/docker-restricted-egress` を保持する

使用状況を確認できない場合やネットワークの削除に失敗した場合は、削除処理を中断して保護を残します。
使用状況の確認後にコンテナが接続された場合も、ネットワークの削除に成功するまで保護を解除しません。

### 完全削除

設定ファイルも含めて削除する場合は、次のコマンドを実行します。

```bash
sudo apt purge docker-restricted-egress
```

### ネットワークが使用中の場合

安全のため、`restricted-net` にコンテナが接続された状態でのアンインストールは拒否します。

先に対象コンテナを停止して削除してください。

```bash
docker network inspect restricted-net
```

Compose プロジェクトで利用している場合は、次のコマンドでコンテナを停止して削除します。

```bash
docker compose down
```

その後、再度アンインストールします。

これは、ファイアウォールだけが削除されて `restricted-net` のコンテナが LAN にアクセス可能になる状態を防止するための仕様です。

## セキュリティモデル

docker-restricted-egress は、Docker の転送経路に対してファイアウォールを設定します。

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

この経路を通る `container → LAN` のような転送通信は制御できます。

一方、`container → WSL/Linux host 自身` の通信は Linux の `INPUT` 経路に入ります。
docker-restricted-egress のデフォルトポリシーは、この通信を制限しません。

docker-restricted-egress は、信頼できないコードを実行するコンテナを完全に隔離するサンドボックスではありません。

起動時や適用失敗時の一時遮断も、IPv4 の転送通信を対象とします。
Linux の `INPUT` 経路に入るホスト自身への通信と IPv6 通信は、この保護の対象に含みません。
一時遮断中はコンテナ間通信にも影響する場合があります。

起動順序による保護には、docker-restricted-egress の systemd 設定が有効であり、Docker Engine が systemd によって管理されている必要があります。
管理者によるファイアウォールルールの削除や、systemd を経由しない `dockerd` の起動に対する保護は保証しません。

次の通信も拒否する必要がある場合は、追加のホストファイアウォールポリシーが必要です。

```text
Internet               OK
LAN                    NG
他 Docker network      NG
WSL host               NG
Windows host           NG
link-local             NG
IPv6 local network     NG
```

## DNS に関する注意

`restricted-net` のようなユーザー定義ネットワークでは、通常 Docker の組み込み DNS（`127.0.0.11`）を利用します。
組み込み DNS は、外部の名前解決をホスト側で設定された DNS サーバーへ転送します。
詳しくは [Docker の DNS services](https://docs.docker.com/engine/network/#dns-services) を参照してください。

環境によっては DNS の上流サーバーが RFC1918 のアドレスに存在する場合があります。

DNS 問い合わせが docker-restricted-egress の制限対象となる転送経路を通る場合、プライベートネットワークへの通信拒否は名前解決にも影響します。
上流サーバーのアドレスだけで判断せず、組み込み DNS の利用状況やコンテナごとの DNS 指定も確認してください。

次のような状態になった場合は、コンテナ、Docker、WSL の DNS 構成を確認してください。

```text
1.1.1.1 には通信できる
example.com は名前解決できない
```

本バージョンには、DNS リゾルバーの例外許可を設定する機能はありません。
例外が必要な場合は、管理者が宛先の DNS リゾルバーと UDP/TCP 53 番ポートに限定したファイアウォール設定を別途管理してください。

docker-restricted-egress の専用チェインは `reload` などで再構築されるため、手動で追加したルールは保持されません。
追加設定では docker-restricted-egress のルールとの適用順序を調整し、起動時、停止中、適用失敗時の一時遮断を迂回させないでください。

## IPv6

本バージョンでは IPv4 の制御を対象とします。

IPv6 が有効な環境では、IPv4 の RFC1918 相当だけを拒否しても LAN への IPv6 通信を防止できません。

IPv6 を利用する場合は、少なくとも次のアドレス範囲を別途検討してください。

```text
fc00::/7   Unique Local Address
fe80::/10  Link-local
```

IPv6 を含む完全な egress policy は将来の対応項目とします。

## Docker のファイアウォールバックエンド

docker-restricted-egress は、Docker の `iptables` ファイアウォールバックエンドを前提とします。

次のコマンドで現在のチェインを確認できます。

```bash
sudo iptables -L DOCKER-USER
```

Docker Engine の起動後も `DOCKER-USER` が存在しない環境では、docker-restricted-egress は制限ルールを適用せずエラー終了します。
この場合は一時遮断を維持します。

```bash
iptables -V
```

このコマンドが次のように表示されることがあります。

```text
iptables v1.8.x (nf_tables)
```

これは `iptables` コマンドが nftables 互換レイヤーを利用していることを示します。
Docker 自体が nftables ファイアウォールバックエンドを使用していることと同義ではありません。

## 対象外

次の環境は本バージョンでは対象外です。

- Docker Desktop for Windows の WSL 統合
- Docker の nftables ファイアウォールバックエンド
- rootless Docker
- IPv6 の外向き通信制御
- Kubernetes および CNI ネットワーク
- Docker Swarm オーバーレイネットワーク

## 設計方針

docker-restricted-egress では、責務を次のように分離します。

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

アプリケーション側の Compose ファイルには、ホストファイアウォールの実装を持ち込みません。
これにより、ネットワークセキュリティポリシーとアプリケーション定義を分離します。

ホスト上に配置するすべてのファイルは、Debian パッケージの所有物とします。
次のコマンドで管理対象を確認できます。

```bash
dpkg -L docker-restricted-egress
```
