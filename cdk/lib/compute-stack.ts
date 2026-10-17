import * as cdk from 'aws-cdk-lib';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as apigatewayv2 from 'aws-cdk-lib/aws-apigatewayv2';
import * as apigatewayv2Integration from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import { Construct } from 'constructs';
import * as path from 'path';

interface ComputeStackProps extends cdk.StackProps {
  environment: string;
  table: dynamodb.Table;
}

export class ComputeStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: ComputeStackProps) {
    super(scope, id, props);

    const logGroup = new logs.LogGroup(this, 'LambdaLogGroup', {
      logGroupName: `/aws/lambda/serverless-api-${props.environment}`,
      retention: logs.RetentionDays.TWO_WEEKS,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const handler = new lambda.Function(this, 'ApiHandler', {
      functionName: `serverless-api-${props.environment}`,
      runtime: lambda.Runtime.NODEJS_20_X,
      architecture: lambda.Architecture.ARM_64,
      handler: 'index.handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '../lambda'), {
        bundling: { image: cdk.DockerImage.fromRegistry('public.ecr.aws/lambda/nodejs:20') },
      }),
      timeout: cdk.Duration.seconds(30),
      memorySize: 256,
      logGroup: logGroup,
      loggingFormat: lambda.LoggingFormat.JSON,
      environment: {
        DYNAMODB_TABLE: props.table.tableName,
        ENVIRONMENT: props.environment,
      },
    });

    props.table.grantReadWriteData(handler);

    const api = new apigatewayv2.HttpApi(this, 'Api', {
      apiName: `serverless-api-${props.environment}`,
      defaultIntegration: new apigatewayv2Integration.HttpLambdaIntegration('LambdaIntegration', handler),
    });

    const stage = api.defaultStage?.node.defaultChild as apigatewayv2.CfnStage;
    if (stage) {
      stage.accessLogSettings = {
        destinationArn: new logs.LogGroup(this, 'ApiLogGroup', {
          logGroupName: `/aws/apigateway/serverless-api-${props.environment}`,
          retention: logs.RetentionDays.TWO_WEEKS,
          removalPolicy: cdk.RemovalPolicy.DESTROY,
        }).logGroupArn,
        format: JSON.stringify({
          requestId: '$context.requestId',
          ip: '$context.identity.sourceIp',
          requestTime: '$context.requestTime',
          httpMethod: '$context.httpMethod',
          resourcePath: '$context.resourcePath',
          status: '$context.status',
        }),
      };
      stage.throttleSettings = { burstLimit: 5000, rateLimit: 2000 };
    }

    new cloudwatch.Alarm(this, 'LambdaErrorsAlarm', {
      alarmName: `serverless-api-lambda-errors-${props.environment}`,
      metric: handler.metricErrors({ period: cdk.Duration.seconds(60) }),
      threshold: 1,
      evaluationPeriods: 1,
      alarmDescription: 'Alert on Lambda errors',
    });

    new cloudwatch.Alarm(this, 'DynamoDBSystemErrorsAlarm', {
      alarmName: `serverless-api-dynamodb-errors-${props.environment}`,
      metric: new cloudwatch.Metric({
        namespace: 'AWS/DynamoDB',
        metricName: 'SystemErrors',
        statistic: 'Sum',
        period: cdk.Duration.seconds(60),
        dimensions: { TableName: props.table.tableName },
      }),
      threshold: 0,
      evaluationPeriods: 1,
      alarmDescription: 'Alert on DynamoDB system errors',
    });

    new cdk.CfnOutput(this, 'ApiEndpoint', {
      value: `${api.url}/`,
      description: 'API Gateway HTTP API endpoint',
    });

    cdk.Tags.of(this).add('ManagedBy', 'cdk');
    cdk.Tags.of(this).add('Environment', props.environment);
  }
}