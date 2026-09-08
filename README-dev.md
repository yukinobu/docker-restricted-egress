# 開発者向けドキュメント

利用方法と運用上の仕様は [README.md](README.md) に記載しています。
開発および対応の基準は、Ubuntu 24.04 LTS、systemd、ローカルの rootful Docker Engine（iptables バックエンド）です。

## ビルド

```bash
make
```

リポジトリ直下に `docker-restricted-egress_<Version>_all.deb` を生成します。
ビルドには Bash、GNU make、dpkg-deb、標準の coreutils、findutils、sed が必要です。
Ubuntu の最小構成で make がなければ `sudo apt install make` を実行します。
Python、Go、jq、debhelper、コンパイラは不要です。
ビルドに root 権限は必要ありません。
`dpkg-deb --root-owner-group` でパッケージ内の所有者を root にします。

```bash
make test    # 構文・差分チェック、ビルド、Bash の自動テスト
make check   # 構文・差分チェックのみ
make clean   # build/ と生成した .deb を削除
```

`systemd-analyze` が利用できる環境では、次の検証も実行できます。
ホストのサービスは操作しません。

```bash
make test-systemd
```

生成した `.deb` を一時領域に展開し、最小構成の Docker ユニットとターゲットを補います。
その構成に対して `systemd-analyze verify` を実行し、ユニットと drop-in の構文および起動依存関係を確認します。
実際のサービス起動順序と停止順序の検証には、「リリース前の実機検証」の手順を使用してください。
`SYSTEMD_ANALYZE=/path/to/systemd-analyze make test-systemd` で検証ツールを指定できます。

バージョンは `debian/control` で管理します。
`make install DESTDIR=/任意の作業ディレクトリ` は、パッケージ作成用の配置だけを行います。
ホストへの導入には README の `apt install` を使用してください。

実行時には Bash、iptables、systemd、util-linux（`flock`）、coreutils（`timeout` など）、Docker Engine と Docker CLI が必要です。
パッケージの依存関係には `docker-ce | docker.io` を宣言しています。
ただし、開発および対応の基準は README に記載した `docker-ce` の構成です。

## ソース構成

| 場所 | 役割 |
| --- | --- |
| `src/firewall` | 設定検証、ネットワーク照合、一時遮断、通常ルール、削除 |
| `config/` | dpkg の conffile として配置する設定ファイル |
| `systemd/` | 通常サービスと Docker の起動および停止フック |
| `debian/` | バイナリパッケージのメタデータと maintainer script |
| `tests/` | Bash の状態付き Docker/iptables モックとパッケージ検証 |

`debian/` は `dpkg-deb` 用であり、debhelper 用のソースパッケージ構成ではありません。
実装を変更するときは、背景の議論より現在の README に記載された仕様を優先します。

## 一時遮断と通常ルール

一時遮断では、**mangle テーブルの `FORWARD` チェイン**の先頭に `DROP` ルールを置きます。
このルールには、入力ブリッジと `docker-restricted-egress:guard` コメントを指定します。
mangle テーブルのフックは filter テーブルの `FORWARD` チェインより前に処理されるため、Docker が `ACCEPT` や `DOCKER-USER` への分岐を挿入しても遮断が残ります。
INPUT と IPv6 にはルールを追加しません。

通常ルールは filter テーブルの `DOCKER-USER` チェイン先頭から専用チェインへ分岐します。
分岐条件は `-i "$BRIDGE" ! -o "$BRIDGE"` です。
同じブリッジ内の通信は分岐せず、Docker の通常処理に進みます。
`BLOCK_CIDRS` の宛先は `REJECT`（`icmp-admin-prohibited`）とし、その他の宛先は `RETURN` します。
`ESTABLISHED` を先に許可する例外を作らないため、`reload` で禁止した宛先への既存接続も拒否対象になります。

既存ルールは順序を維持し、パッケージの分岐をその前に挿入します。
専用チェインだけを再構築し、テーブル全体や `DOCKER-USER` はフラッシュしません。
同名であっても、所有記録のない既存チェインは変更せずエラーにします。
`DOCKER-USER` がない場合や、filter テーブルの `FORWARD` チェインで最初のルールが無条件の `-j DOCKER-USER` でない場合は、一時遮断を解除しません。
管理者が挿入した `FORWARD` ルールが先行する環境では、その適用順序を調整してください。

