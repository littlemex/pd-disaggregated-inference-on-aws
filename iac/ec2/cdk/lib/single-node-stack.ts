import {
  Stack,
  StackProps,
  CfnOutput,
  Fn,
  RemovalPolicy,
} from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as s3 from "aws-cdk-lib/aws-s3";
import { Construct } from "constructs";

/**
 * Recommended volume sizes by instance type (in GB)
 */
const RECOMMENDED_VOLUME_SIZES: Record<string, number> = {
  "g5.xlarge": 100, "g5.2xlarge": 150, "g5.4xlarge": 200, "g5.8xlarge": 200,
  "g5.12xlarge": 200, "g5.24xlarge": 300, "g5.48xlarge": 500,
  "g6.xlarge": 100, "g6.2xlarge": 150, "g6.4xlarge": 200, "g6.8xlarge": 200,
  "g6.12xlarge": 200, "g6.24xlarge": 300, "g6.48xlarge": 500,
  "g6e.xlarge": 100, "g6e.2xlarge": 150, "g6e.4xlarge": 200, "g6e.8xlarge": 200,
  "g6e.12xlarge": 200, "g6e.24xlarge": 300, "g6e.48xlarge": 500,
  "g7e.xlarge": 100, "g7e.2xlarge": 150, "g7e.4xlarge": 200, "g7e.8xlarge": 300,
  "g7e.12xlarge": 300, "g7e.24xlarge": 500, "g7e.48xlarge": 1000,
};

export interface SingleNodeStackProps extends StackProps {
  /** EC2 instance type. */
  instanceType?: string;

  /** SSH key pair name (optional). SSM Session Manager is recommended. */
  keyName?: string;

  /** Root volume size in GB. */
  volumeSize?: number;

  /** Availability zone. If not specified, uses the first AZ in the region. */
  availabilityZone?: string;

  /** VPC ID. If not specified, uses the default VPC. */
  vpcId?: string;

  /** Create a new VPC if vpcId is not specified and default VPC doesn't exist. */
  createVpc?: boolean;
}

