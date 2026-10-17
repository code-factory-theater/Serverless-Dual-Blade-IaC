import * as cdk from 'aws-cdk-lib';
import * as apigatewayv2 from 'aws-cdk-lib/aws-apigatewayv2';
import * as apigatewayv2_integrations from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as path from 'path';
import { Construct } from 'constructs';

interface ServerlessApiStackProps extends cdk.StackProps {
  environment: string;
}

export class ServerlessApiStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: ServerlessApiStackProps) {
    super(scope, id, props);

    const projectName = 'serverless-api';
    const env = props.environment;
    const region = this.region;
    const account = this.account;

    // DynamoDB Table
    const table = new dynamodb.Table(this, 'ItemsTable', {
      tableName: `${projectName}-${env}-items`,
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      partitionKey: { name: 'PK', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'SK', type: dynamodb.AttributeType.STRING },
      pointInTimeRecovery: true,
      encryption: dynamodb.TableEncryption.AWS_MANAGED,
      removalPolicy: env === 'prod' ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
      deletionProtection: env === 'prod',
      timeToLiveAttribute: 'expiresAt',
    });

    // Lambda Function
    const logGroup = new logs.LogGroup(this, 'LambdaLogGroup', {
      logGroupName: `/aws/lambda/${projectName}-${env}-handler`,
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const lambdaFunc = new lambda.Function(this, 'Handler', {
      functionName: `${projectName}-${env}-handler`,
      runtime: lambda.Runtime.NODEJS_20_X,
      code: lambda.Code.fromAsset(path.join(__dirname, '../../apps/dist')),
      handler: 'index.handler',
      architecture: lambda.Architecture.ARM_64,
      memorySize: 512,
      timeout: cdk.Duration.seconds(10),
      loggingFormat: lambda.LoggingFormat.JSON,
      logGroup,
      tracing: lambda.Tracing.ACTIVE,
      environment: {
        DYNAMODB_TABLE: table.tableName,
        ENVIRONMENT: env,
      },
    });

    // Grant DynamoDB permissions
    table.grantReadWriteData(lambdaFunc);

    // Lambda Alias
    const alias = new lambda.Alias(this, 'LiveAlias', {
      aliasName: 'live',
      version: lambdaFunc.currentVersion,
    });

    // HTTP API
    const httpApi = new apigatewayv2.HttpApi(this, 'HttpApi', {
      apiName: `${projectName}-${env}-api`,
      corsPreflight: {
        allowMethods: [apigatewayv2.HttpMethod.GET, apigatewayv2.HttpMethod.POST, 
                       apigatewayv2.HttpMethod.PUT, apigatewayv2.HttpMethod.DELETE],
        allowOrigins: ['*'],
        allowHeaders: ['Content-Type', 'Authorization'],
        maxAge: cdk.Duration.seconds(300),
      },
    });

    // Integration
    const integration = new apigatewayv2_integrations.HttpLambdaIntegration(
      'LambdaIntegration',
      alias
    );

    // Routes
    httpApi.addRoutes({
      path: '/items',
      methods: [apigatewayv2.HttpMethod.GET, apigatewayv2.HttpMethod.POST],
      integration,
    });

    httpApi.addRoutes({
      path: '/items/{id}',
      methods: [apigatewayv2.HttpMethod.GET, apigatewayv2.HttpMethod.PUT, apigatewayv2.HttpMethod.DELETE],
      integration,
    });

    // API Stage with Logging
    const apiLogGroup = new logs.LogGroup(this, 'ApiLogGroup', {
      logGroupName: `/aws/apigateway/${projectName}-${env}-api`,
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const stage = httpApi.defaultStage;
    if (stage) {
      stage.accessLog = new apigatewayv2.HttpStageOptions({
        format: apigatewayv2.AccessLogFormat.jsonWithStandardFields({
          caller: true,
          httpMethod: true,
          ip: true,
          protocol: true,
          requestTime: true,
          resourcePath: true,
          routeKey: true,
          status: true,
          userAgent: true,
          integrationLatency: true,
        }),
        destination: new apigatewayv2.LogDestinationProperty({
          logGroup: apiLogGroup,
        }),
      });
    }

    // CloudWatch Alarm for Lambda Errors
    new cloudwatch.Alarm(this, 'LambdaErrorAlarm', {
      alarmName: `${projectName}-${env}-lambda-errors`,
      metric: new cloudwatch.Metric({
        namespace: 'AWS/Lambda',
        metricName: 'Errors',
        statistic: 'Sum',
        period: cdk.Duration.minutes(1),
        dimensionsMap: { FunctionName: lambdaFunc.functionName },
      }),
      threshold: 5,
      evaluationPeriods: 1,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      alarmDescription: 'Alert when Lambda errors exceed threshold',
    });

    // Outputs
    new cdk.CfnOutput(this, 'ApiEndpoint', {
      value: `${httpApi.url}${env}`,
      exportName: `${projectName}-${env}-api-endpoint`,
    });

    new cdk.CfnOutput(this, 'LambdaFunctionArn', {
      value: lambdaFunc.functionArn,
      exportName: `${projectName}-${env}-lambda-arn`,
    });

    new cdk.CfnOutput(this, 'DynamoDBTableName', {
      value: table.tableName,
      exportName: `${projectName}-${env}-table-name`,
    });
  }
}