ルール構築中のエラーやシグナルによる中断で一時遮断を解除する `trap` はありません。
検証に成功した経路だけで解除します。
iptables は `--wait 10` を使用し、処理全体は `/run/lock/docker-restricted-egress.lock` の `flock` で直列化します。
Docker CLI にはローカルソケットを明示し、Docker コンテキスト、リモート接続、API バージョンを指定する環境変数を除去します。
各 Docker 呼び出しのタイムアウトは 60 秒です。

## 保存する状態と設定エラー

`/var/lib/docker-restricted-egress/` は root 専用（0700）で、次の状態を保存します。

| ファイル | 内容 |
| --- | --- |
| `identity` | 初回の `NETWORK`、`BRIDGE`、`SUBNET`、`CHAIN`。実行せずデータとして読み込む |
| `guards` | 次の起動時にも遮断するブリッジ名 |
| `network-id` | 検証した Docker ネットワークの ID |
| `chain-owned` | このパッケージが専用チェインを作成した記録 |
| `removed` | ネットワークの削除完了後に遅れて実行されるフックを抑止 |

設定を読む前に、保存済みのブリッジを遮断します。
そのため、再起動後に設定の構文が壊れていても、以前の構成を保護したうえで起動に失敗します。
既存ネットワークのブリッジが設定と異なる場合は、実際のブリッジも遮断して保存してから不一致を報告します。
ほかのコンテナがそのブリッジを共有している場合は、それらの通信にも影響します。

設定は root が管理する Bash ファイルです。
`SUBNET` と `BLOCK_CIDRS` には、ホスト名を含まない正規化済み IPv4 CIDR（例：`10.0.0.0/8`）を指定します。
空の `BLOCK_CIDRS=""` は明示的に拒否対象なしとし、未指定なら既定値を使います。
インターフェイス名の `+` ワイルドカードや Docker 管理チェインの指定は拒否します。

既存ネットワークについて、ブリッジドライバー、ローカルスコープ、IPv6 無効、非 internal、単一の IPv4 サブネット、デフォルト IPAM、ICC および masquerade 有効、IPv4 NAT モードを確認します。
名前が同じでも保存済み ID と違うネットワークを自動で引き継ぎません。
状態ファイルを手動で削除すると、変更前の構成を保護する情報が失われます。
通常の移行には README の削除および再インストール手順を使用してください。
チェイン作成直後の強制終了などによって所有記録を保存できなかった場合も、安全側に停止します。
その場合は、管理者がカーネルのルールと保存状態を照合して復旧します。

## systemd とパッケージのライフサイクル

Docker の drop-in は、`Wants=docker-restricted-egress.service` によって Docker の起動ごとにサービスを起動します。
サービスは static ユニットであり、個別の `enable` は不要です。
`After` によって Docker の起動後に適用し、停止時は逆順になります。
`BindsTo` と `PartOf` によって Docker の停止と再起動にも連動します。

Docker の `ExecStartPre` が一時遮断に失敗した場合は、Docker 自体が起動しません。
通常ルールの適用失敗は `Wants` 先のサービスの失敗として扱われるため、Docker の稼働を保ちながら遮断を残します。
Docker の `ExecStop` は、dockerd へ停止シグナルを送る前に遮断します。
`ExecStopPost` でも遮断し、起動失敗や予期しないデーモン終了を扱います。
`docker-ce` の標準ユニット（`ExecStop` なし、systemd のシグナルで dockerd を停止）を前提としています。
管理者が Docker の `ExecStop` を追加または置換している場合は、順序を確認してください。

| 操作 | maintainer script の処理 |
| --- | --- |
| install / configure | `prepare` で遮断 → `daemon-reload` → Docker の `start` → 通常サービスの `restart` |
| upgrade | 旧スクリプトで unpack 前に遮断 → configure で再適用 |
| remove | 遮断と未使用確認 → サービスの `stop` → 再確認 → ID を指定して `network rm` → ルール削除 |
| purge | remove と同じ安全確認後、dpkg が conffile を削除 |
| abort | 自動再適用せず、遮断を保持 |

一覧取得の失敗を「ネットワークなし」とは扱いません。
削除直前にも状態を照合し、最終的な削除可否は Docker に判断させます。
削除に失敗した場合はルールを外しません。
削除完了を記録した後は、遅れて呼ばれた systemd フックによる再作成を抑止します。
`postrm` はユニットを再読み込みしてから、削除完了済みの状態だけを清掃します。

