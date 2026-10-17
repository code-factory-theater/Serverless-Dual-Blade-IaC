#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { ServerlessApiStack } from '../lib/stack';

const app = new cdk.App();

const environment = app.node.tryGetContext('environment') || 'dev';
const region = app.node.tryGetContext('region') || 'us-east-1';

new ServerlessApiStack(app, `ServerlessApiStack-${environment}`, {
  environment,
  env: {
    region,
  },
});

cdk.Aspects.of(app).add(new cdk.Nag.NagPack());