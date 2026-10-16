import * as cdk from "aws-cdk-lib";
import * as apigatewayv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as iam from "aws-cdk-lib/aws-iam";
import * as logs from "aws-cdk-lib/aws-logs";
import * as sqs from "aws-cdk-lib/aws-sqs";
import { Construct } from "constructs";
import * as path from "path";

interface ServerlessAPIStackProps extends cdk.StackProps {
  environment: string;
}

export class ServerlessAPIStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: ServerlessAPIStackProps) {
    super(scope, id, props);

    const appName = "serverless-api";
    const env = props.environment;
    const account = cdk.Stack.of(this).account;
    const region = cdk.Stack.of(this).region;

    // DynamoDB Table
    const table = new dynamodb.Table(this, "ApiTable", {
      tableName: `${appName}-table-${env}`,
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      partitionKey: { name: "id", type: dynamodb.AttributeType.STRING },
      pointInTimeRecovery: true,
      encryption: dynamodb.TableEncryption.DEFAULT,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // Dead Letter Queue
    const dlq = new sqs.Queue(this, "LambdaDLQ", {
      queueName: `${appName}-dlq-${env}`,
      retentionPeriod: cdk.Duration.days(14),
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // Lambda Function
    const handler = new lambda.Function(this, "ApiHandler", {
      functionName: `${appName}-handler-${env}`,
      runtime: lambda.Runtime.NODEJS_20_X,
      architecture: lambda.Architecture.ARM_64,
      handler: "index.handler",
      code: lambda.Code.fromAsset(path.join(__dirname, "../../apps/dist")),
      memorySize: 512,
      timeout: cdk.Duration.seconds(10),
      environment: {
        TABLE_NAME: table.tableName,
        ENVIRONMENT: env,
        LOG_LEVEL: "INFO",
      },
      deadLetterQueue: dlq,
      tracing: lambda.Tracing.ACTIVE,
      insightsVersion: lambda.LambdaInsightsVersion.VERSION_1_0_119_0,
    });

    // Grant permissions
    table.grantReadWriteData(handler);
    dlq.grantSendMessages(handler);

    // API Gateway HTTP API
    const httpApi = new apigatewayv2.HttpApi(this, "HttpApi", {
      apiName: `${appName}-api-${env}`,
      corsPreflight: {
        allowOrigins: ["*"],
        allowMethods: [
          apigatewayv2.HttpMethod.GET,
          apigatewayv2.HttpMethod.POST,
          apigatewayv2.HttpMethod.PUT,
          apigatewayv2.HttpMethod.DELETE,
          apigatewayv2.HttpMethod.OPTIONS,
        ],
        allowHeaders: ["*"],
      },
    });

    // CloudWatch Log Group for API
    const apiLogGroup = new logs.LogGroup(this, "ApiLogGroup", {
      logGroupName: `/aws/apigateway/${appName}-${env}`,
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // Integration
    const integration = new integrations.HttpLambdaIntegration(
      "LambdaIntegration",
      handler,
      {
        payloadFormatVersion: apigatewayv2.PayloadFormatVersion.VERSION_2_0,
      }
    );

    // Route
    httpApi.addRoutes({
      path: "/{proxy+}",
      methods: [apigatewayv2.HttpMethod.ANY],
      integration,
    });

    // Stage with throttle & logging
    const stage = httpApi.defaultStage;
    if (stage) {
      stage.accessLog = {
        destinationArn: apiLogGroup.logGroupArn,
        format: apigatewayv2.AccessLogFormat.jsonWithStandardFields({
          caller: false,
          httpMethod: true,
          ip: true,
          protocol: true,
          requestTime: true,
          resourcePath: true,
          responseLength: true,
          status: true,
          user: false,
        }),
      };
      stage.throttleSettings = {
        rateLimit: 100,
        burstLimit: 200,
      };
    }

    // Outputs
    new cdk.CfnOutput(this, "ApiEndpoint", {
      value: httpApi.url || "",
      description: "HTTP API endpoint",
      exportName: `${appName}-endpoint-${env}`,
    });
    new cdk.CfnOutput(this, "LambdaFunctionName", {
      value: handler.functionName,
      exportName: `${appName}-lambda-${env}`,
    });
    new cdk.CfnOutput(this, "DynamoDBTableName", {
      value: table.tableName,
      exportName: `${appName}-table-${env}`,
    });
  }
}