セキュリティ設定を実際に適用するため、`configure` と `remove` は systemd と Docker が動作するホスト上で実行してください。
オフラインイメージや chroot への導入は対象外です。
設定失敗は dpkg に伝播させ、正常導入として扱いません。

## テストの範囲

`make test` は root 権限も Docker デーモンも使わず、ホストのファイアウォールを変更しません。
実装本体を Bash から読み込み、コマンド境界だけを状態付きモックに置換します。
初期化、繰り返し適用、既存ルール保持、設定破損、構成変更、所有権衝突、Docker および iptables のエラー、適用途中の失敗、停止、削除拒否、接続競合、同時実行を確認します。
生成した `.deb` の展開内容と権限も確認します。
展開した maintainer script のパスを一時領域に置き換え、成功時と失敗時の呼び出し順を検証します。

これらのモック検証は、カーネルによるパケット処理、実際の systemd ジョブ順序、apt/dpkg の conffile 更新対話に対する実機検証を代替しません。

初回実装では、Ubuntu 26.04 の開発コンテナで `make test` のファイアウォール 22 シナリオとパッケージ検証 8 項目を確認しました。
追加パッケージをインストールせず、systemd 259 のパッケージを一時展開して `make test-systemd` も確認しました。
この開発環境には Docker Engine と iptables がなく、`NET_ADMIN` 権限およびネットワーク名前空間の作成権限もありません。
そのため、Ubuntu 24.04 LTS または WSL2 上の実通信と実際のサービス連携は未検証です。

### リリース前の実機検証

Ubuntu 24.04 LTS の使い捨て WSL2/VM で、ローカルの Docker Engine と systemd を使用してください。
次の手順では Docker を再起動し、ネットワークを作成して削除します。

1. `make test` 後、README の手順で生成した `.deb` をインストールし、サービスが `active (exited)`、既定ネットワークが作成済みであることを確認します。
2. README に従い、インターネット、DNS、HTTPS、LAN の疎通を確認します。
   LAN の拒否は、接続先が実際に到達可能であることをホスト側から確認し、専用チェインの `REJECT` カウンタ増加も確認します。
3. 同じネットワークのコンテナ同士で ping と TCP 通信を実行します。
   別ネットワークのコンテナからの通信に、このパッケージのルールが適用されないことも確認します。
4. コンテナから定期的に外部と LAN へ通信しながら、サービスの reload/stop/start/restart、Docker の restart、ホスト再起動を行います。
   `--restart=always` と Docker の live-restore について有効時と無効時をそれぞれ確認し、LAN に到達する期間がないことを記録します。
5. `BLOCK_CIDRS` の不正値と Bash 構文エラーを設定し、`reload` と Docker の `restart` の失敗時に一時遮断が残ることを確認します。
   修正後は README の復旧手順で通信が戻ることを確認します。
6. `BLOCK_CIDRS` に到達可能な宛先を追加し、既存 TCP 接続も拒否されることを確認します。
7. 設定ファイルを編集した状態でパッケージを再インストールして更新し、設定保持と再適用を確認します。
8. 接続中のコンテナがある状態で `remove` が失敗することを確認します。
   コンテナ削除後はネットワーク、チェイン、一時遮断が消え、設定だけが残ることを確認します。
   再インストール後に `purge` し、設定の削除も確認します。
9. ブリッジとサブネットの不一致、ネットワーク削除時の Docker 停止、適用途中のプロセス終了を再現し、エラー時に保護が残ることを確認します。

一時遮断は次のコマンドで確認します。

```bash
sudo iptables -t mangle -S FORWARD
sudo iptables -t mangle -L FORWARD -n -v --line-numbers
systemctl cat docker.service docker-restricted-egress.service
sudo journalctl -b -u docker.service -u docker-restricted-egress.service
```

参考資料は次のとおりです。

- [Docker の iptables 処理](https://docs.docker.com/engine/network/firewall-iptables/)
- [bridge driver の設定](https://docs.docker.com/engine/network/drivers/bridge/)
- [iptables マニュアル](https://ipset.netfilter.org/iptables.man.html)
- [Debian maintainer scripts](https://www.debian.org/doc/debian-policy/ch-maintainerscripts.html)
