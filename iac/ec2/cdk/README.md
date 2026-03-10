# CDK Infrastructure for vLLM Disaggregated Inference on EC2

CDK スタックで EC2 インスタンスをデプロイします。Single-node と Multi-node の 2 つのモードをサポート。

## デプロイモード

### Single-node モード

1 つの EC2 インスタンスで実行。Aggregated または Disaggregated (同一ノード内) パターンをサポート。

```bash
cdk deploy -c mode=single -c region=ap-northeast-1
```

### Multi-node モード

2 つの EC2 インスタンスで実行。Disaggregated (Producer/Consumer 分離) パターン専用。EFA サポート。

```bash
cdk deploy -c mode=multi -c region=ap-northeast-1
```

## コンテキスト変数

| 変数 | 説明 | デフォルト値 |
|------|------|------------|
| `mode` | デプロイモード (`single` or `multi`) | `single` |
| `region` | AWS リージョン | `CDK_DEFAULT_REGION` |
| `instanceType` | EC2 インスタンスタイプ | `g7e.12xlarge` |
| `availabilityZone` | アベイラビリティゾーン | リージョンの最初の AZ |
| `vpcId` | VPC ID (既存 VPC 使用時) | デフォルト VPC |
| `keyName` | SSH キーペア名 | なし (SSM 推奨) |

## 使用例

### Basic Deployment

```bash
# Single-node (g7e.12xlarge, Tokyo region)
cdk deploy -c mode=single -c region=ap-northeast-1

# Multi-node (g7e.12xlarge x2, Tokyo region)
cdk deploy -c mode=multi -c region=ap-northeast-1
```

### Custom Instance Type

```bash
# Single-node with g7e.8xlarge
cdk deploy -c mode=single \
  -c region=ap-northeast-1 \
  -c instanceType=g7e.8xlarge

# Multi-node with g7e.24xlarge
cdk deploy -c mode=multi \
  -c region=ap-northeast-1 \
  -c instanceType=g7e.24xlarge
```

### Specific AZ

```bash
# Deploy to ap-northeast-1a
cdk deploy -c mode=multi \
  -c region=ap-northeast-1 \
  -c az=ap-northeast-1a
```

### Existing VPC

```bash
# Use existing VPC
cdk deploy -c mode=multi \
  -c region=ap-northeast-1 \
  -c vpcId=vpc-xxxxxxxxx
```

## 前提条件

```bash
# Install dependencies
npm install

# Bootstrap CDK (first time only)
cdk bootstrap aws://ACCOUNT-ID/REGION
```

## CDK コマンド

```bash
# Synthesize CloudFormation template
cdk synth -c mode=single

# Show diff
cdk diff -c mode=multi

# Deploy
cdk deploy -c mode=single

# Destroy
cdk destroy -c mode=single
```

## Outputs

デプロイ後、以下の情報が出力されます:

### Single-node

- `InstanceId` - EC2 インスタンス ID
- `PublicIp` - パブリック IP アドレス
- `PrivateIp` - プライベート IP アドレス
- `ScriptsBucketName` - S3 バケット名
- `SecurityGroupId` - セキュリティグループ ID

### Multi-node

- `Node1InstanceId`, `Node1PublicIp`, `Node1PrivateIp` - Producer ノード情報
- `Node2InstanceId`, `Node2PublicIp`, `Node2PrivateIp` - Consumer ノード情報
- `ScriptsBucketName` - S3 バケット名
- `SecurityGroupId` - セキュリティグループ ID
- `PlacementGroupName` - プレースメントグループ名

## 次のステップ

CDK デプロイ後、`../setup/` のデプロイメントツールを使用してアプリケーションをセットアップします:

```bash
cd ../setup
./deploy.sh --mode single --config configs/my-deployment.env
```

詳細は [../setup/README.md](../setup/README.md) を参照してください。
