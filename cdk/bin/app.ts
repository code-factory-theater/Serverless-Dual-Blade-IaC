#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { ServerlessAPIStack } from "../lib/stack";

const app = new cdk.App();

const environment = app.node.tryGetContext("environment") || "dev";
const awsRegion = app.node.tryGetContext("aws_region") || "ap-northeast-1";

new ServerlessAPIStack(app, `ServerlessAPI-${environment}`, {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: awsRegion,
  },
  environment,
  stackName: `serverless-api-${environment}`,
});