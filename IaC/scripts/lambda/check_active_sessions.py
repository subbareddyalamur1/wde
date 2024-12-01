import json
import boto3
import time
from datetime import datetime, timedelta

def lambda_handler(event, context):
    print("Received event:", json.dumps(event))
    
    # Initialize AWS clients
    asg = boto3.client('autoscaling')
    cloudwatch = boto3.client('cloudwatch')
    
    # Get instance ID from the event
    instance_id = event['detail']['EC2InstanceId']
    asg_name = event['detail']['AutoScalingGroupName']
    lifecycle_hook_name = event['detail']['LifecycleHookName']
    
    try:
        max_attempts = 12  # Try for 1 hour (5 minutes between attempts)
        for attempt in range(max_attempts):
            # Record heartbeat to extend the timeout
            if attempt > 0:  # Don't record on first attempt
                try:
                    asg.record_lifecycle_action_heartbeat(
                        LifecycleHookName=lifecycle_hook_name,
                        AutoScalingGroupName=asg_name,
                        InstanceId=instance_id
                    )
                    print(f"Recorded heartbeat, attempt {attempt + 1}")
                except Exception as e:
                    print(f"Failed to record heartbeat: {str(e)}")
            
            # Get the latest ActiveUserSessions metric
            response = cloudwatch.get_metric_statistics(
                Namespace='Custom/WindowsMetrics',  # Updated namespace to match PowerShell script
                MetricName='ActiveUserSessions',
                Dimensions=[
                    {
                        'Name': 'InstanceId',
                        'Value': instance_id
                    },
                    {
                        'Name': 'AutoScalingGroupName',
                        'Value': asg_name
                    }
                ],
                StartTime=datetime.utcnow() - timedelta(minutes=5),
                EndTime=datetime.utcnow(),
                Period=300,  # 5 minutes
                Statistics=['Maximum']
            )
            
            if response['Datapoints']:
                active_sessions = response['Datapoints'][0]['Maximum']
                print(f"Active sessions from CloudWatch: {active_sessions}")
                
                if active_sessions == 0:
                    # Complete lifecycle action - continue termination
                    asg.complete_lifecycle_action(
                        LifecycleHookName=lifecycle_hook_name,
                        AutoScalingGroupName=asg_name,
                        InstanceId=instance_id,
                        LifecycleActionResult='CONTINUE'
                    )
                    print(f"Instance {instance_id} can be terminated - no active sessions")
                    return {
                        'statusCode': 200,
                        'body': json.dumps('Instance can be terminated')
                    }
                else:
                    print(f"Instance {instance_id} has {active_sessions} active sessions, waiting...")
                    time.sleep(300)  # Wait 5 minutes before next check
            else:
                print("No metric data available, waiting for next check...")
                time.sleep(300)  # Wait 5 minutes before next check
        
        # If we get here, we've exceeded max attempts
        print(f"Exceeded maximum attempts ({max_attempts}), abandoning termination")
        asg.complete_lifecycle_action(
            LifecycleHookName=lifecycle_hook_name,
            AutoScalingGroupName=asg_name,
            InstanceId=instance_id,
            LifecycleActionResult='ABANDON'
        )
            
    except Exception as e:
        print(f"Error: {str(e)}")
        # Abandon termination on error
        asg.complete_lifecycle_action(
            LifecycleHookName=lifecycle_hook_name,
            AutoScalingGroupName=asg_name,
            InstanceId=instance_id,
            LifecycleActionResult='ABANDON'
        )
        
    return {
        'statusCode': 200,
        'body': json.dumps('Function completed successfully')
    }