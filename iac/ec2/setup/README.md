# EC2 Setup Scripts

SSM + S3 + Parameter Store ベースのデプロイツールです。EC2 上で vLLM コンテナを起動・テストします。

## ファイル構成

```
setup/
├── deploy.sh           # メインデプロイスクリプト
├── ssm_helper.sh       # SSM コマンド実行ヘルパー
├── configs/            # デプロイ設定
├── tasks/              # JSON タスク定義
└── scripts/            # ユーティリティスクリプト
```

## 仕組み

1. `deploy.sh` が `configs/*.env` を読み込む
2. 全設定を JSON にまとめて SSM Parameter Store に書き込む
3. タスクスクリプト (`tasks/*.sh`) を S3 経由でリモートに送信
4. SSM send-command でリモート実行
5. リモートスクリプトは Parameter Store から設定を取得して Docker コンテナを起動

スクリプトはそのまま送信されます（テンプレート展開なし）。

## ssm_helper.sh の主要関数

```
source ssm_helper.sh

# コマンド実行して完了を待つ
ssm_run_and_wait <instance-id> <region> <command> [timeout]

# スクリプトを S3 経由で送信・実行
ssm_run_script <instance-id> <region> <s3-bucket> <script> [timeout]

# スクリプトを送信・実行 (PARAM_NAME, AWS_REGION を注入)
ssm_run_script_with_param <instance-id> <region> <s3-bucket> <script> <param-name> [timeout]

# コマンド出力を取得
ssm_get_output <command-id> <instance-id> <region>
```