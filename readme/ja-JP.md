<div align="center">

# Godot Graphics Playground

</div>

<div align="center">

[English](../README.md) | [简体中文](zh-CN.md) | 日本語 | [Français](fr-FR.md)

</div>

Godot 4.7.2 の Forward+ でリアルタイム照明、地面を流れる霧、キャラクターの動きを試せるシーン集です。

![Sponza の中央通路、アーチの回廊、中庭の中央からの広角写真、日差しの入る中庭](images/sponza-restir.jpg)

*Intel Sponza 2022 · Vulkan · Split Radiance Cascades による 2 バウンスの間接照明。上段は ReSTIR DI で照らした中央通路と回廊です。左下は中庭の中央から広角で捉えた上下階の回廊です。太陽光と[松明を持って歩くシーン](../scenes/sponza_torch_walk.tscn)の回廊灯で照らしています。右下は太陽の直射光とその拡散反射のみです。下段の 2 枚では、空からの環境光と空の映り込みを無効にしています。*

**直接照明（DI）：** ReSTIR DI は前フレームと隣接ピクセルの点光源サンプルを再利用し、現在の表面への寄与に応じて再サンプリングしたうえで、遮蔽判定により影を求めます。
**間接照明（GI）：** Split Radiance Cascades はワールド空間でレイを追跡し、階層化したプローブに入射光を方向別に記録して、2 回目の拡散反射の計算にも使います。

## クイックスタート

### インストール

Godot 4.7.2 と Git LFS をインストールし、アセットを含むプロジェクトを取得します。

```sh
git lfs install
git clone https://github.com/gloridifice/godot-graphics-playground.git
cd godot-graphics-playground
```

`project.godot` を開き、インポートが終わったら **F5** で霧の実験シーンを起動します。

### 更新

プロジェクトのディレクトリで `git pull --ff-only`、続いて `git lfs pull` を実行します。

## 試せること

- Sponza の回廊で、ReSTIR DI と 12 個の点光源をすべて評価した参照画像を比較できます。
- 拡散反射の回数を 1 回と 2 回で切り替え、アーチの天井に届く光の違いを観察できます。
- 地表の霧の中を歩いたり跳んだりして、浅水方程式と Stable Fluids による霧の動きを比較できます。
- [キャラクターデモ](../addons/motion/demo.tscn)では、モーションマッチング、足の接地固定、クライミングを確認できます。

## Vulkan の GPU 計測結果

**RTX 5070 Ti Laptop GPU**（ドライバー 621.01）、Godot 4.7.2 Forward+、ネイティブ解像度 1600 × 900。表紙右上の回廊にカメラを固定し、点光源 12 個、ReSTIR DI、2 バウンス GI を有効にしました。HUD と垂直同期は無効です。

| 1 フレームの GPU 時間（ms） | 中央値 | P95 |
|---|---:|---:|
| ビューポート全体 | 2.927 | 4.635 |
| GI：Prepare から Merge まで | 0.584 | 0.639 |
| DI：時間方向の再利用とシェーディング | 1.059 | 2.643 |
| 共通処理：Receiver と Apply | 0.454 | 0.660 |

240 フレームのウォームアップ後、[計測スクリプト](../tools/profile_sponza_restir.gd)でビューポートを 4,413 回、各パスを 64 回計測しました。全体の時間には Godot の他の描画処理も含まれます。GI と DI の値は各パスの所要時間で、片方だけを有効にした場合のフレーム時間ではありません。

## ソースから表紙のシーンを起動する

インポート後、Godot の実行ファイルに `PATH` を通し、プロジェクトのディレクトリで実行します。

```sh
godot --rendering-driver vulkan scenes/sponza_restir_di.tscn
```

ReSTIR DI と 2 バウンスの GI は起動時から有効です。**B** で 1 バウンスに切り替え、照明が安定してから見比べてください。

## ライセンスとクレジット

[第三者の著作権表示とアセットの利用制限](../THIRD_PARTY.md)、および [Intel Sponza のクレジットとライセンス](../assets/sponza/credits_license.txt)を参照してください。

## 開発資料

- [アーキテクチャ](../doco/architecture.md)
- [Split Radiance Cascades と ReSTIR DI](../addons/split_radiance_cascades/USAGE.md)
- [高さ場を使った霧](../addons/heightfield_fog/README.md)