export class SingleNodeStack extends Stack {
  public readonly instance: ec2.CfnInstance;
  public readonly securityGroup: ec2.ISecurityGroup;
  public readonly vpc: ec2.IVpc;
  public readonly scriptsBucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: SingleNodeStackProps) {
    super(scope, id, props);

    const {
      instanceType = "g7e.12xlarge",
      keyName,
      volumeSize,
      availabilityZone,
      vpcId,
      createVpc = false,
    } = props;

    // Determine volume size
    const recommendedVolumeSize = RECOMMENDED_VOLUME_SIZES[instanceType] || 200;
    const finalVolumeSize = volumeSize || recommendedVolumeSize;

    // VPC
    this.vpc = this.resolveVpc(vpcId, createVpc, availabilityZone);

    // AMI: Deep Learning OSS Nvidia Driver AMI (Ubuntu 24.04)
    const ami = ec2.MachineImage.lookup({
      name: "Deep Learning OSS Nvidia Driver AMI GPU PyTorch * (Ubuntu 24.04) *",
      owners: ["amazon"],
    });

    // Security Group
    this.securityGroup = new ec2.SecurityGroup(this, "SecurityGroup", {
      vpc: this.vpc,
      description: "Security group for single-node inference",
      allowAllOutbound: true,
    });

    // vLLM HTTP access (VPC only for production, or allow from specific IP for development)
    this.securityGroup.addIngressRule(
      ec2.Peer.ipv4(this.vpc.vpcCidrBlock),
      ec2.Port.tcp(8000),
      "Allow vLLM HTTP from VPC"
    );

    // Aggregated mode: single port 8000
    // Disaggregated mode: Producer 8100, Consumer 8200, Proxy 8000
    this.securityGroup.addIngressRule(
      ec2.Peer.ipv4(this.vpc.vpcCidrBlock),
      ec2.Port.tcp(8100),
      "Allow Producer API from VPC"
    );

    this.securityGroup.addIngressRule(
      ec2.Peer.ipv4(this.vpc.vpcCidrBlock),
      ec2.Port.tcp(8200),
      "Allow Consumer API from VPC"
    );

    // S3 Bucket for Scripts
    this.scriptsBucket = new s3.Bucket(this, "ScriptsBucket", {
      removalPolicy: RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      versioned: false,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
    });

    // IAM Role for EC2 with SSM
    const ec2Role = new iam.Role(this, "InstanceRole", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      description: "IAM role for EC2 instance with SSM and S3 access",
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore"),
      ],
    });

    this.scriptsBucket.grantReadWrite(ec2Role);

    ec2Role.addToPolicy(
      new iam.PolicyStatement({
        actions: [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ],
        resources: [
          `arn:aws:logs:${this.region}:${this.account}:log-group:/aws/ssm/*`,
        ],
      })
    );

    const instanceProfile = new iam.CfnInstanceProfile(this, "InstanceProfile", {
      roles: [ec2Role.roleName],
    });

    // User Data
    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      "#!/bin/bash",
      `echo 'export AWS_DEFAULT_REGION="${this.region}"' >> /etc/environment`,
      "apt-get update -qq",
      "apt-get install -y -qq jq docker.io docker-compose",
      "systemctl enable docker",
      "systemctl start docker",
      "usermod -aG docker ubuntu",
    );

    // Subnet
    const actualAz = availabilityZone || this.vpc.availabilityZones[0];
    const subnetSelection = availabilityZone
      ? { availabilityZones: [actualAz], onePerAz: true }
      : { onePerAz: true };

    const selectedSubnets = this.vpc.selectSubnets(subnetSelection).subnets;

    if (selectedSubnets.length === 0) {
      throw new Error(
        `No subnets found in VPC ${this.vpc.vpcId} for AZ ${actualAz}`
      );
    }

    const subnet = selectedSubnets[0];

    // EC2 Instance
    this.instance = new ec2.CfnInstance(this, "Instance", {
      imageId: ami.getImage(this).imageId,
      instanceType,
      keyName,
      availabilityZone: actualAz,
      iamInstanceProfile: instanceProfile.ref,
      subnetId: subnet.subnetId,
      securityGroupIds: [this.securityGroup.securityGroupId],
      blockDeviceMappings: [
        {
          deviceName: "/dev/sda1",
          ebs: {
            volumeSize: finalVolumeSize,
            volumeType: "gp3",
          },
        },
      ],
      userData: Fn.base64(userData.render()),
      tags: [
        { key: "Name", value: "pd-di-single-node" },
        { key: "Mode", value: "single" },
      ],
    });

    // Outputs
    new CfnOutput(this, "InstanceId", {
      value: this.instance.ref,
      description: "EC2 instance ID",
      exportName: `${this.stackName}-InstanceId`,
    });

    new CfnOutput(this, "PublicIp", {
      value: this.instance.attrPublicIp,
      description: "Public IP address",
      exportName: `${this.stackName}-PublicIp`,
    });

    new CfnOutput(this, "PrivateIp", {
      value: this.instance.attrPrivateIp,
      description: "Private IP address",
      exportName: `${this.stackName}-PrivateIp`,
    });

    new CfnOutput(this, "ScriptsBucketName", {
      value: this.scriptsBucket.bucketName,
      description: "S3 bucket for scripts and configurations",
      exportName: `${this.stackName}-ScriptsBucketName`,
    });

    new CfnOutput(this, "SecurityGroupId", {
      value: this.securityGroup.securityGroupId,
      description: "Security group ID",
      exportName: `${this.stackName}-SecurityGroupId`,
    });
  }

  private resolveVpc(vpcId?: string, createVpc?: boolean, az?: string): ec2.IVpc {
    if (vpcId) {
      return ec2.Vpc.fromLookup(this, "ExistingVpc", { vpcId });
    }

    if (createVpc) {
      const vpcConfig: ec2.VpcProps = az
        ? {
            availabilityZones: [az],
            natGateways: 0,
            subnetConfiguration: [
              {
                cidrMask: 24,
                name: "Public",
                subnetType: ec2.SubnetType.PUBLIC,
              },
            ],
          }
        : {
            maxAzs: 2,
            natGateways: 0,
            subnetConfiguration: [
              {
                cidrMask: 24,
                name: "Public",
                subnetType: ec2.SubnetType.PUBLIC,
              },
            ],
          };

      return new ec2.Vpc(this, "Vpc", vpcConfig);
    }

    return ec2.Vpc.fromLookup(this, "DefaultVpc", { isDefault: true });
  }
}
