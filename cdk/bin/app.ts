import * as cdk from 'aws-cdk-lib';
import { StateStack } from '../lib/state-stack';
import { ComputeStack } from '../lib/compute-stack';

const app = new cdk.App();
const config = app.node.tryGetContext('config') || { env: 'dev', region: 'ap-northeast-1' };

const stateStack = new StateStack(app, 'ServerlessApiStateStack', {
  environment: config.env,
  env: { region: config.region },
});

const computeStack = new ComputeStack(app, 'ServerlessApiComputeStack', {
  environment: config.env,
  table: stateStack.table,
  env: { region: config.region },
});

computeStack.addDependency(stateStack);

app.synth();