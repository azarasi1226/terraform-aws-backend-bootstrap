# terraform-aws-backend-bootstrap

Terraform の S3 backend 用バケットを作成するスクリプトです。

backend のバケットは Terraform 自身では作れないため、各リポジトリで Terraform を使い始める前に一度だけ実行します。

## 作成されるバケットの設定

| 設定 | 内容 |
|---|---|
| パブリックアクセスブロック | すべて有効 |
| ACL | 無効（BucketOwnerEnforced） |
| バージョニング | 有効。state を誤って壊したときに過去のバージョンへ戻せる |
| 暗号化 | SSE-S3。`--kms-key-id` を指定した場合は KMS |
| バケットポリシー | TLS 以外のアクセスを拒否 |
| ライフサイクル | 古いバージョンを90日後に削除（`--noncurrent-days` で変更可） |
| タグ | `ManagedBy=manual`（`--tag` で追加可） |

state のロックは S3 のロックファイル（`use_lockfile = true`、Terraform 1.10 以上）を使うため、DynamoDB テーブルは作成しません。

既にバケットがある場合は、作成をスキップして設定だけを適用し直します。

## 使い方

```bash
export AWS_PROFILE=<バケットを作るアカウントのプロファイル>

# 実行内容の確認
./create-tf-backend.sh -b example-tfstate --dry-run

# 作成
./create-tf-backend.sh -b example-tfstate -k aws-organization/root-ou.tfstate
```

最後に `backend.hcl` の例が出力されるので、各リポジトリの `backend.hcl` に貼り付けて使います。

```bash
terraform init -backend-config=backend.hcl
```

オプションの一覧は `./create-tf-backend.sh --help` で確認できます。

## 前提条件

- AWS CLI v2
- バケットを作るアカウントで、S3 の操作と `sts:GetCallerIdentity` ができる権限
# terraform-aws-backend-bootstrap
