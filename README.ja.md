# unifi-v6plus-static-ip（日本語）

[English](README.md) | [日本語](README.ja.md)

UniFi OS ゲートウェイ（UDM / UDR）で、ISP から提供される **v6プラス固定IPv4（/32）** を **IPv4 over IPv6（IPIP6 トンネル）** で通しつつ、**ネイティブ IPv6 をそのまま維持**するためのスクリプト集です。

ISP が以下のような情報を提供するケースを想定しています：

- **固定 IPv4 アドレス**：`x.x.x.x/32`
- **IPv6 プレフィックス**：`xxxx:....::/64`
- **BR（Border Relay）の IPv6 アドレス**：`xxxx:....::xx`
- **トンネルのローカル IPv6（ISP 指定の IPv6 アドレス）**  
  （IPv6プレフィックス + 固定の "host part" / **IID** として指定されることがあります）

また、Yamaha RTX などの設定例にある `tunnel encapsulation ipip` 相当の構成を UniFi OS 上で再現します。

> ⚠️ 免責  
> 自己責任で利用してください。UniFi OS / UniFi Network のアップデートで IF 名・iptables チェーン・挙動が変わる可能性があります。

> 🔐 セキュリティ注意  
> ISP の更新 URL / 認証情報などは Git にコミットしないでください。  
> `config/v6plus.env.example` のアドレスは例です。必ず ISP から割り当てられた値に置き換えてください。

---

## 日本固有の注意（v6プラスについて）

「v6プラス（v6 Plus）」は日本の IPoE 環境（主に NTT 東西網系）で使われる **商用サービス名**です。  
日本以外では同種の仕組みは **CGNAT / DS-Lite** など別の用語で語られることが多く、「v6プラス」という名称は基本的に通じません。

技術的には **MAP-E / IPv4 over IPv6** の文脈に近いですが、本 README の UI 用語・想定は日本の ISP 環境寄りです。

---

## このスクリプトがやること

- ISP の BR に向けて **ipip6 トンネル（IPv4-in-IPv6）** を作成
- トンネル IF に **固定 IPv4 /32** を付与
- **LAN から入ってきた転送 IPv4 トラフィックのみ**を、`ip rule ... iif <LAN_IF>` で専用テーブルへ流す（ゲートウェイ自身の通信を巻き込みにくくする）
- **メインテーブルにデフォルトルートを追加**し、ゲートウェイ自身もトンネル経由でインターネットに到達できるようにする
- ISP 指定のトンネルローカル IPv6 を WAN に **/128** で追加（/64 を避け、副作用を抑える）
- LAN -> トンネルへの **SNAT（固定 IPv4 へ）**
- 安定化のため **TCP MSS clamp** を追加

---

## 前提条件（UniFi Network UI の設定）

スクリプト実行前に、UniFi Network を以下の状態にしておきます：

1) WAN の IPv4 を **DHCPv4** にする
2) WAN の IPv6 を **DHCPv6** にする（IPv6 + PD を受け取るため）
3) LAN 側の IPv6 を **Prefix Delegation（PD）** にする

> **なぜ MAP-E / v6 Plus ではなく DHCPv4 なのか？**  
> MAP-E / v6 Plus に設定すると、UniFi が独自の `ip6tnl1` トンネルを作成し、カスタムトンネルと競合するポリシールーティングルール（table 201）を追加してしまいます。DHCPv4 + DHCPv6 にすることで UniFi は競合するトンネルを作らなくなり、`v6plus0` がクリーンに動作します。

### 1) Internet（WAN）：DHCPv4 + IPv6 DHCPv6

開く：

- `UniFi Network` → `Settings` → `Internet`  
  URL（例）：`https://192.168.1.1/network/default/settings/internet`

対象の WAN を編集して設定：

**IPv4 Configuration**
- **Connection**：`DHCPv4`

**IPv6 Configuration**
- **Connection**：`DHCPv6`

Apply/Save。

### 2) Networks（LAN）：IPv6 Interface Type = Prefix Delegation

開く：

- `UniFi Network` → `Settings` → `Networks`  
  URL（例）：`https://192.168.1.1/network/default/settings/networks`

LAN（例：`Default`）を編集して設定：

**IPv6**
- **Interface Type**：`Prefix Delegation`
- **Prefix Delegation Interface**：上で設定した WAN を選択

Apply/Save。

---

## リポジトリ構成

```text
unifi-v6plus-static-ip/
  README.md
  README.ja.md
  LICENSE
  scripts/
    v6plus-static-ip-iif.sh
    v6plus-watch.sh
    v6plus-diag.sh
  config/
    v6plus.env.example
  systemd/
    v6plus-static-ip.service
    v6plus-watch.service
```

---

## クイックスタート（SCP 前提）

この手順は「PC から gateway に **SCP でファイルを転送**して実行する」前提です。

### 0) SSH を有効化

UniFi の設定から SSH を有効化し、PC 側で `ssh` / `scp` が使えることを確認してください。  
以下の例では gateway の IP を `192.168.1.1` としています（環境に合わせて変更）。

### 1) PC から `/data` にファイルを転送

PC 側（このリポジトリのディレクトリで）：

```sh
# メインスクリプトを転送
scp scripts/v6plus-static-ip-iif.sh root@192.168.1.1:/data/v6plus-static-ip-iif.sh

# watchdog スクリプトを転送
scp scripts/v6plus-watch.sh root@192.168.1.1:/data/v6plus-watch.sh

# 診断スクリプトを転送
scp scripts/v6plus-diag.sh root@192.168.1.1:/data/v6plus-diag.sh

# env を転送（gateway 側で編集します）
scp config/v6plus.env.example root@192.168.1.1:/data/v6plus.env
```

> `/data` は UniFi OS の永続領域です（再起動してもファイルは残ります）。

