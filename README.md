# Terraform Plan Analyzer

jqを使用したTerraform Plan JSONファイルの包括的な分析ツールです。リソース変更とアウトプット変更の詳細な解析機能を提供します。

## 機能

- **リソース変更分析**: create, update, delete, replace, forget, no-op アクションの検出
- **アウトプット変更分析**: 出力値の変更を追跡
- **インポート検出**: リソースのインポート操作を識別
- **複数出力フォーマット**: 基本、簡潔、詳細、no-op専用モード
- **Markdown対応**: GitHub コメント最適化を含む
- **文字数制限チェック**: GitHub コメント用の文字数制限警告

## 基本使用法

### Terraform Plan JSONファイルの生成

```bash
# Terraform plan ファイルを JSON 形式で生成する
terraform plan -out=plan >/dev/null 2>&1
terraform show -json plan > plan.json
```

### スクリプトの実行

```bash
# 基本分析（デフォルト）
./terraform-plan-analyzer.sh plan.json

# 簡潔表示（diff形式、no-op除く）
./terraform-plan-analyzer.sh --short plan.json

# 詳細表示（アクション種類別にグループ化）
./terraform-plan-analyzer.sh --detail plan.json

# no-opリソースのみ表示
./terraform-plan-analyzer.sh --no-op plan.json

# Markdown形式で出力
./terraform-plan-analyzer.sh --markdown plan.json
./terraform-plan-analyzer.sh --short --markdown plan.json
./terraform-plan-analyzer.sh --detail --markdown plan.json

# GitHub コメント最適化（文字数制限チェック付き）
./terraform-plan-analyzer.sh --github-comment plan.json
```

## オプション

| オプション | 説明 |
|-----------|------|
| `--short` | 簡潔な diff 形式で変更のみ表示 |
| `--detail` | アクション種類別に詳細にグループ化して表示 |
| `--no-op` | 変更のないリソース（no-op）のみ表示 |
| `--markdown` | Markdown形式で出力 |
| `--github-comment` | GitHub コメント用に最適化（文字数制限チェック付き） |
| `-h, --help` | ヘルプメッセージを表示 |

## 出力例

### 基本モード（デフォルト）
```
🔍 Terraform Plan Analysis for: plan.json
==============================================

📊 Change Actions Summary:
-------------------------
create: 5
update: 2
delete: 3

📊 Resource Types:
-----------------
  aws_s3_bucket: 3
  aws_iam_role: 2  
  aws_lambda_function: 2

📊 Plan Summary:
---------------
Terraform Version: 1.0.0
Total Resource Changes: 7
Applyable: true
```

### --short モード
```
+ aws_s3_bucket.example
+ aws_s3_bucket.logs
~ aws_iam_role.lambda_role
~ aws_lambda_function.processor
- aws_s3_bucket.old_bucket
-/+ aws_lambda_function.migrated Import
+ output.bucket_name
```

### --detail モード
```
📊 Resource Changes Detail:
===========================

📊 CREATE Actions:
==================
  - aws_s3_bucket.example
  - aws_s3_bucket.logs

📊 UPDATE Actions:
==================
  - aws_iam_role.lambda_role
  - aws_lambda_function.processor

📊 DELETE Actions:
==================
  - aws_s3_bucket.old_bucket

📊 REPLACE Actions:
===================
  - aws_lambda_function.migrated Import

📊 OUTPUT CREATE Actions:
=========================
  - bucket_name

📊 Summary:
  Resource Changes:
    create: 2
    update: 2
    delete: 1
    replace: 1
    importing: 1
  Output Changes:
    create: 1
```

### Markdownモード
```markdown
# Terraform Plan Analysis

**File:** `plan.json`

## Change Actions Summary

- **create**: 2
- **update**: 2
- **delete**: 1
- **importing**: 1

## Resource Types

- **aws_lambda_function**: 2
- **aws_s3_bucket**: 2
- **aws_iam_role**: 1

## Plan Summary

- **Terraform Version**: 1.0.0
- **Total Resource Changes**: 5
- **Applyable**: true
```

## よく使うjqクエリ

### 基本的な集計
```bash
# アクション種類ごとの個数集計
jq '[.resource_changes[].change.actions[]] | group_by(.) | map({action: .[0], count: length})' plan.json
```

### 実用的なクエリ
```bash
# 削除されるリソース一覧
jq '.resource_changes[] | select(.change.actions[] == "delete") | .address' plan.json

# 作成されるリソース一覧
jq '.resource_changes[] | select(.change.actions[] == "create") | .address' plan.json

# 更新されるリソース一覧
jq '.resource_changes[] | select(.change.actions[] == "update") | .address' plan.json
```

## ファイル構成

```
├── README.md                   # このファイル
└── terraform-plan-analyzer.sh  # Terraform Plan分析スクリプト
```

## アクション種類

| シンボル | アクション | 説明 |
|---------|-----------|------|
| `+` | create | 新しいリソースの作成 |
| `~` | update | 既存リソースの更新 |
| `-` | delete | リソースの削除 |
| `-/+` | replace | リソースの置換（削除→作成） |
| `#` | forget | リソースの管理から除外 |
| (なし) | no-op | 変更なし |

## 特殊表示

- `Import`: インポート操作を伴うリソース
- `output.`: 出力値の変更

## 依存関係

- **jq**: JSON処理に必要。インストールコマンド：
  - macOS: `brew install jq`
  - Ubuntu/Debian: `sudo apt-get install jq`
  - CentOS/RHEL: `sudo yum install jq`

---

**Note:** 
- `--short` および `--detail` オプションでは、`no-op` アクションは非表示になります
- `--github-comment` オプションは65,536文字の制限をチェックし、超過時に警告を表示します
- スクリプトは自動的にjqの存在をチェックし、不足時にインストール手順を表示します
