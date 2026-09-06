# 開発者向けドキュメント

利用方法・運用上の仕様は [README.md](README.md) に記載しています。
対応の基準は Ubuntu 24.04 LTS、systemd、ローカルの rootful Docker Engine
（iptables backend）です。

## ビルド

```bash
make
```

リポジトリ直下に `docker-restricted-egress_(Version)_all.deb` を生成します。
ビルドには Bash、GNU make、dpkg-deb、標準の coreutils・findutils・sed が必要です。
Ubuntu の最小構成で make がなければ `sudo apt install make` を実行します。
Python、Go、jq、debhelper、コンパイラは不要です。ビルドは root 権限を必要としません。
`dpkg-deb --root-owner-group` でパッケージ内の所有者を root にします。

```bash
make test     # 構文・差分チェック、ビルド、Bash の自動テスト
make check    # 構文・差分チェックのみ
make clean   # build/ と生成した .deb を削除
```

バージョンは `debian/control` で管理します。`make install DESTDIR=/任意の作業ディレクトリ`
はパッケージ作成用の配置を行います。ホストへの導入は README の `apt install` を使用してください。

実行時の依存は Bash、iptables、systemd、util-linux（flock）、coreutils（timeout など）、
Docker Engine と CLI です。`docker-ce | docker.io` をパッケージ依存として宣言していますが、
開発・対応基準は README に記載した docker-ce の構成です。

## ソース構成

| 場所 | 役割 |
| --- | --- |
| `src/firewall` | 設定検証、ネットワーク照合、遮断・通常ルール、削除 |
| `config/` | dpkg の conffile として配置する設定 |
| `systemd/` | 通常サービスと Docker の起動・停止フック |
| `debian/` | バイナリパッケージのメタデータと maintainer scripts |
| `tests/` | Bash の状態付き Docker/iptables モックとパッケージ検証 |

`debian/` は `dpkg-deb` 用です。debhelper 用のソースパッケージ構成ではありません。
背景の議論より、現在の README の仕様を優先しています。

## 一時遮断と通常ルール

一時遮断は **mangle table の FORWARD** 先頭に、入力 bridge と
`docker-restricted-egress:guard` comment を指定した DROP を置きます。
この hook は filter/FORWARD より前に処理され、Docker が filter/FORWARD に
ACCEPT や DOCKER-USER への分岐を挿入しても遮断が残ります。
INPUT と IPv6 にはルールを追加しません。

通常ルールは filter/DOCKER-USER の先頭から専用 chain へ分岐します。
条件は `-i "$BRIDGE" ! -o "$BRIDGE"` です。同一 bridge 内は分岐の対象外で、
Docker の通常処理に進みます。BLOCK_CIDRS は REJECT（icmp-admin-prohibited）、
その他は RETURN です。ESTABLISHED を先に許可する例外を作らないため、
reload で禁止した宛先への既存接続も拒否対象になります。

既存ルールは順序を維持し、パッケージの分岐をその前に挿入します。
専用 chain だけを再構築し、テーブル全体や DOCKER-USER を flush しません。
同名でも所有記録のない既存 chain は変更せずエラーにします。
DOCKER-USER がない場合や、filter/FORWARD の最初のルールが無条件の
`-j DOCKER-USER` でない場合は、一時遮断を解除しません。
管理者が挿入した FORWARD ルールが先行する環境では、その適用順序を調整してください。

ルール構築途中のエラー、シグナルによる中断でも一時遮断を解除する trap はありません。
検証成功の経路だけで解除します。iptables は `--wait 10` を使用し、
処理全体は `/run/lock/docker-restricted-egress.lock` の flock で直列化します。
Docker CLI はローカル socket を明示し、Docker context・リモート接続・API バージョンの
環境変数を除去します。各 Docker 呼び出しの timeout は 60 秒です。

## 保存する状態と設定エラー

`/var/lib/docker-restricted-egress/` は root 専用（0700）で、以下を保存します。

| ファイル | 内容 |
| --- | --- |
| `identity` | 初回の NETWORK、BRIDGE、SUBNET、CHAIN。実行せずデータとして読み込み |
| `guards` | 次の起動時にも遮断する bridge 名 |
| `network-id` | 検証した Docker network の ID |
| `chain-owned` | このパッケージが専用 chain を作成した記録 |
| `removed` | ネットワークの削除完了後に遅れて実行されるフックを抑止 |

設定を読む前に保存済み bridge を遮断します。これにより、再起動後に設定の構文が
壊れていても、以前の構成を保護した上で起動に失敗します。
既存ネットワークの bridge が設定と違う場合は、実際の bridge も遮断・保存してから
不一致を報告します。ほかのコンテナとその bridge を共有していた場合は、それらにも影響します。

設定は root 管理の Bash ファイルです。SUBNET と BLOCK_CIDRS はホスト名を含まない
正規化済み IPv4 CIDR（例: `10.0.0.0/8`）を指定します。
空の `BLOCK_CIDRS=""` は明示的に拒否対象なしとし、未指定なら既定値を使います。
interface 名の `+` ワイルドカードや Docker 管理 chain の指定は拒否します。

既存ネットワークについて bridge driver、local scope、IPv6 無効、非 internal、
単一の IPv4 subnet、default IPAM、ICC・masquerade 有効、IPv4 NAT mode を確認します。
名前が同じでも保存済み ID と違うネットワークを自動で引き継ぎません。
状態ファイルを手動削除すると変更前の構成を保護する情報を失うため、通常の移行は README の
remove/install 手順を使ってください。chain 作成直後の強制終了などで所有記録を保存できなかった
場合も安全側に停止します。その場合はカーネルのルールと状態を照合して管理者が復旧します。