### 2) gateway に SSH して env を編集

```sh
ssh root@192.168.1.1
vi /data/v6plus.env
```

最低限必要な項目：

- `WAN_IF`（WAN の IF 名）
- `LAN_IF`（多くは `br0`）
- `LAN_CIDR`（例：`192.168.1.0/24`）
- `STATIC_V4`（固定 IPv4）
- `PROVIDER_ASSIGNED_LOCAL_V6`（トンネルローカル IPv6、WAN に /128 で追加）
- `BR_V6`（BR の IPv6）
- `TUN_IF`（例：`v6plus0`）
- `TUN_MTU`, `MSS`
- `ROUTE_TABLE`, `RULE_PREF`

IF 名の確認：

```sh
ip link
ip -6 addr
```

### 3) 実行権限付与

```sh
chmod +x /data/v6plus-static-ip-iif.sh
chmod +x /data/v6plus-watch.sh
chmod +x /data/v6plus-diag.sh
```

### 4) 適用（apply）

```sh
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh apply
```

### 5) 状態確認（status）

```sh
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh status
# または診断スクリプトを使う
/data/v6plus-diag.sh
```

### 6) 無効化（off）

```sh
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh off
```

---

## 永続化（再起動後も維持する）

UniFi OS は再起動のたびにトンネル / ip rule / iptables をリセットします。**systemd** を使って永続化します。

> **注意：** UDR/UDM では、systemd ユニットファイルは `/etc/systemd/system/` に**実ファイルとして**配置する必要があります。`/data` へのシンボリックリンクは**動作しません**。

### systemd サービスのインストール

PC からゲートウェイにサービスファイルを転送：

```sh
scp systemd/v6plus-static-ip.service root@192.168.1.1:/etc/systemd/system/
scp systemd/v6plus-watch.service root@192.168.1.1:/etc/systemd/system/
```

有効化して起動：

```sh
ssh root@192.168.1.1
systemctl daemon-reload
systemctl enable v6plus-static-ip.service
systemctl enable v6plus-watch.service
systemctl start v6plus-static-ip.service
systemctl start v6plus-watch.service
```

状態確認：

```sh
systemctl status v6plus-static-ip.service
systemctl status v6plus-watch.service
journalctl -t v6plus-watch -f
```

---

## Watchdog について

`v6plus-watch.sh` は systemd サービスとして動作し、以下の3つを担当します：

1. **SNAT 監視**：WiFi 設定変更など UniFi が設定変更を行った際に SNAT ルールが消えた場合、自動的に `apply` を再実行します。
2. **ルーティング競合の解消**：UniFi が生成する競合するポリシールーティングルール（table 201 / ip6tnl1）を削除し、カスタムトンネルが正しく動作するようにします。
3. **dpinger の乗っ取り**：UniFi の WAN 死活監視プロセス（dpinger）を DS-Lite トンネルインターフェースではなく `v6plus0` 経由で動作させることで、Site Manager がゲートウェイをオンラインと認識できるようにします。

---

## 動作確認（Validation）

```sh
# IPv4：固定IPになっているか（ゲートウェイから実行）
curl -4 -s --interface <TUN_IF> https://api.ipify.org ; echo

# IPv4：LAN クライアントから確認
curl -4 -s https://api.ipify.org ; echo

# IPv6：ネイティブIPv6が生きているか
curl -6 -s https://api6.ipify.org ; echo

# ルールとルーティング
ip -4 rule
ip -4 route show table 300
ip -d link show v6plus0
```

---

## 既知の制限

- **UniFi UI の WAN IP が `192.0.0.2` と表示される**（DS-Lite の CGNAT アドレス）。これは正常です。実際の送信元 IP は固定 IPv4 です。`curl -4 -s --interface <TUN_IF> https://api.ipify.org` で確認できます。

- **UI の Uptime / Internet Down 表示**：watchdog が `dpinger` を乗っ取ることで Site Manager の認識は改善されますが、UI 上の WAN IP は `192.0.0.2` のままになります。

---

## よくある罠（Common pitfalls）

- ISP 指定のトンネルローカル IPv6 を `/64` で持つと、送信元 IPv6 選択などで副作用が出ることがあります。本リポジトリは WAN に **/128** で追加します。

- `ip rule from 192.168.1.0/24 lookup 300` のようなルールは、ゲートウェイ自身の通信まで巻き込んで UI/SSH が不安定になる場合があります。本リポジトリは **`ip rule ... iif <LAN_IF>`** で LAN から入ってきた転送トラフィックに限定します。

- MTU/MSS が合わないと特定サイトだけ遅い/詰まることがあります。`TUN_MTU` と `MSS` を調整してください。

- **UniFi UI の MSS Clamping 設定は変更しないでください**。カスタムの iptables ルールと干渉する可能性があります。MSS の管理はスクリプト（`v6plus.env`）に任せてください。

- **WAN を MAP-E / v6 Plus に設定しないでください**。UniFi が競合する `ip6tnl1` トンネルと table 201 のルーティングルールを作成し、`v6plus0` と衝突します。DHCPv4 + DHCPv6 を使用してください。

---

## Acknowledgements

**unifi-utilities/unifios-utilities** のメンテナ・コントリビュータのみなさんに感謝します。on-boot-script-2.x / udm-boot の仕組みは本プロジェクトの初期設計に参考にさせていただきました。
- https://github.com/unifi-utilities/unifios-utilities

また、UDR/UDM では systemd ユニットファイルをシンボリックリンクではなく `/etc/systemd/system/` に実ファイルとして配置する必要があることを発見するきっかけとなったコミュニティの議論にも感謝します。この発見により on-boot-script が不要になりました。

---

## License

MIT. `LICENSE` を参照してください。
