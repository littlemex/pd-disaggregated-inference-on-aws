# EC2 ベースのデプロイ

シンプルで直接的な EC2 インスタンスベースのデプロイ、開発・テスト向けの実装例です。

## ディレクトリ構成

```
ec2/
├── cdk/                    # CDK インフラ定義
│   ├── lib/
│   │   ├── single-node-stack.ts   # Single-node スタック
│   │   └── multi-node-stack.ts    # Multi-node スタック
│   ├── bin/
│   │   └── app.ts                 # CDK アプリ (--mode で切り替え)
│   ├── package.json
│   └── cdk.json
└── setup/                  # デプロイメントツール
    ├── deploy.sh           # メインデプロイスクリプト
    ├── ssm_helper.sh       # SSM コマンド実行
    ├── tasks/              # JSON タスク定義
    ├── configs/            # デプロイ設定
    └── scripts/            # ユーティリティスクリプト
```

## デプロイモード

### Single-node モード

1 つの EC2 インスタンスで実行。Aggregated または Disaggregated (同一ノード内) パターンをサポート。

**用途**:
- 開発・検証
- 小規模推論ワークロード
- コスト重視

**インスタンスタイプ例**:
- `g7e.8xlarge` (1x RTX PRO 6000 Blackwell 48GB)
- `g7e.12xlarge` (2x RTX PRO 6000 Blackwell 96GB)

### Multi-node モード

2 つの EC2 インスタンスで実行。Disaggregated (Producer/Consumer 分離) パターン専用。

**用途**:
- Prefill/Decode 分離の性能測定
- EFA 通信の評価
- 本番環境 (小規模)

**インスタンスタイプ例**:
- Node1 (Producer): `g7e.8xlarge` (2 GPU)
- Node2 (Consumer): `g7e.8xlarge` (2 GPU)

## クイックスタート

### 1. インフラのデプロイ

```bash
cd cdk

# Single-node
npm install

cdk deploy -c mode=single -c region=ap-northeast-1 -c instance-type=g7e.8xlarge
cdk deploy -c mode=multi  -c region=ap-northeast-1 -c instance-type=g7e.8xlarge
```

```bash

 ✅  pd-di-single-ap-northeast-1

✨  Deployment time: 175.74s

Outputs:
pd-di-single-ap-northeast-1.InstanceId = i-0332f047734a1ec51
pd-di-single-ap-northeast-1.PrivateIp = 172.31.36.161
pd-di-single-ap-northeast-1.PublicIp = 57.180.53.50
pd-di-single-ap-northeast-1.ScriptsBucketName = pd-di-single-ap-northeast-1-XXXXXXXX
pd-di-single-ap-northeast-1.SecurityGroupId = sg-0acd067492acbf799
```

### 2. アプリケーションのデプロイ

```bash
cd ../setup

# 設定ファイルの作成(シングルの場合)
cp configs/example-single.env configs/my-deployment.env
# 上記の CDK Output の出力値を入れてください
# TENSOR_PARALLEL_SIZE="1" の部分は使うインスタンスに合わせて変えてください
vim configs/my-deployment.env

# デプロイ実行
./deploy.sh --mode single --config configs/my-deployment.env
# または
./deploy.sh --mode multi --config configs/my-deployment.env
```

```bash
./deploy.sh --mode single --config configs/my-deployment.env
[16:48:03] Writing config to Parameter Store: /vllm-di/single/config
{
    "Version": 3,
    "Tier": "Standard"
}
[OK] Config written to Parameter Store
[16:48:04] Uploading Docker build context to S3...
[OK] Upload complete
[16:48:06] Setting up i-0332f047734a1ec51...
[16:48:06] Uploading setup-environment.sh to S3...
[16:48:07] Running SSM command on i-0332f047734a1ec51...
[DEBUG] Command to be executed:
export HOME=/root && export PARAM_NAME='/vllm-di/single/config' && export AWS_REGION='ap-northeast-1' && aws s3 cp s3://pd-di-single-ap-northeast-1-scriptsbucketXXXXXX/scripts/setup-environment.sh /tmp/setup-environment.sh --region ap-northeast-1 --quiet && chmod +x /tmp/setup-environment.sh && bash /tmp/setup-environment.sh && rm -f /tmp/setup-environment.sh

[16:48:08] Waiting for command 1c270e30-706f-46d9-b4c7-2c0f4cb2b766 to complete (timeout: 600s)...
.[OK] Command completed successfully

Next steps:
  ./deploy.sh --mode single --config configs/my-deployment.env --task test-single-node-aggregated
```

### 3. テストの実行

コンテナのビルドを実行するため 10 分以上かかる可能性があります。EC2 上でのコンテナのビルドから推論が動作するところまでを確認します。測定は行いません。

```bash
# Aggregated パターン (single-node のみ)
./deploy.sh --mode single --config configs/my-deployment.env --task test-single-node-aggregated

# Disaggregated パターン (single-node)
./deploy.sh --mode single --config configs/my-deployment.env --task test-single-node-disaggregated

# Disaggregated パターン (multi-node)
./deploy.sh --mode multi --config configs/my-deployment.env --task test-multi-node-disaggregated

# ログ確認
./deploy.sh --logs
```

```bash
./deploy.sh --logs
...
[06] Testing inference...
{"id":"cmpl-830c9643bdef7b6b","object":"text_completion","created":1773163335,"model":"Qwen/Qwen2.
5-32B-Instruct","choices":[{"index":0,"text":"1. The problem statement, all variables and given","
logprobs":null,"finish_reason":"length","stop_reason":null,"token_ids":null,"prompt_logprobs":null
,"prompt_token_ids":null}],"service_tier":null,"system_fingerprint":null,"usage":{"prompt_tokens":
3,"total_tokens":13,"completion_tokens":10,"prompt_tokens_details":null},"kv_transfer_params":null
}
[OK] Done
```

## 設定ファイル

`configs/my-deployment.env` の例:

```bash
# AWS 設定
AWS_REGION="ap-northeast-1"
S3_BUCKET="pd-di-single-ap-northeast-1-scriptsbucket40feb4b1-xxxx"

# Single-node 設定
NODE_INSTANCE_ID="i-xxxxxxxxxxxxx"
NODE_PRIVATE_IP="172.31.x.x"

# Multi-node 設定 (multi モード時のみ)
NODE1_INSTANCE_ID="i-xxxxxxxxxxxxx"  # Producer
NODE2_INSTANCE_ID="i-xxxxxxxxxxxxx"  # Consumer
NODE1_PRIVATE_IP="172.31.x.x"
NODE2_PRIVATE_IP="172.31.x.x"

# vLLM 設定
MODEL_NAME="Qwen/Qwen2.5-32B-Instruct"
ENGINE_ID="pd-di-$(date +%Y%m%d)"

# NIXL 設定
UCX_TLS="tcp,self,sm"  # または "srd,self,sm" (EFA)
KV_BUFFER_DEVICE="cpu"
```

## タスク定義

`tasks/` ディレクトリのスクリプトファイルでデプロイタスクを実施します。

- `test-single-node-aggregated.sh` - Aggregated パターンのテスト
- `test-single-node-disaggregated.sh` - Disaggregated (single-node) のテスト
- `test-multi-node-disaggregated.sh` - Disaggregated (multi-node) のテスト

詳細は [setup/README.md](setup/README.md) を参照。