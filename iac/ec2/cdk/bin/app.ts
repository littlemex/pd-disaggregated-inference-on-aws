#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { SingleNodeStack } from "../lib/single-node-stack";
import { MultiNodeStack } from "../lib/multi-node-stack";

const app = new cdk.App();

// Parse command-line arguments
const mode = app.node.tryGetContext("mode") || "single";
const region = app.node.tryGetContext("region") || process.env.CDK_DEFAULT_REGION || "us-east-1";
const account = process.env.CDK_DEFAULT_ACCOUNT;
const instanceType = app.node.tryGetContext("instanceType") || app.node.tryGetContext("instance-type");
const availabilityZone = app.node.tryGetContext("availabilityZone") || app.node.tryGetContext("az");
const vpcId = app.node.tryGetContext("vpcId") || app.node.tryGetContext("vpc-id");
const keyName = app.node.tryGetContext("keyName") || app.node.tryGetContext("key-name");

// Validate mode
if (!["single", "multi"].includes(mode)) {
  console.error(`[ERROR] Invalid mode: ${mode}. Must be 'single' or 'multi'.`);
  process.exit(1);
}

// Validate region
if (!region) {
  console.error(`[ERROR] Region not specified. Use: cdk deploy -c region=<region>`);
  process.exit(1);
}

console.log(`[INFO] Mode: ${mode}`);
console.log(`[INFO] Region: ${region}`);
if (instanceType) {
  console.log(`[INFO] Instance Type: ${instanceType}`);
}

const stackName = `pd-di-${mode}-${region}`;

if (mode === "single") {
  new SingleNodeStack(app, stackName, {
    env: { account, region },
    instanceType,
    keyName,
    availabilityZone,
    vpcId,
  });
  console.log(`[INFO] Deploying Single-node stack: ${stackName}`);
} else {
  new MultiNodeStack(app, stackName, {
    env: { account, region },
    instanceType,
    keyName,
    availabilityZone,
    vpcId,
  });
  console.log(`[INFO] Deploying Multi-node stack: ${stackName}`);
}

app.synth();
