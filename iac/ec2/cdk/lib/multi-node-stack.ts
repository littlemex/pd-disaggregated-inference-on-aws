import {
  Stack,
  StackProps,
  CfnOutput,
  Fn,
  RemovalPolicy,
  Annotations,
} from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as s3 from "aws-cdk-lib/aws-s3";
import { Construct } from "constructs";

/**
 * EFA-supported instance types
 */
const EFA_SUPPORTED_INSTANCE_TYPES = [
  "g5.12xlarge", "g5.24xlarge", "g5.48xlarge",
  "g6.12xlarge", "g6.24xlarge", "g6.48xlarge",
  "g6e.12xlarge", "g6e.24xlarge", "g6e.48xlarge",
  "g7e.8xlarge", "g7e.12xlarge", "g7e.24xlarge", "g7e.48xlarge",
  "p4d.24xlarge", "p4de.24xlarge", "p5.48xlarge",
  "trn1.32xlarge", "trn1n.32xlarge",
  "inf2.24xlarge", "inf2.48xlarge",
];

/**
 * Recommended volume sizes by instance type (in GB)
 */
const RECOMMENDED_VOLUME_SIZES: Record<string, number> = {
  "g5.12xlarge": 200, "g5.24xlarge": 300, "g5.48xlarge": 500,
  "g6.12xlarge": 200, "g6.24xlarge": 300, "g6.48xlarge": 500,
  "g6e.12xlarge": 200, "g6e.24xlarge": 300, "g6e.48xlarge": 500,
  "g7e.8xlarge": 300, "g7e.12xlarge": 300, "g7e.24xlarge": 500, "g7e.48xlarge": 1000,
  "p4d.24xlarge": 500, "p4de.24xlarge": 500, "p5.48xlarge": 1000,
  "trn1.32xlarge": 500, "trn1n.32xlarge": 500,
  "inf2.24xlarge": 300, "inf2.48xlarge": 500,
};

export interface MultiNodeStackProps extends StackProps {
  /** EC2 instance type. Must support EFA. */
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

export class MultiNodeStack extends Stack {
  public readonly node1: ec2.CfnInstance;
  public readonly node2: ec2.CfnInstance;
  public readonly securityGroup: ec2.ISecurityGroup;
  public readonly placementGroup: ec2.CfnPlacementGroup;
  public readonly vpc: ec2.IVpc;
  public readonly scriptsBucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: MultiNodeStackProps) {
    super(scope, id, props);

    const {
      instanceType = "g7e.12xlarge",
      keyName,
      volumeSize,
      availabilityZone,
      vpcId,
      createVpc = false,
    } = props;

    // Validate instance type
    if (!EFA_SUPPORTED_INSTANCE_TYPES.includes(instanceType)) {
      Annotations.of(this).addWarning(
        `Instance type ${instanceType} may not support EFA. ` +
        `Supported types: ${EFA_SUPPORTED_INSTANCE_TYPES.join(", ")}`
      );
    }

    // Determine volume size
    const recommendedVolumeSize = RECOMMENDED_VOLUME_SIZES[instanceType] || 200;
    const finalVolumeSize = volumeSize || recommendedVolumeSize;

    if (volumeSize && volumeSize < recommendedVolumeSize * 0.8) {
      Annotations.of(this).addWarning(
        `Volume size ${volumeSize}GB is smaller than recommended ${recommendedVolumeSize}GB for ${instanceType}`
      );
    }

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
      description: "Security group for multi-node disaggregated inference",
      allowAllOutbound: true,
    });

    // vLLM HTTP access (VPC only)
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

    // Proxy server
    this.securityGroup.addIngressRule(
      ec2.Peer.ipv4(this.vpc.vpcCidrBlock),
      ec2.Port.tcp(8000),
      "Allow Proxy from VPC"
    );

    // All traffic within security group (for EFA)
    this.securityGroup.addIngressRule(
      this.securityGroup,
      ec2.Port.allTraffic(),
      "All traffic within security group for EFA"
    );

    // Placement Group
    this.placementGroup = new ec2.CfnPlacementGroup(this, "PlacementGroup", {
      strategy: "cluster",
    });

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
      description: "IAM role for EC2 instances with SSM and S3 access",
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
      'echo \'export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libibverbs.so.1\' >> /etc/environment',
      "apt-get update -qq",
      "apt-get install -y -qq jq",
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

    // EFA Network Interface: Node 1
    const node1Efa = new ec2.CfnNetworkInterface(this, "Node1EfaInterface", {
      subnetId: subnet.subnetId,
      groupSet: [this.securityGroup.securityGroupId],
      interfaceType: "efa",
      tags: [{ key: "Name", value: "node1-efa" }],
    });

    // EFA Network Interface: Node 2
    const node2Efa = new ec2.CfnNetworkInterface(this, "Node2EfaInterface", {
      subnetId: subnet.subnetId,
      groupSet: [this.securityGroup.securityGroupId],
      interfaceType: "efa",
      tags: [{ key: "Name", value: "node2-efa" }],
    });

    // EC2 Instance: Node 1 (Producer)
    this.node1 = new ec2.CfnInstance(this, "Node1", {
      imageId: ami.getImage(this).imageId,
      instanceType,
      keyName,
      placementGroupName: this.placementGroup.ref,
      availabilityZone: actualAz,
      iamInstanceProfile: instanceProfile.ref,
      networkInterfaces: [
        {
          networkInterfaceId: node1Efa.ref,
          deviceIndex: "0",
        },
      ],
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
        { key: "Name", value: "pd-di-node1" },
        { key: "Role", value: "producer" },
      ],
    });

    this.node1.addDependency(this.placementGroup);

    // EC2 Instance: Node 2 (Consumer)
    this.node2 = new ec2.CfnInstance(this, "Node2", {
      imageId: ami.getImage(this).imageId,
      instanceType,
      keyName,
      placementGroupName: this.placementGroup.ref,
      availabilityZone: actualAz,
      iamInstanceProfile: instanceProfile.ref,
      networkInterfaces: [
        {
          networkInterfaceId: node2Efa.ref,
          deviceIndex: "0",
        },
      ],
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
        { key: "Name", value: "pd-di-node2" },
        { key: "Role", value: "consumer" },
      ],
    });

    this.node2.addDependency(this.placementGroup);

    // Outputs
    new CfnOutput(this, "Node1InstanceId", {
      value: this.node1.ref,
      description: "Node 1 (Producer) instance ID",
      exportName: `${this.stackName}-Node1InstanceId`,
    });

    new CfnOutput(this, "Node1PublicIp", {
      value: this.node1.attrPublicIp,
      description: "Node 1 public IP address",
      exportName: `${this.stackName}-Node1PublicIp`,
    });

    new CfnOutput(this, "Node1PrivateIp", {
      value: this.node1.attrPrivateIp,
      description: "Node 1 private IP address",
      exportName: `${this.stackName}-Node1PrivateIp`,
    });

    new CfnOutput(this, "Node2InstanceId", {
      value: this.node2.ref,
      description: "Node 2 (Consumer) instance ID",
      exportName: `${this.stackName}-Node2InstanceId`,
    });

    new CfnOutput(this, "Node2PublicIp", {
      value: this.node2.attrPublicIp,
      description: "Node 2 public IP address",
      exportName: `${this.stackName}-Node2PublicIp`,
    });

    new CfnOutput(this, "Node2PrivateIp", {
      value: this.node2.attrPrivateIp,
      description: "Node 2 private IP address",
      exportName: `${this.stackName}-Node2PrivateIp`,
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
