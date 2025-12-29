# unifi-v6plus-static-ip（日本語）

[English](README.md) | [日本語](README.ja.md)

UniFi OS ゲートウェイ（UDM / UDR）で、ISP から提供される **v6プラス固定IPv4（/32）** を **IPv4 over IPv6（IPIP6 トンネル）** で通しつつ、**ネイティブ IPv6 をそのまま維持**するためのスクリプト集です。

ISP が以下のような情報を提供するケースを想定しています：

- **固定 IPv4 アドレス**：`x.x.x.x/32`
- **IPv6 プレフィックス**：`xxxx:....::/64`
- **BR（Border Relay）の IPv6 アドレス**：`xxxx:....::xx`
- **トンネルのローカル IPv6（ISP 指定の IPv6 アドレス）**  
  （IPv6プレフィックス + 固定の “host part” / **IID** として指定されることがあります）

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
- ISP 指定のトンネルローカル IPv6 を WAN に **/128** で追加（/64 を避け、副作用を抑える）
- LAN -> トンネルへの **SNAT（固定 IPv4 へ）**
- 安定化のため **TCP MSS clamp** を追加

> 注意：本リポジトリには **死活監視 / watchdog ロジックはありません**（削除済み）。

---

## 前提条件（UniFi Network UI の設定）

スクリプト実行前に、UniFi Network を以下の状態にしておきます：

1) WAN を **IPv4 over IPv6（MAP-E / v6 Plus）** にする  
2) WAN の IPv6 を **DHCPv6** にする（IPv6 + PD を受け取るため）  
3) LAN 側の IPv6 を **Prefix Delegation（PD）** にする

### 1) Internet（WAN）：IPv4 over IPv6（MAP-E / v6 Plus） + IPv6 DHCPv6

開く：

- `UniFi Network` → `Settings` → `Internet`  
  URL（例）：`https://192.168.1.1/network/default/settings/internet`

対象の WAN（例：`Internet 2` / `WAN2`）を編集して設定：

**IPv4 Configuration**
- **Connection**：`IPv4 over IPv6`
- **Type**：`MAP-E`
- **Service**：`v6 Plus`

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
- **Prefix Delegation Interface**：上で設定した WAN（例：`Internet 2`）を選択

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
    on_boot/
      99-v6plus-static-ip.sh
  config/
    v6plus.env.example
```

---

## クイックスタート（SCP 前提）

この手順は「PC から gateway に **SCP でファイルを転送**して実行する」前提です。  
（UniFi OS 上で `apt` や `git` を前提にしません）

### 0) SSH を有効化

UniFi の設定から SSH を有効化し、PC 側で `ssh` / `scp` が使えることを確認してください。  
以下の例では gateway の IP を `192.168.1.1` としています（環境に合わせて変更）。

### 1) PC から `/data` にファイルを転送

PC 側（このリポジトリのディレクトリで）：

```sh
# スクリプトを転送
scp scripts/v6plus-static-ip-iif.sh root@192.168.1.1:/data/v6plus-static-ip-iif.sh

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
```

### 4) 適用（apply）

```sh
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh apply
```

### 5) 状態確認（status）

```sh
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh status
```

### 6) 無効化（off）

```sh
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh off
```

---

## 永続化（再起動後も維持する）

UniFi OS は標準状態では **`/data/on_boot.d` を自動実行しません**。  
このスクリプトが追加する設定（トンネル / ip rule / iptables）は、**再起動で消えます**。

永続化したい場合は、コミュニティの **on-boot runner** を導入するか、再起動のたびに手動で `apply` してください。

### Option A：on-boot-script-2.x を導入（おすすめ）

`unifi-utilities/unifios-utilities` の **on-boot-script-2.x** を入れると、`udm-boot` がセットアップされ、
`/data/on_boot.d/` に置いたスクリプトが起動時に実行されるようになります。

> セキュリティ注意：`curl | sh` 形式です。気になる場合は後述の「download→review→run」を使ってください。

#### 1行インストール（gateway から外向き通信が必要）

```sh
curl -fsL "https://raw.githubusercontent.com/unifi-utilities/unifios-utilities/HEAD/on-boot-script-2.x/remote_install.sh" | /bin/sh
```

#### より安全：ダウンロード → 内容確認 → 実行

`curl | sh` は便利ですが、ダウンロードした内容を **即実行**します。  
実行前に中身を確認したい場合は、いったん保存してレビューしてから実行します：

```sh
curl -fsLo /tmp/remote_install.sh "https://raw.githubusercontent.com/unifi-utilities/unifios-utilities/HEAD/on-boot-script-2.x/remote_install.sh"