## systemd とパッケージのライフサイクル

Docker の drop-in は `Wants=docker-restricted-egress.service` によって、Docker 起動ごとに
サービスを起動します。サービスは static unit で、個別の enable は不要です。
`After` により Docker 起動後に適用し、停止時は逆順になります。
`BindsTo` と `PartOf` で Docker の停止・再起動にも連動します。

Docker の `ExecStartPre` が一時遮断に失敗した場合は Docker 自体が起動しません。
通常ルールの失敗は Wants の先のサービスの失敗となり、Docker の稼働を保ちつつ遮断を残します。
Docker の `ExecStop` は dockerd へ停止シグナルを送る前に遮断します。
`ExecStopPost` でも遮断し、起動失敗や予期しない daemon 終了を扱います。
docker-ce の標準 unit（ExecStop なし、systemd のシグナルで dockerd を停止）を前提としています。
管理者が Docker の ExecStop を追加・置換している場合は順序を確認してください。

| 操作 | maintainer script の処理 |
| --- | --- |
| install / configure | prepare で遮断 → daemon-reload → Docker start → 通常サービス restart |
| upgrade | 旧スクリプトで unpack 前に遮断 → configure で再適用 |
| remove | 遮断・未使用確認 → サービス stop → 再確認 → ID を指定して network rm → ルール削除 |
| purge | remove と同じ安全確認後、dpkg が conffile を削除 |
| abort | 自動再適用せず、遮断を保持 |

一覧取得の失敗を「ネットワークなし」と扱いません。削除直前にも状態を照合し、
最終的な削除可否は Docker に判断させます。削除に失敗したらルールを外しません。
削除完了を記録した後は、遅れて呼ばれた systemd フックによる再作成を抑止します。
postrm は unit を再読み込みしてから削除完了済みの状態だけを清掃します。

セキュリティ設定を実際に適用するため、configure/remove は systemd と Docker が動作する
ホスト上で実行してください。offline image や chroot への導入は対象外です。
設定失敗は dpkg に伝播させ、正常導入として扱いません。

## テストの範囲

`make test` は root 権限も Docker daemon も使わず、ホストの firewall を変更しません。
実装本体を Bash から読み込み、コマンド境界だけを状態付きモックに置換します。
初期化、繰り返し適用、既存ルール保持、設定破損、構成変更、所有権衝突、
Docker/iptables エラー、適用途中の失敗、停止、削除拒否、接続競合、同時実行を確認します。
生成 .deb の展開内容と権限も確認し、展開した maintainer scripts のパスを一時領域に
置き換えて成功・失敗時の呼び出し順を検証します。

これらのモック検証は、カーネルによるパケット処理、実際の systemd job ordering、
apt/dpkg の conffile 更新対話の実機検証を代替しません。

### リリース前の実機検証

Ubuntu 24.04 LTS の使い捨て WSL2/VM で、ローカルの Docker Engine と systemd を使用してください。
以下は Docker を再起動し、ネットワークを作成・削除する検証です。

1. `make test` 後、README の手順で生成 .deb をインストールし、サービスが
   `active (exited)`、既定 network が作成済みであることを確認します。
2. README のインターネット・DNS・HTTPS・LAN の疎通確認を実施します。
   LAN の拒否は、接続先が実際に到達可能であることをホスト側から確認し、
   専用 chain の REJECT カウンタ増加も確認します。
3. 同じ network のコンテナ同士で ping/TCP を実行します。別 network のコンテナからの
   通信にこのパッケージのルールが適用されないことも確認します。
4. コンテナから定期的に外部・LAN へ通信しながら、サービスの reload/stop/start/restart、
   Docker の restart、ホスト再起動を行います。`--restart=always` と Docker の live-restore
   有効・無効をそれぞれ確認し、LAN に到達する期間がないことを記録します。
5. BLOCK_CIDRS の不正値と Bash 構文エラーを設定し、reload と Docker restart の失敗時に
   一時遮断が残ることを確認します。修正後は README の復旧手順で通信が戻ることを確認します。
6. BLOCK_CIDRS に到達可能な宛先を追加し、既存 TCP 接続も拒否されることを確認します。
7. 設定ファイルを編集した状態でパッケージを再インストール・更新し、設定保持と再適用を確認します。
8. 接続中のコンテナがある状態で remove が失敗すること、コンテナ削除後は network/chain/guard が
   消え、設定だけが残ることを確認します。再インストール後に purge し、設定の削除も確認します。
9. bridge/subnet の不一致、ネットワーク削除時の Docker 停止、適用途中のプロセス終了を再現し、
   エラー時に保護が残ることを確認します。

一時遮断の確認:

```bash
sudo iptables -t mangle -S FORWARD
sudo iptables -t mangle -L FORWARD -n -v --line-numbers
systemctl cat docker.service docker-restricted-egress.service
sudo journalctl -b -u docker.service -u docker-restricted-egress.service
```

参考: [Docker の iptables 処理](https://docs.docker.com/engine/network/firewall-iptables/)、
[bridge driver の設定](https://docs.docker.com/engine/network/drivers/bridge/)、
[iptables マニュアル](https://ipset.netfilter.org/iptables.man.html)、
[Debian maintainer scripts](https://www.debian.org/doc/debian-policy/ch-maintainerscripts.html)。