# 実行前に内容を確認（UDM/UDR では通常 less が使えます）
less /tmp/remote_install.sh

# 内容に納得したら実行
sh /tmp/remote_install.sh
```

確認：

```sh
ls -la /data/on_boot.d
systemctl status udm-boot --no-pager || true
```

#### ラッパースクリプトの配置

on-boot runner 導入後、`/data/on_boot.d/` にラッパーを置きます：

```sh
mkdir -p /data/on_boot.d

# /data に本体と env があることを確認（永続）
ls -la /data/v6plus-static-ip-iif.sh
ls -la /data/v6plus.env

# ラッパーを配置（※このファイルはPCからSCPで置く or 手元のrepoからコピーしてください）
cp /path/to/repo/scripts/on_boot/99-v6plus-static-ip.sh /data/on_boot.d/99-v6plus-static-ip.sh
chmod +x /data/on_boot.d/99-v6plus-static-ip.sh
```

> ラッパーは以下を前提にしています：
> - `/data/v6plus-static-ip-iif.sh`
> - `/data/v6plus.env`

再起動後に確認：

```sh
ip -d link show v6plus0
ip -4 rule
iptables -t nat -L -n -v | sed -n '1,80p'
```

### Option B：再起動のたびに手動適用

```sh
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh apply
```

---

## 既知の制限（UniFi UI が “Internet Down” のままになることがある）

この構成では、実際の通信が生きていても **UniFi Network / UniFi OS の UI 上で WAN が “Internet Down” のまま表示**されることがあります。

理由（概要）：UniFi の内蔵ヘルスチェック/テレメトリが、固定 IPv4 /32 を IPIP6 + ポリシールーティングで流す経路を正しく認識できず、UI の状態表示が実トラフィックとズレることがあります。

影響：
- UI 上で **Internet Down** が出続ける
- 通知/アラートや一部メトリクスが実態と一致しない可能性がある

実際の疎通確認：

```sh
curl -4 -s https://api.ipify.org ; echo
curl -6 -s https://api6.ipify.org ; echo
```

---

## 動作確認（Validation）

```sh
# IPv4：固定IPになっているか
curl -4 -s https://api.ipify.org ; echo

# IPv6：ネイティブIPv6が生きているか
curl -6 -s https://api6.ipify.org ; echo

# ルールとルーティング
ip -4 rule
ip -4 route show table 300
ip -d link show v6plus0
```

---

## よくある罠（Common pitfalls）

- ISP 指定のトンネルローカル IPv6 を `/64` で持つと、送信元 IPv6 選択などで副作用が出ることがあります。  
  本リポジトリは WAN に **/128** で追加します。

- `ip rule from 192.168.1.0/24 lookup 300` のようなルールは、ゲートウェイ自身の通信まで巻き込んで UI/SSH が不安定になる場合があります。  
  本リポジトリは **`ip rule ... iif <LAN_IF>`** で LAN から入ってきた転送トラフィックに限定します。

- MTU/MSS が合わないと、特定サイトだけ遅い/詰まることがあります。`TUN_MTU` と `MSS` を調整してください。

---

## Acknowledgements

Boot 時実行の仕組みとして、コミュニティの **on-boot-script-2.x / udm-boot** を利用します。  
**unifi-utilities/unifios-utilities** のメンテナ・コントリビュータのみなさんに感謝します。

- https://github.com/unifi-utilities/unifios-utilities

---

## License

MIT. `LICENSE` を参照してください。
